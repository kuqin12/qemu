/*
 * KVM-based ITS implementation for a GICv3-based system
 *
 * Copyright (c) 2015 Samsung Electronics Co., Ltd.
 * Written by Pavel Fedin <p.fedin@samsung.com>
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, see <http://www.gnu.org/licenses/>.
 */

#include "qemu/osdep.h"
#include "qapi/error.h"
#include "qemu/module.h"
#include "qemu/error-report.h"
#include "qemu/timer.h"
#include "qemu/units.h"
#include "hw/intc/arm_gicv3_its_common.h"
#include "gicv3_internal.h"
#include "hw/core/cpu.h"
#include "hw/core/qdev-properties.h"
#include "system/runstate.h"
#include "system/kvm.h"
#include "kvm_arm.h"
#include "migration/blocker.h"
#include "qom/object.h"
#include "trace.h"

#define TYPE_KVM_ARM_ITS "arm-its-kvm"
#define KVM_ITS_HIBERNATE_MAX_BLOBS 512
#define KVM_ITS_HIBERNATE_MAX_BYTES (32 * MiB)
#define KVM_ITS_ABI_DTE_SIZE 8
#define KVM_ITS_ABI_ITE_SIZE 8
#define KVM_ITS_ABI_DTE_NEXT_SHIFT 49
#define KVM_ITS_ABI_DTE_NEXT_LENGTH 14
#define KVM_ITS_ABI_REVISION(iidr) extract64((iidr), 12, 4)
typedef struct KVMARMITSState KVMARMITSState;
typedef struct KVMARMITSClass KVMARMITSClass;
DECLARE_OBJ_CHECKERS(KVMARMITSState, KVMARMITSClass,
                     KVM_ARM_ITS, TYPE_KVM_ARM_ITS)

struct KVMARMITSState {
    GICv3ITSState parent_obj;
    QEMUTimer wake_timer;
    GQueue blocked_msis;
    unsigned int wake_retry;
};

struct KVMARMITSClass {
    GICv3ITSCommonClass parent_class;
    ResettablePhases parent_phases;
};

static const unsigned int kvm_its_wake_retry_ms[] = {
    10, 100, 1000, 2000, 4000, 8000,
};

static void kvm_its_wake_cpu(CPUState *cs, run_on_cpu_data data)
{
}

static void kvm_its_queue_cpu_wake(void)
{
    CPUState *cs;

    CPU_FOREACH(cs) {
        if (!cs->secondary_tcg) {
            async_run_on_cpu(cs, kvm_its_wake_cpu, RUN_ON_CPU_NULL);
        }
    }
}

static bool kvm_its_same_msi(const struct kvm_msi *a,
                             const struct kvm_msi *b)
{
    return a->address_lo == b->address_lo &&
           a->address_hi == b->address_hi &&
           a->data == b->data &&
           a->flags == b->flags &&
           a->devid == b->devid;
}

static void kvm_its_clear_blocked_msis(KVMARMITSState *its)
{
    timer_del(&its->wake_timer);
    its->wake_retry = 0;

    while (!g_queue_is_empty(&its->blocked_msis)) {
        g_free(g_queue_pop_head(&its->blocked_msis));
    }
}

static void kvm_its_queue_blocked_msi(KVMARMITSState *its,
                                      const struct kvm_msi *msi)
{
    struct kvm_msi *blocked;
    GList *item;

    for (item = its->blocked_msis.head; item; item = item->next) {
        blocked = item->data;
        if (kvm_its_same_msi(blocked, msi)) {
            return;
        }
    }

    blocked = g_new(struct kvm_msi, 1);
    *blocked = *msi;
    g_queue_push_tail(&its->blocked_msis, blocked);

    its->wake_retry = 0;
    timer_mod(&its->wake_timer,
              qemu_clock_get_ms(QEMU_CLOCK_VIRTUAL) +
              kvm_its_wake_retry_ms[0]);
}

static void kvm_its_wake_timer(void *opaque)
{
    KVMARMITSState *its = opaque;
    GList *item = its->blocked_msis.head;
    unsigned int retry = its->wake_retry++;
    bool delivered = false;
    Error *restore_err = NULL;
    int restore_ret;

    g_assert(retry < ARRAY_SIZE(kvm_its_wake_retry_ms));
    restore_ret = arm_hybrid_restore_its(DEVICE(its), &restore_err);
    if (restore_ret < 0) {
        error_reportf_err(restore_err,
                          "KVM ITS hibernation restore failed: ");
        qemu_system_vmstop_request_prepare();
        qemu_system_vmstop_request(RUN_STATE_INTERNAL_ERROR);
        kvm_its_clear_blocked_msis(its);
        return;
    }
    while (item) {
        struct kvm_msi *blocked = item->data;
        GList *next = item->next;
        int ret;

        ret = kvm_vm_ioctl(kvm_state, KVM_SIGNAL_MSI, blocked);
        trace_kvm_its_wake_retry(blocked->devid, blocked->data,
                                 ret, retry + 1,
                                 kvm_its_wake_retry_ms[retry]);
        if (ret != 0) {
            g_queue_delete_link(&its->blocked_msis, item);
            g_free(blocked);
            delivered |= ret > 0;
        }
        item = next;
    }

    if (delivered) {
        kvm_its_queue_cpu_wake();
    }

    if (g_queue_is_empty(&its->blocked_msis)) {
        its->wake_retry = 0;
    } else if (its->wake_retry < ARRAY_SIZE(kvm_its_wake_retry_ms)) {
        timer_mod(&its->wake_timer,
                  qemu_clock_get_ms(QEMU_CLOCK_VIRTUAL) +
                  kvm_its_wake_retry_ms[its->wake_retry] -
                  kvm_its_wake_retry_ms[retry]);
    } else {
        kvm_its_clear_blocked_msis(its);
    }
}

static int kvm_its_send_msi(GICv3ITSState *s, uint32_t value, uint16_t devid)
{
    KVMARMITSState *its = KVM_ARM_ITS(s);
    struct kvm_msi msi;
    CPUState *cs;
    bool kick;
    int ret;

    if (unlikely(!s->translater_gpa_known)) {
        MemoryRegion *mr = &s->iomem_its_translation;
        MemoryRegionSection mrs;

        mrs = memory_region_find(mr, 0, 1);
        memory_region_unref(mrs.mr);
        s->gits_translater_gpa = mrs.offset_within_address_space + 0x40;
        s->translater_gpa_known = true;
    }

    msi.address_lo = extract64(s->gits_translater_gpa, 0, 32);
    msi.address_hi = extract64(s->gits_translater_gpa, 32, 32);
    msi.data = value;
    msi.flags = KVM_MSI_VALID_DEVID;
    msi.devid = devid;
    memset(msi.pad, 0, sizeof(msi.pad));

    ret = kvm_vm_ioctl(kvm_state, KVM_SIGNAL_MSI, &msi);
    if (ret == 0) {
        Error *restore_err = NULL;
        int restore_ret = arm_hybrid_restore_its(DEVICE(s), &restore_err);

        if (restore_ret > 0) {
            ret = kvm_vm_ioctl(kvm_state, KVM_SIGNAL_MSI, &msi);
        } else if (restore_ret < 0) {
            error_reportf_err(restore_err,
                              "KVM ITS hibernation restore failed: ");
            qemu_system_vmstop_request_prepare();
            qemu_system_vmstop_request(RUN_STATE_INTERNAL_ERROR);
            ret = restore_ret;
        }
    }
    /* KVM_SIGNAL_MSI returns > 0 when the MSI was delivered. */
    kick = ret > 0 && kvm_arm_ffa_forward_enabled();
    trace_kvm_its_send_msi(devid, value, ret, kick);
    if (ret == 0 && kvm_arm_ffa_forward_enabled()) {
        /* The device edge occurred, but KVM blocked and dropped the MSI. */
        kvm_its_queue_blocked_msi(its, &msi);
    }
    if (kick) {
        CPU_FOREACH(cs) {
            if (!cs->secondary_tcg) {
                qemu_cpu_kick(cs);
            }
        }
    }

    return ret;
}

/**
 * vm_change_state_handler - VM change state callback aiming at flushing
 * ITS tables into guest RAM
 *
 * The tables get flushed to guest RAM whenever the VM gets stopped.
 */
static void vm_change_state_handler(void *opaque, bool running,
                                    RunState state)
{
    GICv3ITSState *s = (GICv3ITSState *)opaque;
    Error *err = NULL;

    if (running) {
        return;
    }

    if (s->hibernate_resume_pending) {
        return;
    }

    kvm_device_access(s->dev_fd, KVM_DEV_ARM_VGIC_GRP_CTRL,
                      KVM_DEV_ARM_ITS_SAVE_TABLES, NULL, true, &err);
    if (err) {
        error_report_err(err);
    }
}

static void kvm_arm_its_realize(DeviceState *dev, Error **errp)
{
    GICv3ITSState *s = ARM_GICV3_ITS_COMMON(dev);

    s->dev_fd = kvm_create_device(kvm_state, KVM_DEV_TYPE_ARM_VGIC_ITS, false);
    if (s->dev_fd < 0) {
        error_setg_errno(errp, -s->dev_fd, "error creating in-kernel ITS");
        return;
    }

    /* explicit init of the ITS */
    kvm_device_access(s->dev_fd, KVM_DEV_ARM_VGIC_GRP_CTRL,
                      KVM_DEV_ARM_VGIC_CTRL_INIT, NULL, true, &error_abort);

    /* register the base address */
    kvm_arm_register_device(&s->iomem_its_cntrl, -1, KVM_DEV_ARM_VGIC_GRP_ADDR,
                            KVM_VGIC_ITS_ADDR_TYPE, s->dev_fd, 0);

    gicv3_add_its(s->gicv3, dev);

    gicv3_its_init_mmio(s, NULL, NULL);

    if (!kvm_device_check_attr(s->dev_fd, KVM_DEV_ARM_VGIC_GRP_ITS_REGS,
        GITS_CTLR)) {
        error_setg(&s->migration_blocker, "This operating system kernel "
                   "does not support vITS migration");
        if (migrate_add_blocker(&s->migration_blocker, errp) < 0) {
            return;
        }
    } else {
        qemu_add_vm_change_state_handler(vm_change_state_handler, s);
    }

    kvm_msi_use_devid = true;
    kvm_gsi_direct_mapping = false;
    kvm_msi_via_irqfd_allowed = true;
}

/**
 * kvm_arm_its_pre_save - handles the saving of ITS registers.
 * ITS tables are flushed into guest RAM separately and earlier,
 * through the VM change state handler, since at the moment pre_save()
 * is called, the guest RAM has already been saved.
 */
static void kvm_arm_its_pre_save(GICv3ITSState *s)
{
    int i;

    for (i = 0; i < 8; i++) {
        kvm_device_access(s->dev_fd, KVM_DEV_ARM_VGIC_GRP_ITS_REGS,
                          GITS_BASER + i * 8, &s->baser[i], false,
                          &error_abort);
    }

    kvm_device_access(s->dev_fd, KVM_DEV_ARM_VGIC_GRP_ITS_REGS,
                      GITS_CTLR, &s->ctlr, false, &error_abort);

    kvm_device_access(s->dev_fd, KVM_DEV_ARM_VGIC_GRP_ITS_REGS,
                      GITS_CBASER, &s->cbaser, false, &error_abort);

    kvm_device_access(s->dev_fd, KVM_DEV_ARM_VGIC_GRP_ITS_REGS,
                      GITS_CREADR, &s->creadr, false, &error_abort);

    kvm_device_access(s->dev_fd, KVM_DEV_ARM_VGIC_GRP_ITS_REGS,
                      GITS_CWRITER, &s->cwriter, false, &error_abort);

    kvm_device_access(s->dev_fd, KVM_DEV_ARM_VGIC_GRP_ITS_REGS,
                      GITS_IIDR, &s->iidr, false, &error_abort);
}

/**
 * kvm_arm_its_post_load - Restore both the ITS registers and tables
 */
static void kvm_arm_its_post_load(GICv3ITSState *s)
{
    int i;

    kvm_device_access(s->dev_fd, KVM_DEV_ARM_VGIC_GRP_ITS_REGS,
                      GITS_IIDR, &s->iidr, true, &error_abort);

    /*
     * must be written before GITS_CREADR since GITS_CBASER write
     * access resets GITS_CREADR.
     */
    kvm_device_access(s->dev_fd, KVM_DEV_ARM_VGIC_GRP_ITS_REGS,
                      GITS_CBASER, &s->cbaser, true, &error_abort);

    kvm_device_access(s->dev_fd, KVM_DEV_ARM_VGIC_GRP_ITS_REGS,
                      GITS_CREADR, &s->creadr, true, &error_abort);

    kvm_device_access(s->dev_fd, KVM_DEV_ARM_VGIC_GRP_ITS_REGS,
                      GITS_CWRITER, &s->cwriter, true, &error_abort);


    for (i = 0; i < 8; i++) {
        kvm_device_access(s->dev_fd, KVM_DEV_ARM_VGIC_GRP_ITS_REGS,
                          GITS_BASER + i * 8, &s->baser[i], true,
                          &error_abort);
    }

    kvm_device_access(s->dev_fd, KVM_DEV_ARM_VGIC_GRP_CTRL,
                      KVM_DEV_ARM_ITS_RESTORE_TABLES, NULL, true,
                      &error_abort);

    kvm_device_access(s->dev_fd, KVM_DEV_ARM_VGIC_GRP_ITS_REGS,
                      GITS_CTLR, &s->ctlr, true, &error_abort);
}

static int kvm_arm_its_validate_hibernate(GICv3ITSState *s, Error **errp)
{
    if (!kvm_device_check_attr(s->dev_fd,
                               KVM_DEV_ARM_VGIC_GRP_ITS_REGS, GITS_CTLR) ||
        !kvm_device_check_attr(s->dev_fd, KVM_DEV_ARM_VGIC_GRP_CTRL,
                               KVM_DEV_ARM_ITS_SAVE_TABLES) ||
        !kvm_device_check_attr(s->dev_fd, KVM_DEV_ARM_VGIC_GRP_CTRL,
                               KVM_DEV_ARM_ITS_RESTORE_TABLES) ||
        !kvm_device_check_attr(s->dev_fd, KVM_DEV_ARM_VGIC_GRP_CTRL,
                               KVM_DEV_ARM_ITS_CTRL_RESET)) {
        error_setg(errp, "host KVM ITS does not support hybrid hibernation");
        return -ENOTSUP;
    }

    return 0;
}

static int kvm_arm_its_read_hibernate_layout(
    GICv3ITSState *s, GICv3ITSHibernateState *state, Error **errp)
{
    unsigned int collection_table_count = 0;
    unsigned int device_table_count = 0;
    int ret;
    int i;

    ret = kvm_device_access(s->dev_fd, KVM_DEV_ARM_VGIC_GRP_ITS_REGS,
                            GITS_CTLR, &state->ctlr, false, errp);
    if (ret) {
        return ret;
    }
    ret = kvm_device_access(s->dev_fd, KVM_DEV_ARM_VGIC_GRP_ITS_REGS,
                            GITS_IIDR, &state->iidr, false, errp);
    if (ret) {
        return ret;
    }
    ret = kvm_device_access(s->dev_fd, KVM_DEV_ARM_VGIC_GRP_ITS_REGS,
                            GITS_TYPER, &state->typer, false, errp);
    if (ret) {
        return ret;
    }
    ret = kvm_device_access(s->dev_fd, KVM_DEV_ARM_VGIC_GRP_ITS_REGS,
                            GITS_CBASER, &state->cbaser, false, errp);
    if (ret) {
        return ret;
    }
    ret = kvm_device_access(s->dev_fd, KVM_DEV_ARM_VGIC_GRP_ITS_REGS,
                            GITS_CWRITER, &state->cwriter, false, errp);
    if (ret) {
        return ret;
    }
    ret = kvm_device_access(s->dev_fd, KVM_DEV_ARM_VGIC_GRP_ITS_REGS,
                            GITS_CREADR, &state->creadr, false, errp);
    if (ret) {
        return ret;
    }
    for (i = 0; i < ARRAY_SIZE(state->baser); i++) {
        uint64_t type;

        ret = kvm_device_access(s->dev_fd, KVM_DEV_ARM_VGIC_GRP_ITS_REGS,
                                GITS_BASER + i * 8, &state->baser[i], false,
                                errp);
        if (ret) {
            return ret;
        }
        if (!FIELD_EX64(state->baser[i], GITS_BASER, VALID)) {
            continue;
        }
        type = FIELD_EX64(state->baser[i], GITS_BASER, TYPE);
        if ((type == GITS_BASER_TYPE_DEVICE ||
             type == GITS_BASER_TYPE_COLLECTION) &&
            FIELD_EX64(state->baser[i], GITS_BASER, INDIRECT)) {
            error_setg(errp, "indirect KVM ITS tables are not supported "
                       "for hybrid hibernation");
            return -ENOTSUP;
        }
        device_table_count += type == GITS_BASER_TYPE_DEVICE;
        collection_table_count += type == GITS_BASER_TYPE_COLLECTION;
    }

    if (!(state->ctlr & R_GITS_CTLR_ENABLED_MASK) ||
        !FIELD_EX64(state->cbaser, GITS_CBASER, VALID) ||
        device_table_count != 1 || collection_table_count != 1) {
        return GICV3_ITS_HIBERNATE_NOT_READY;
    }
    if (KVM_ITS_ABI_REVISION(state->iidr) != 0) {
        error_setg(errp, "unsupported KVM ITS table ABI revision %" PRIu64,
                   KVM_ITS_ABI_REVISION(state->iidr));
        return -ENOTSUP;
    }

    return 0;
}

static uint64_t kvm_arm_its_baser_page_size(uint64_t baser)
{
    switch (FIELD_EX64(baser, GITS_BASER, PAGESIZE)) {
    case GITS_BASER_PAGESIZE_4K:
        return GITS_PAGE_SIZE_4K;
    case GITS_BASER_PAGESIZE_16K:
        return GITS_PAGE_SIZE_16K;
    case GITS_BASER_PAGESIZE_64K:
    default:
        return GITS_PAGE_SIZE_64K;
    }
}

static uint64_t kvm_arm_its_baser_address(uint64_t baser,
                                           uint64_t page_size)
{
    if (page_size == GITS_PAGE_SIZE_64K) {
        return FIELD_EX64(baser, GITS_BASER, PHYADDRL_64K) << 16 |
               FIELD_EX64(baser, GITS_BASER, PHYADDRH_64K) << 48;
    }

    return FIELD_EX64(baser, GITS_BASER, PHYADDR) << 12;
}

static size_t kvm_arm_its_hibernate_bytes(
    const GICv3ITSHibernateState *state)
{
    size_t total = 0;
    unsigned int i;

    for (i = 0; i < state->blobs->len; i++) {
        GICv3ITSHibernateBlob *blob = g_ptr_array_index(state->blobs, i);

        total += g_bytes_get_size(blob->data);
    }
    return total;
}

static bool kvm_arm_its_hibernate_range_is_ram(GICv3ITSState *s,
                                                uint64_t guest_address,
                                                uint64_t size,
                                                bool is_write)
{
    hwaddr translated;
    hwaddr translated_size = size;
    MemoryRegion *mr;

    RCU_READ_LOCK_GUARD();
    mr = address_space_translate(&s->gicv3->dma_as, guest_address,
                                 &translated, &translated_size, is_write,
                                 MEMTXATTRS_UNSPECIFIED);
    return translated_size == size && memory_region_is_ram(mr);
}

static int kvm_arm_its_capture_blob(GICv3ITSState *s,
                                     GICv3ITSHibernateState *state,
                                     uint64_t guest_address, uint64_t size,
                                     Error **errp)
{
    GICv3ITSHibernateBlob *blob;
    g_autofree uint8_t *data = NULL;
    MemTxResult result;
    unsigned int i;

    if (!size || size > KVM_ITS_HIBERNATE_MAX_BYTES ||
        guest_address + size < guest_address ||
        state->blobs->len >= KVM_ITS_HIBERNATE_MAX_BLOBS ||
        kvm_arm_its_hibernate_bytes(state) >
            KVM_ITS_HIBERNATE_MAX_BYTES - size) {
        error_setg(errp, "invalid KVM ITS hibernation table range "
                   "0x%" PRIx64 "+0x%" PRIx64, guest_address, size);
        return -E2BIG;
    }
    if (!kvm_arm_its_hibernate_range_is_ram(s, guest_address, size,
                                             false)) {
        error_setg(errp, "KVM ITS hibernation table is not in guest RAM at "
                   "0x%" PRIx64 "+0x%" PRIx64, guest_address, size);
        return -EFAULT;
    }

    for (i = 0; i < state->blobs->len; i++) {
        uint64_t blob_size;

        blob = g_ptr_array_index(state->blobs, i);
        blob_size = g_bytes_get_size(blob->data);

        if (blob->guest_address == guest_address && blob_size == size) {
            return 0;
        }
        if (ranges_overlap(blob->guest_address, blob_size,
                           guest_address, size)) {
            error_setg(errp, "overlapping KVM ITS hibernation table ranges");
            return -EINVAL;
        }
    }

    data = g_malloc(size);
    result = address_space_read(&s->gicv3->dma_as, guest_address,
                                MEMTXATTRS_UNSPECIFIED, data, size);
    if (result != MEMTX_OK) {
        error_setg(errp, "cannot read KVM ITS hibernation table at "
                   "0x%" PRIx64, guest_address);
        return -EFAULT;
    }

    blob = g_new0(GICv3ITSHibernateBlob, 1);
    blob->guest_address = guest_address;
    blob->data = g_bytes_new_take(g_steal_pointer(&data), size);
    g_ptr_array_add(state->blobs, blob);
    return 0;
}

typedef int (*KVMARMITSDTEFunction)(uint64_t itt_address,
                                    uint64_t itt_size,
                                    void *opaque, Error **errp);

static int kvm_arm_its_foreach_hibernate_dte(
    GBytes *device_table, KVMARMITSDTEFunction function,
    void *opaque, Error **errp)
{
    gsize table_size;
    const uint8_t *table = g_bytes_get_data(device_table, &table_size);
    uint64_t offset = 0;

    while (offset + KVM_ITS_ABI_DTE_SIZE <= table_size) {
        uint64_t dte = ldq_le_p(table + offset);
        uint64_t next = 1;
        uint64_t itt_address;
        uint64_t itt_size;
        unsigned int size_bits;
        int ret;

        if (!(dte & BIT_ULL(63))) {
            offset += KVM_ITS_ABI_DTE_SIZE;
            continue;
        }
        size_bits = extract64(dte, 0, 5) + 1;
        itt_address = extract64(dte, 5, 44) << 8;
        itt_size = (1ULL << size_bits) * KVM_ITS_ABI_ITE_SIZE;
        ret = function(itt_address, itt_size, opaque, errp);
        if (ret) {
            return ret;
        }
        next = extract64(dte, KVM_ITS_ABI_DTE_NEXT_SHIFT,
                         KVM_ITS_ABI_DTE_NEXT_LENGTH);
        if (!next || next * KVM_ITS_ABI_DTE_SIZE >= table_size - offset) {
            break;
        }
        offset += next * KVM_ITS_ABI_DTE_SIZE;
    }

    return 0;
}

typedef struct KVMARMITSCaptureContext {
    GICv3ITSState *s;
    GICv3ITSHibernateState *state;
} KVMARMITSCaptureContext;

static int kvm_arm_its_capture_itt_blob(uint64_t itt_address,
                                        uint64_t itt_size,
                                        void *opaque, Error **errp)
{
    KVMARMITSCaptureContext *context = opaque;

    return kvm_arm_its_capture_blob(context->s, context->state,
                                    itt_address, itt_size, errp);
}

static int kvm_arm_its_capture_itt_blobs(GICv3ITSState *s,
                                          GICv3ITSHibernateState *state,
                                          GBytes *device_table,
                                          Error **errp)
{
    KVMARMITSCaptureContext context = {
        .s = s,
        .state = state,
    };

    return kvm_arm_its_foreach_hibernate_dte(
        device_table, kvm_arm_its_capture_itt_blob, &context, errp);
}

static int kvm_arm_its_capture_hibernate(
    GICv3ITSState *s, GICv3ITSHibernateState *state, Error **errp)
{
    GBytes *device_table = NULL;
    int ret;
    int i;

    g_ptr_array_set_size(state->blobs, 0);
    memset(state, 0, offsetof(GICv3ITSHibernateState, blobs));
    ret = kvm_arm_its_read_hibernate_layout(s, state, errp);
    if (ret) {
        return ret;
    }

    ret = kvm_device_access(s->dev_fd, KVM_DEV_ARM_VGIC_GRP_CTRL,
                            KVM_DEV_ARM_ITS_SAVE_TABLES, NULL, true, errp);
    if (ret) {
        return ret;
    }

    for (i = 0; i < ARRAY_SIZE(state->baser); i++) {
        GICv3ITSHibernateBlob *blob;
        uint64_t baser = state->baser[i];
        uint64_t page_size;
        uint64_t table_address;
        uint64_t table_size;
        uint64_t type;

        if (!FIELD_EX64(baser, GITS_BASER, VALID)) {
            continue;
        }
        type = FIELD_EX64(baser, GITS_BASER, TYPE);
        if (type != GITS_BASER_TYPE_DEVICE &&
            type != GITS_BASER_TYPE_COLLECTION) {
            continue;
        }
        page_size = kvm_arm_its_baser_page_size(baser);
        table_address = kvm_arm_its_baser_address(baser, page_size);
        table_size = (FIELD_EX64(baser, GITS_BASER, SIZE) + 1) * page_size;
        ret = kvm_arm_its_capture_blob(s, state, table_address, table_size,
                                       errp);
        if (ret) {
            return ret;
        }
        if (type == GITS_BASER_TYPE_DEVICE) {
            blob = g_ptr_array_index(state->blobs,
                                     state->blobs->len - 1);
            device_table = blob->data;
        }
    }

    if (!device_table) {
        error_setg(errp, "KVM ITS hibernation device table is missing");
        return -EINVAL;
    }
    return kvm_arm_its_capture_itt_blobs(s, state, device_table, errp);
}

static bool kvm_arm_its_hibernate_layout_matches(
    const GICv3ITSHibernateState *current,
    const GICv3ITSHibernateState *saved)
{
    return current->iidr == saved->iidr &&
           current->typer == saved->typer &&
           current->cbaser == saved->cbaser &&
           !memcmp(current->baser, saved->baser, sizeof(current->baser));
}

static int kvm_arm_its_find_hibernate_blob(
    const GICv3ITSHibernateState *state, uint64_t guest_address,
    uint64_t size)
{
    unsigned int i;

    for (i = 0; i < state->blobs->len; i++) {
        GICv3ITSHibernateBlob *blob = g_ptr_array_index(state->blobs, i);

        if (blob->guest_address == guest_address &&
            g_bytes_get_size(blob->data) == size) {
            return i;
        }
    }

    return -1;
}

typedef struct KVMARMITSValidateContext {
    const GICv3ITSHibernateState *state;
    bool *used;
} KVMARMITSValidateContext;

static int kvm_arm_its_validate_itt_blob(uint64_t itt_address,
                                         uint64_t itt_size,
                                         void *opaque, Error **errp)
{
    KVMARMITSValidateContext *context = opaque;
    int blob_index = kvm_arm_its_find_hibernate_blob(
        context->state, itt_address, itt_size);

    if (blob_index < 0) {
        error_setg(errp, "KVM ITS hibernation ITT is missing");
        return -EINVAL;
    }
    context->used[blob_index] = true;
    return 0;
}

static bool kvm_arm_its_hibernate_blobs_valid(
    const GICv3ITSHibernateState *state, Error **errp)
{
    bool used[KVM_ITS_HIBERNATE_MAX_BLOBS] = { false };
    GBytes *device_table = NULL;
    KVMARMITSValidateContext context = {
        .state = state,
        .used = used,
    };
    unsigned int i;
    int ret;

    if (!state->blobs->len ||
        state->blobs->len > KVM_ITS_HIBERNATE_MAX_BLOBS) {
        error_setg(errp, "invalid KVM ITS hibernation blob count");
        return false;
    }

    for (i = 0; i < ARRAY_SIZE(state->baser); i++) {
        uint64_t baser = state->baser[i];
        uint64_t page_size;
        uint64_t table_address;
        uint64_t table_size;
        uint64_t type;
        int blob_index;

        if (!FIELD_EX64(baser, GITS_BASER, VALID)) {
            continue;
        }
        type = FIELD_EX64(baser, GITS_BASER, TYPE);
        if (type != GITS_BASER_TYPE_DEVICE &&
            type != GITS_BASER_TYPE_COLLECTION) {
            continue;
        }
        page_size = kvm_arm_its_baser_page_size(baser);
        table_address = kvm_arm_its_baser_address(baser, page_size);
        table_size = (FIELD_EX64(baser, GITS_BASER, SIZE) + 1) * page_size;
        blob_index = kvm_arm_its_find_hibernate_blob(
            state, table_address, table_size);
        if (blob_index < 0 || used[blob_index]) {
            error_setg(errp, "missing or duplicate KVM ITS hibernation "
                       "BASER table");
            return false;
        }
        used[blob_index] = true;
        if (type == GITS_BASER_TYPE_DEVICE) {
            GICv3ITSHibernateBlob *blob =
                g_ptr_array_index(state->blobs, blob_index);

            device_table = blob->data;
        }
    }

    if (!device_table) {
        error_setg(errp, "KVM ITS hibernation device table is missing");
        return false;
    }

    ret = kvm_arm_its_foreach_hibernate_dte(
        device_table, kvm_arm_its_validate_itt_blob, &context, errp);
    if (ret) {
        return false;
    }

    for (i = 0; i < state->blobs->len; i++) {
        if (!used[i]) {
            error_setg(errp, "KVM ITS hibernation marker has an "
                       "unreferenced table blob");
            return false;
        }
    }

    return true;
}

static int kvm_arm_its_write_hibernate_register(GICv3ITSState *s,
                                                 uint64_t offset,
                                                 uint64_t value,
                                                 Error **errp)
{
    return kvm_device_access(s->dev_fd, KVM_DEV_ARM_VGIC_GRP_ITS_REGS,
                             offset, &value, true, errp);
}

static int kvm_arm_its_restore_hibernate(
    GICv3ITSState *s, const GICv3ITSHibernateState *state, Error **errp)
{
    GICv3ITSHibernateState current = { 0 };
    Error *local_err = NULL;
    Error *enable_err = NULL;
    int enable_ret;
    int ret;
    int i;

    ret = kvm_arm_its_read_hibernate_layout(s, &current, &local_err);
    if (ret == GICV3_ITS_HIBERNATE_NOT_READY) {
        return ret;
    }
    if (ret) {
        goto out;
    }
    if (!kvm_arm_its_hibernate_layout_matches(&current, state)) {
        return GICV3_ITS_HIBERNATE_NOT_READY;
    }
    if (!kvm_arm_its_hibernate_blobs_valid(state, &local_err)) {
        ret = -EINVAL;
        goto out;
    }

    for (i = 0; i < state->blobs->len; i++) {
        GICv3ITSHibernateBlob *blob = g_ptr_array_index(state->blobs, i);
        gsize size;
        const void *data = g_bytes_get_data(blob->data, &size);
        MemTxResult result;

        if (!kvm_arm_its_hibernate_range_is_ram(
                s, blob->guest_address, size, true)) {
            error_setg(&local_err, "KVM ITS hibernation table is not in "
                       "guest RAM at 0x%" PRIx64, blob->guest_address);
            ret = -EFAULT;
            goto out;
        }
        result = address_space_write(&s->gicv3->dma_as,
                                     blob->guest_address,
                                     MEMTXATTRS_UNSPECIFIED, data, size);

        if (result != MEMTX_OK) {
            error_setg(&local_err, "cannot restore KVM ITS table at "
                       "0x%" PRIx64, blob->guest_address);
            ret = -EFAULT;
            goto out;
        }
    }

    ret = kvm_device_access(s->dev_fd, KVM_DEV_ARM_VGIC_GRP_CTRL,
                            KVM_DEV_ARM_ITS_CTRL_RESET, NULL, true,
                            &local_err);
    if (ret) {
        goto out;
    }
    ret = kvm_arm_its_write_hibernate_register(
        s, GITS_CBASER, state->cbaser, &local_err);
    if (ret) {
        goto out;
    }
    ret = kvm_arm_its_write_hibernate_register(
        s, GITS_IIDR, state->iidr, &local_err);
    if (ret) {
        goto out;
    }
    ret = kvm_arm_its_write_hibernate_register(
        s, GITS_CREADR, state->creadr, &local_err);
    if (ret) {
        goto out;
    }
    ret = kvm_arm_its_write_hibernate_register(
        s, GITS_CWRITER, state->cwriter, &local_err);
    if (ret) {
        goto out;
    }
    for (i = 0; i < ARRAY_SIZE(state->baser); i++) {
        ret = kvm_arm_its_write_hibernate_register(
            s, GITS_BASER + i * 8, state->baser[i], &local_err);
        if (ret) {
            goto out;
        }
    }
    ret = kvm_device_access(s->dev_fd, KVM_DEV_ARM_VGIC_GRP_CTRL,
                            KVM_DEV_ARM_ITS_RESTORE_TABLES, NULL, true,
                            &local_err);
    enable_ret = kvm_arm_its_write_hibernate_register(
        s, GITS_CTLR, state->ctlr, &enable_err);
    if (!ret && enable_ret) {
        ret = enable_ret;
        local_err = enable_err;
        enable_err = NULL;
    } else if (enable_err) {
        error_report_err(enable_err);
    }

out:
    error_propagate(errp, local_err);
    return ret;
}

static void kvm_arm_its_reset_hold(Object *obj, ResetType type)
{
    GICv3ITSState *s = ARM_GICV3_ITS_COMMON(obj);
    KVMARMITSState *its = KVM_ARM_ITS(obj);
    KVMARMITSClass *c = KVM_ARM_ITS_GET_CLASS(s);
    int i;

    kvm_its_clear_blocked_msis(its);

    if (c->parent_phases.hold) {
        c->parent_phases.hold(obj, type);
    }

    if (kvm_device_check_attr(s->dev_fd, KVM_DEV_ARM_VGIC_GRP_CTRL,
                               KVM_DEV_ARM_ITS_CTRL_RESET)) {
        kvm_device_access(s->dev_fd, KVM_DEV_ARM_VGIC_GRP_CTRL,
                          KVM_DEV_ARM_ITS_CTRL_RESET, NULL, true, &error_abort);
        return;
    }

    warn_report("ITS KVM: full reset is not supported by the host kernel");

    if (!kvm_device_check_attr(s->dev_fd, KVM_DEV_ARM_VGIC_GRP_ITS_REGS,
                               GITS_CTLR)) {
        return;
    }

    kvm_device_access(s->dev_fd, KVM_DEV_ARM_VGIC_GRP_ITS_REGS,
                      GITS_CTLR, &s->ctlr, true, &error_abort);

    kvm_device_access(s->dev_fd, KVM_DEV_ARM_VGIC_GRP_ITS_REGS,
                      GITS_CBASER, &s->cbaser, true, &error_abort);

    for (i = 0; i < 8; i++) {
        kvm_device_access(s->dev_fd, KVM_DEV_ARM_VGIC_GRP_ITS_REGS,
                          GITS_BASER + i * 8, &s->baser[i], true,
                          &error_abort);
    }
}

static const Property kvm_arm_its_props[] = {
    DEFINE_PROP_LINK("parent-gicv3", GICv3ITSState, gicv3, "kvm-arm-gicv3",
                     GICv3State *),
};

static void kvm_arm_its_instance_init(Object *obj)
{
    KVMARMITSState *its = KVM_ARM_ITS(obj);

    g_queue_init(&its->blocked_msis);
    timer_init_ms(&its->wake_timer, QEMU_CLOCK_VIRTUAL,
                  kvm_its_wake_timer, its);
}

static void kvm_arm_its_instance_finalize(Object *obj)
{
    KVMARMITSState *its = KVM_ARM_ITS(obj);

    kvm_its_clear_blocked_msis(its);
}

static void kvm_arm_its_class_init(ObjectClass *klass, const void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);
    ResettableClass *rc = RESETTABLE_CLASS(klass);
    GICv3ITSCommonClass *icc = ARM_GICV3_ITS_COMMON_CLASS(klass);
    KVMARMITSClass *ic = KVM_ARM_ITS_CLASS(klass);

    dc->realize = kvm_arm_its_realize;
    device_class_set_props(dc, kvm_arm_its_props);
    resettable_class_set_parent_phases(rc, NULL, kvm_arm_its_reset_hold, NULL,
                                       &ic->parent_phases);
    icc->send_msi = kvm_its_send_msi;
    icc->pre_save = kvm_arm_its_pre_save;
    icc->post_load = kvm_arm_its_post_load;
    icc->validate_hibernate = kvm_arm_its_validate_hibernate;
    icc->capture_hibernate = kvm_arm_its_capture_hibernate;
    icc->restore_hibernate = kvm_arm_its_restore_hibernate;
}

static const TypeInfo kvm_arm_its_info = {
    .name = TYPE_KVM_ARM_ITS,
    .parent = TYPE_ARM_GICV3_ITS_COMMON,
    .instance_size = sizeof(KVMARMITSState),
    .instance_init = kvm_arm_its_instance_init,
    .instance_finalize = kvm_arm_its_instance_finalize,
    .class_init = kvm_arm_its_class_init,
    .class_size = sizeof(KVMARMITSClass),
};

static void kvm_arm_its_register_types(void)
{
    type_register_static(&kvm_arm_its_info);
}

type_init(kvm_arm_its_register_types)
