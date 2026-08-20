/*
 *  x86 SMM helpers (system-only)
 *
 *  Copyright (c) 2003 Fabrice Bellard
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
#include "cpu.h"
#include "exec/helper-proto.h"
#include "exec/log.h"
#include "tcg/helper-tcg.h"

typedef struct QEMU_PACKED IntelSmmSaveState64 {
    uint8_t reserved_7c00[0x1d0];
    uint32_t gdt_base_hi;
    uint32_t ldt_base_hi;
    uint32_t idt_base_hi;
    uint8_t reserved_7ddc[0x64];
    uint32_t cr4;
    uint8_t reserved_7e44[0x48];
    uint32_t gdt_base_lo;
    uint32_t reserved_7e90;
    uint32_t idt_base_lo;
    uint32_t reserved_7e98;
    uint32_t ldt_base_lo;
    uint8_t reserved_7ea0[0x58];
    uint32_t smbase;
    uint32_t smm_rev_id;
    uint16_t io_restart;
    uint16_t auto_halt_restart;
    uint8_t reserved_7f04[0x18];
    uint64_t r15;
    uint64_t r14;
    uint64_t r13;
    uint64_t r12;
    uint64_t r11;
    uint64_t r10;
    uint64_t r9;
    uint64_t r8;
    uint64_t rax;
    uint64_t rcx;
    uint64_t rdx;
    uint64_t rbx;
    uint64_t rsp;
    uint64_t rbp;
    uint64_t rsi;
    uint64_t rdi;
    uint64_t io_mem_addr;
    uint32_t io_misc;
    uint32_t es;
    uint32_t cs;
    uint32_t ss;
    uint32_t ds;
    uint32_t fs;
    uint32_t gs;
    uint32_t ldtr;
    uint32_t tr;
    uint64_t dr7;
    uint64_t dr6;
    uint64_t rip;
    uint64_t efer;
    uint64_t rflags;
    uint64_t cr3;
    uint64_t cr0;
} IntelSmmSaveState64;

QEMU_BUILD_BUG_ON(sizeof(IntelSmmSaveState64) != 0x400);
QEMU_BUILD_BUG_ON(offsetof(IntelSmmSaveState64, smm_rev_id) != 0x2fc);
QEMU_BUILD_BUG_ON(offsetof(IntelSmmSaveState64, rax) != 0x35c);
QEMU_BUILD_BUG_ON(offsetof(IntelSmmSaveState64, io_misc) != 0x3a4);
QEMU_BUILD_BUG_ON(offsetof(IntelSmmSaveState64, cr0) != 0x3f8);

static void sm_state_init_64_amd(X86CPU *cpu)
{
#ifdef TARGET_X86_64
    CPUX86State *env = &cpu->env;
    CPUState *cs = CPU(cpu);
    SegmentCache *dt;
    int i, offset;
    target_ulong sm_state = env->smbase + 0x8000;

    for (i = 0; i < 6; i++) {
        dt = &env->segs[i];
        offset = 0x7e00 + i * 16;
        x86_stw_phys(cs, sm_state + offset, dt->selector);
        x86_stw_phys(cs, sm_state + offset + 2, (dt->flags >> 8) & 0xf0ff);
        x86_stl_phys(cs, sm_state + offset + 4, dt->limit);
        x86_stq_phys(cs, sm_state + offset + 8, dt->base);
    }

    x86_stq_phys(cs, sm_state + 0x7e68, env->gdt.base);
    x86_stl_phys(cs, sm_state + 0x7e64, env->gdt.limit);

    x86_stw_phys(cs, sm_state + 0x7e70, env->ldt.selector);
    x86_stq_phys(cs, sm_state + 0x7e78, env->ldt.base);
    x86_stl_phys(cs, sm_state + 0x7e74, env->ldt.limit);
    x86_stw_phys(cs, sm_state + 0x7e72, (env->ldt.flags >> 8) & 0xf0ff);

    x86_stq_phys(cs, sm_state + 0x7e88, env->idt.base);
    x86_stl_phys(cs, sm_state + 0x7e84, env->idt.limit);

    x86_stw_phys(cs, sm_state + 0x7e90, env->tr.selector);
    x86_stq_phys(cs, sm_state + 0x7e98, env->tr.base);
    x86_stl_phys(cs, sm_state + 0x7e94, env->tr.limit);
    x86_stw_phys(cs, sm_state + 0x7e92, (env->tr.flags >> 8) & 0xf0ff);

    /* ??? Vol 1, 16.5.6 Intel MPX and SMM says that IA32_BNDCFGS
       is saved at offset 7ED0.  Vol 3, 34.4.1.1, Table 32-2, has
       7EA0-7ED7 as "reserved".  What's this, and what's really
       supposed to happen?  */
    x86_stq_phys(cs, sm_state + 0x7ed0, env->efer);

    x86_stq_phys(cs, sm_state + 0x7ff8, env->regs[R_EAX]);
    x86_stq_phys(cs, sm_state + 0x7ff0, env->regs[R_ECX]);
    x86_stq_phys(cs, sm_state + 0x7fe8, env->regs[R_EDX]);
    x86_stq_phys(cs, sm_state + 0x7fe0, env->regs[R_EBX]);
    x86_stq_phys(cs, sm_state + 0x7fd8, env->regs[R_ESP]);
    x86_stq_phys(cs, sm_state + 0x7fd0, env->regs[R_EBP]);
    x86_stq_phys(cs, sm_state + 0x7fc8, env->regs[R_ESI]);
    x86_stq_phys(cs, sm_state + 0x7fc0, env->regs[R_EDI]);
    for (i = 8; i < 16; i++) {
        x86_stq_phys(cs, sm_state + 0x7ff8 - i * 8, env->regs[i]);
    }
    x86_stq_phys(cs, sm_state + 0x7f78, env->eip);
    x86_stl_phys(cs, sm_state + 0x7f70, cpu_compute_eflags(env));
    x86_stl_phys(cs, sm_state + 0x7f68, env->dr[6]);
    x86_stl_phys(cs, sm_state + 0x7f60, env->dr[7]);

    x86_stl_phys(cs, sm_state + 0x7f48, env->cr[4]);
    x86_stq_phys(cs, sm_state + 0x7f50, env->cr[3]);
    x86_stl_phys(cs, sm_state + 0x7f58, env->cr[0]);

    x86_stl_phys(cs, sm_state + 0x7efc, 0x00020064);    /* SMM revision ID */
    x86_stl_phys(cs, sm_state + 0x7f00, env->smbase);
#else
    g_assert_not_reached();
#endif
}

static void sm_state_init_64_intel(X86CPU *cpu)
{
#ifdef TARGET_X86_64
    CPUX86State *env = &cpu->env;
    CPUState *cs = CPU(cpu);
    target_ulong sm_state = env->smbase + 0x8000;
    int i;

    memcpy(env->smm_saved_segs, env->segs, sizeof(env->segs));
    env->smm_saved_ldt = env->ldt;
    env->smm_saved_tr = env->tr;
    env->smm_saved_gdt = env->gdt;
    env->smm_saved_idt = env->idt;

    x86_stl_phys(cs, sm_state + 0x7dd0, env->gdt.base >> 32);
    x86_stl_phys(cs, sm_state + 0x7dd4, env->ldt.base >> 32);
    x86_stl_phys(cs, sm_state + 0x7dd8, env->idt.base >> 32);
    x86_stl_phys(cs, sm_state + 0x7e40, env->cr[4]);
    x86_stl_phys(cs, sm_state + 0x7e8c, env->gdt.base);
    x86_stl_phys(cs, sm_state + 0x7e94, env->idt.base);
    x86_stl_phys(cs, sm_state + 0x7e9c, env->ldt.base);

    x86_stl_phys(cs, sm_state + 0x7ef8, env->smbase);
    x86_stl_phys(cs, sm_state + 0x7efc, 0x00030004);
    x86_stw_phys(cs, sm_state + 0x7f00, 0); /* I/O restart */
    x86_stw_phys(cs, sm_state + 0x7f02, 0); /* Auto-HALT restart */

    for (i = 8; i < 16; i++) {
        x86_stq_phys(cs, sm_state + 0x7f54 - (i - 8) * 8,
                     env->regs[i]);
    }
    x86_stq_phys(cs, sm_state + 0x7f5c, env->regs[R_EAX]);
    x86_stq_phys(cs, sm_state + 0x7f64, env->regs[R_ECX]);
    x86_stq_phys(cs, sm_state + 0x7f6c, env->regs[R_EDX]);
    x86_stq_phys(cs, sm_state + 0x7f74, env->regs[R_EBX]);
    x86_stq_phys(cs, sm_state + 0x7f7c, env->regs[R_ESP]);
    x86_stq_phys(cs, sm_state + 0x7f84, env->regs[R_EBP]);
    x86_stq_phys(cs, sm_state + 0x7f8c, env->regs[R_ESI]);
    x86_stq_phys(cs, sm_state + 0x7f94, env->regs[R_EDI]);

    x86_stq_phys(cs, sm_state + 0x7f9c, 0); /* I/O memory address */
    x86_stl_phys(cs, sm_state + 0x7fa4,
                 env->smm_io_pending ? env->smm_io_info : 0);
    env->smm_io_pending = false;

    for (i = 0; i < 6; i++) {
        x86_stl_phys(cs, sm_state + 0x7fa8 + i * 4,
                     env->segs[i].selector);
    }
    x86_stl_phys(cs, sm_state + 0x7fc0, env->ldt.selector);
    x86_stl_phys(cs, sm_state + 0x7fc4, env->tr.selector);
    x86_stq_phys(cs, sm_state + 0x7fc8, env->dr[7]);
    x86_stq_phys(cs, sm_state + 0x7fd0, env->dr[6]);
    x86_stq_phys(cs, sm_state + 0x7fd8, env->eip);
    x86_stq_phys(cs, sm_state + 0x7fe0, env->efer);
    x86_stq_phys(cs, sm_state + 0x7fe8, cpu_compute_eflags(env));
    x86_stq_phys(cs, sm_state + 0x7ff0, env->cr[3]);
    x86_stq_phys(cs, sm_state + 0x7ff8, env->cr[0]);
#else
    g_assert_not_reached();
#endif
}

static void sm_state_init_32(X86CPU *cpu)
{
    CPUX86State *env = &cpu->env;
    CPUState *cs = CPU(cpu);
    SegmentCache *dt;
    int i, offset;
    target_ulong sm_state = env->smbase + 0x8000;

    x86_stl_phys(cs, sm_state + 0x7ffc, env->cr[0]);
    x86_stl_phys(cs, sm_state + 0x7ff8, env->cr[3]);
    x86_stl_phys(cs, sm_state + 0x7ff4, cpu_compute_eflags(env));
    x86_stl_phys(cs, sm_state + 0x7ff0, env->eip);
    x86_stl_phys(cs, sm_state + 0x7fec, env->regs[R_EDI]);
    x86_stl_phys(cs, sm_state + 0x7fe8, env->regs[R_ESI]);
    x86_stl_phys(cs, sm_state + 0x7fe4, env->regs[R_EBP]);
    x86_stl_phys(cs, sm_state + 0x7fe0, env->regs[R_ESP]);
    x86_stl_phys(cs, sm_state + 0x7fdc, env->regs[R_EBX]);
    x86_stl_phys(cs, sm_state + 0x7fd8, env->regs[R_EDX]);
    x86_stl_phys(cs, sm_state + 0x7fd4, env->regs[R_ECX]);
    x86_stl_phys(cs, sm_state + 0x7fd0, env->regs[R_EAX]);
    x86_stl_phys(cs, sm_state + 0x7fcc, env->dr[6]);
    x86_stl_phys(cs, sm_state + 0x7fc8, env->dr[7]);

    x86_stl_phys(cs, sm_state + 0x7fc4, env->tr.selector);
    x86_stl_phys(cs, sm_state + 0x7f64, env->tr.base);
    x86_stl_phys(cs, sm_state + 0x7f60, env->tr.limit);
    x86_stl_phys(cs, sm_state + 0x7f5c, (env->tr.flags >> 8) & 0xf0ff);

    x86_stl_phys(cs, sm_state + 0x7fc0, env->ldt.selector);
    x86_stl_phys(cs, sm_state + 0x7f80, env->ldt.base);
    x86_stl_phys(cs, sm_state + 0x7f7c, env->ldt.limit);
    x86_stl_phys(cs, sm_state + 0x7f78, (env->ldt.flags >> 8) & 0xf0ff);

    x86_stl_phys(cs, sm_state + 0x7f74, env->gdt.base);
    x86_stl_phys(cs, sm_state + 0x7f70, env->gdt.limit);

    x86_stl_phys(cs, sm_state + 0x7f58, env->idt.base);
    x86_stl_phys(cs, sm_state + 0x7f54, env->idt.limit);

    for (i = 0; i < 6; i++) {
        dt = &env->segs[i];
        if (i < 3) {
            offset = 0x7f84 + i * 12;
        } else {
            offset = 0x7f2c + (i - 3) * 12;
        }
        x86_stl_phys(cs, sm_state + 0x7fa8 + i * 4, dt->selector);
        x86_stl_phys(cs, sm_state + offset + 8, dt->base);
        x86_stl_phys(cs, sm_state + offset + 4, dt->limit);
        x86_stl_phys(cs, sm_state + offset, (dt->flags >> 8) & 0xf0ff);
    }
    x86_stl_phys(cs, sm_state + 0x7f14, env->cr[4]);

    x86_stl_phys(cs, sm_state + 0x7efc, 0x00020000);   /* SMM revision ID */
    x86_stl_phys(cs, sm_state + 0x7ef8, env->smbase);
}

void do_smm_enter(X86CPU *cpu)
{
    CPUX86State *env = &cpu->env;

    qemu_log_mask(CPU_LOG_INT, "SMM: enter\n");
    log_cpu_state_mask(CPU_LOG_INT, CPU(cpu), CPU_DUMP_CCOP);

    env->msr_smi_count++;
    env->hflags |= HF_SMM_MASK;
    if (env->hflags2 & HF2_NMI_MASK) {
        env->hflags2 |= HF2_SMM_INSIDE_NMI_MASK;
    } else {
        env->hflags2 |= HF2_NMI_MASK;
    }

    if (env->features[FEAT_8000_0001_EDX] & CPUID_EXT2_LM) {
        if (IS_INTEL_CPU(env)) {
            sm_state_init_64_intel(cpu);
        } else {
            sm_state_init_64_amd(cpu);
        }
        cpu_load_efer(env, 0);
    } else {
        sm_state_init_32(cpu);
    }

    /* init SMM cpu state */

    cpu_load_eflags(env, 0, ~(CC_O | CC_S | CC_Z | CC_A | CC_P | CC_C |
                              DF_MASK));
    env->eip = 0x00008000;
    cpu_x86_update_cr0(env,
                       env->cr[0] & ~(CR0_PE_MASK | CR0_EM_MASK | CR0_TS_MASK |
                                      CR0_PG_MASK));
    cpu_x86_update_cr4(env, 0);
    helper_set_dr(env, 7, 0x00000400);

    cpu_x86_load_seg_cache(env, R_CS, (env->smbase >> 4) & 0xffff, env->smbase,
                           0xffffffff,
                           DESC_P_MASK | DESC_S_MASK | DESC_W_MASK |
                           DESC_G_MASK | DESC_A_MASK);
    cpu_x86_load_seg_cache(env, R_DS, 0, 0, 0xffffffff,
                           DESC_P_MASK | DESC_S_MASK | DESC_W_MASK |
                           DESC_G_MASK | DESC_A_MASK);
    cpu_x86_load_seg_cache(env, R_ES, 0, 0, 0xffffffff,
                           DESC_P_MASK | DESC_S_MASK | DESC_W_MASK |
                           DESC_G_MASK | DESC_A_MASK);
    cpu_x86_load_seg_cache(env, R_SS, 0, 0, 0xffffffff,
                           DESC_P_MASK | DESC_S_MASK | DESC_W_MASK |
                           DESC_G_MASK | DESC_A_MASK);
    cpu_x86_load_seg_cache(env, R_FS, 0, 0, 0xffffffff,
                           DESC_P_MASK | DESC_S_MASK | DESC_W_MASK |
                           DESC_G_MASK | DESC_A_MASK);
    cpu_x86_load_seg_cache(env, R_GS, 0, 0, 0xffffffff,
                           DESC_P_MASK | DESC_S_MASK | DESC_W_MASK |
                           DESC_G_MASK | DESC_A_MASK);
}

static void rsm_load_regs_64_amd(CPUX86State *env)
{
#ifdef TARGET_X86_64
    CPUState *cs = env_cpu(env);
    target_ulong sm_state;
    int i, offset;
    uint32_t val;

    sm_state = env->smbase + 0x8000;

    cpu_load_efer(env, x86_ldq_phys(cs, sm_state + 0x7ed0));

    env->gdt.base = x86_ldq_phys(cs, sm_state + 0x7e68);
    env->gdt.limit = x86_ldl_phys(cs, sm_state + 0x7e64);

    env->ldt.selector = x86_lduw_phys(cs, sm_state + 0x7e70);
    env->ldt.base = x86_ldq_phys(cs, sm_state + 0x7e78);
    env->ldt.limit = x86_ldl_phys(cs, sm_state + 0x7e74);
    env->ldt.flags = (x86_lduw_phys(cs, sm_state + 0x7e72) & 0xf0ff) << 8;

    env->idt.base = x86_ldq_phys(cs, sm_state + 0x7e88);
    env->idt.limit = x86_ldl_phys(cs, sm_state + 0x7e84);

    env->tr.selector = x86_lduw_phys(cs, sm_state + 0x7e90);
    env->tr.base = x86_ldq_phys(cs, sm_state + 0x7e98);
    env->tr.limit = x86_ldl_phys(cs, sm_state + 0x7e94);
    env->tr.flags = (x86_lduw_phys(cs, sm_state + 0x7e92) & 0xf0ff) << 8;

    env->regs[R_EAX] = x86_ldq_phys(cs, sm_state + 0x7ff8);
    env->regs[R_ECX] = x86_ldq_phys(cs, sm_state + 0x7ff0);
    env->regs[R_EDX] = x86_ldq_phys(cs, sm_state + 0x7fe8);
    env->regs[R_EBX] = x86_ldq_phys(cs, sm_state + 0x7fe0);
    env->regs[R_ESP] = x86_ldq_phys(cs, sm_state + 0x7fd8);
    env->regs[R_EBP] = x86_ldq_phys(cs, sm_state + 0x7fd0);
    env->regs[R_ESI] = x86_ldq_phys(cs, sm_state + 0x7fc8);
    env->regs[R_EDI] = x86_ldq_phys(cs, sm_state + 0x7fc0);
    for (i = 8; i < 16; i++) {
        env->regs[i] = x86_ldq_phys(cs, sm_state + 0x7ff8 - i * 8);
    }
    env->eip = x86_ldq_phys(cs, sm_state + 0x7f78);
    cpu_load_eflags(env, x86_ldl_phys(cs, sm_state + 0x7f70),
                    ~(CC_O | CC_S | CC_Z | CC_A | CC_P | CC_C | DF_MASK));
    helper_set_dr(env, 6, x86_ldl_phys(cs, sm_state + 0x7f68));
    helper_set_dr(env, 7, x86_ldl_phys(cs, sm_state + 0x7f60));

    cpu_x86_update_cr4(env, x86_ldl_phys(cs, sm_state + 0x7f48));
    cpu_x86_update_cr3(env, x86_ldq_phys(cs, sm_state + 0x7f50));
    cpu_x86_update_cr0(env, x86_ldl_phys(cs, sm_state + 0x7f58));

    for (i = 0; i < 6; i++) {
        offset = 0x7e00 + i * 16;
        cpu_x86_load_seg_cache(env, i,
                               x86_lduw_phys(cs, sm_state + offset),
                               x86_ldq_phys(cs, sm_state + offset + 8),
                               x86_ldl_phys(cs, sm_state + offset + 4),
                               (x86_lduw_phys(cs, sm_state + offset + 2) &
                                0xf0ff) << 8);
    }

    val = x86_ldl_phys(cs, sm_state + 0x7efc); /* revision ID */
    if (val & 0x20000) {
        env->smbase = x86_ldl_phys(cs, sm_state + 0x7f00);
    }
#else
    g_assert_not_reached();
#endif
}

static void rsm_load_regs_64_intel(CPUX86State *env)
{
#ifdef TARGET_X86_64
    CPUState *cs = env_cpu(env);
    target_ulong sm_state = env->smbase + 0x8000;
    uint64_t base;
    uint32_t val;
    int i;

    cpu_load_efer(env, x86_ldq_phys(cs, sm_state + 0x7fe0));

    env->regs[R_EAX] = x86_ldq_phys(cs, sm_state + 0x7f5c);
    env->regs[R_ECX] = x86_ldq_phys(cs, sm_state + 0x7f64);
    env->regs[R_EDX] = x86_ldq_phys(cs, sm_state + 0x7f6c);
    env->regs[R_EBX] = x86_ldq_phys(cs, sm_state + 0x7f74);
    env->regs[R_ESP] = x86_ldq_phys(cs, sm_state + 0x7f7c);
    env->regs[R_EBP] = x86_ldq_phys(cs, sm_state + 0x7f84);
    env->regs[R_ESI] = x86_ldq_phys(cs, sm_state + 0x7f8c);
    env->regs[R_EDI] = x86_ldq_phys(cs, sm_state + 0x7f94);
    for (i = 8; i < 16; i++) {
        env->regs[i] = x86_ldq_phys(cs,
                                    sm_state + 0x7f54 - (i - 8) * 8);
    }

    env->eip = x86_ldq_phys(cs, sm_state + 0x7fd8);
    cpu_load_eflags(env, x86_ldq_phys(cs, sm_state + 0x7fe8),
                    ~(CC_O | CC_S | CC_Z | CC_A | CC_P | CC_C | DF_MASK));
    helper_set_dr(env, 6, x86_ldq_phys(cs, sm_state + 0x7fd0));
    helper_set_dr(env, 7, x86_ldq_phys(cs, sm_state + 0x7fc8));

    cpu_x86_update_cr4(env, x86_ldl_phys(cs, sm_state + 0x7e40));
    cpu_x86_update_cr3(env, x86_ldq_phys(cs, sm_state + 0x7ff0));
    cpu_x86_update_cr0(env, x86_ldq_phys(cs, sm_state + 0x7ff8));

    for (i = 0; i < 6; i++) {
        cpu_x86_load_seg_cache(env, i,
                               x86_ldl_phys(cs,
                                             sm_state + 0x7fa8 + i * 4),
                               env->smm_saved_segs[i].base,
                               env->smm_saved_segs[i].limit,
                               env->smm_saved_segs[i].flags);
    }

    base = (uint64_t)x86_ldl_phys(cs, sm_state + 0x7dd0) << 32;
    base |= x86_ldl_phys(cs, sm_state + 0x7e8c);
    env->gdt = env->smm_saved_gdt;
    env->gdt.base = base;

    base = (uint64_t)x86_ldl_phys(cs, sm_state + 0x7dd8) << 32;
    base |= x86_ldl_phys(cs, sm_state + 0x7e94);
    env->idt = env->smm_saved_idt;
    env->idt.base = base;

    base = (uint64_t)x86_ldl_phys(cs, sm_state + 0x7dd4) << 32;
    base |= x86_ldl_phys(cs, sm_state + 0x7e9c);
    env->ldt = env->smm_saved_ldt;
    env->ldt.selector = x86_ldl_phys(cs, sm_state + 0x7fc0);
    env->ldt.base = base;

    env->tr = env->smm_saved_tr;
    env->tr.selector = x86_ldl_phys(cs, sm_state + 0x7fc4);

    val = x86_ldl_phys(cs, sm_state + 0x7efc);
    if (val & 0x20000) {
        env->smbase = x86_ldl_phys(cs, sm_state + 0x7ef8);
    }
#else
    g_assert_not_reached();
#endif
}

static void rsm_load_regs_32(CPUX86State *env)
{
    CPUState *cs = env_cpu(env);
    target_ulong sm_state;
    int i, offset;
    uint32_t val;

    sm_state = env->smbase + 0x8000;

    cpu_x86_update_cr0(env, x86_ldl_phys(cs, sm_state + 0x7ffc));
    cpu_x86_update_cr3(env, x86_ldl_phys(cs, sm_state + 0x7ff8));
    cpu_load_eflags(env, x86_ldl_phys(cs, sm_state + 0x7ff4),
                    ~(CC_O | CC_S | CC_Z | CC_A | CC_P | CC_C | DF_MASK));
    env->eip = x86_ldl_phys(cs, sm_state + 0x7ff0);
    env->regs[R_EDI] = x86_ldl_phys(cs, sm_state + 0x7fec);
    env->regs[R_ESI] = x86_ldl_phys(cs, sm_state + 0x7fe8);
    env->regs[R_EBP] = x86_ldl_phys(cs, sm_state + 0x7fe4);
    env->regs[R_ESP] = x86_ldl_phys(cs, sm_state + 0x7fe0);
    env->regs[R_EBX] = x86_ldl_phys(cs, sm_state + 0x7fdc);
    env->regs[R_EDX] = x86_ldl_phys(cs, sm_state + 0x7fd8);
    env->regs[R_ECX] = x86_ldl_phys(cs, sm_state + 0x7fd4);
    env->regs[R_EAX] = x86_ldl_phys(cs, sm_state + 0x7fd0);
    helper_set_dr(env, 6, x86_ldl_phys(cs, sm_state + 0x7fcc));
    helper_set_dr(env, 7, x86_ldl_phys(cs, sm_state + 0x7fc8));

    env->tr.selector = x86_ldl_phys(cs, sm_state + 0x7fc4) & 0xffff;
    env->tr.base = x86_ldl_phys(cs, sm_state + 0x7f64);
    env->tr.limit = x86_ldl_phys(cs, sm_state + 0x7f60);
    env->tr.flags = (x86_ldl_phys(cs, sm_state + 0x7f5c) & 0xf0ff) << 8;

    env->ldt.selector = x86_ldl_phys(cs, sm_state + 0x7fc0) & 0xffff;
    env->ldt.base = x86_ldl_phys(cs, sm_state + 0x7f80);
    env->ldt.limit = x86_ldl_phys(cs, sm_state + 0x7f7c);
    env->ldt.flags = (x86_ldl_phys(cs, sm_state + 0x7f78) & 0xf0ff) << 8;

    env->gdt.base = x86_ldl_phys(cs, sm_state + 0x7f74);
    env->gdt.limit = x86_ldl_phys(cs, sm_state + 0x7f70);

    env->idt.base = x86_ldl_phys(cs, sm_state + 0x7f58);
    env->idt.limit = x86_ldl_phys(cs, sm_state + 0x7f54);

    for (i = 0; i < 6; i++) {
        if (i < 3) {
            offset = 0x7f84 + i * 12;
        } else {
            offset = 0x7f2c + (i - 3) * 12;
        }
        cpu_x86_load_seg_cache(env, i,
                               x86_ldl_phys(cs,
                                        sm_state + 0x7fa8 + i * 4) & 0xffff,
                               x86_ldl_phys(cs, sm_state + offset + 8),
                               x86_ldl_phys(cs, sm_state + offset + 4),
                               (x86_ldl_phys(cs,
                                         sm_state + offset) & 0xf0ff) << 8);
    }
    cpu_x86_update_cr4(env, x86_ldl_phys(cs, sm_state + 0x7f14));

    val = x86_ldl_phys(cs, sm_state + 0x7efc); /* revision ID */
    if (val & 0x20000) {
        env->smbase = x86_ldl_phys(cs, sm_state + 0x7ef8);
    }
}

void helper_rsm(CPUX86State *env)
{
    X86CPU *cpu = env_archcpu(env);

    if (env->features[FEAT_8000_0001_EDX] & CPUID_EXT2_LM) {
        if (IS_INTEL_CPU(env)) {
            rsm_load_regs_64_intel(env);
        } else {
            rsm_load_regs_64_amd(env);
        }
    } else {
        rsm_load_regs_32(env);
    }

    if ((env->hflags2 & HF2_SMM_INSIDE_NMI_MASK) == 0) {
        env->hflags2 &= ~HF2_NMI_MASK;
    }
    env->hflags2 &= ~HF2_SMM_INSIDE_NMI_MASK;
    env->hflags &= ~HF_SMM_MASK;

    qemu_log_mask(CPU_LOG_INT, "SMM: after RSM\n");
    log_cpu_state_mask(CPU_LOG_INT, CPU(cpu), CPU_DUMP_CCOP);
}
