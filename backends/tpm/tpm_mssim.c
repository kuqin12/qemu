/*
 *  Microsoft TPM simulator (mssim) TCP backend driver
 *
 *  Copyright (c) 2026
 *
 *  This backend connects QEMU's TPM frontend to a TPM 2.0 simulator that
 *  speaks the TCG "mssim" TCP protocol, such as the TCG TPM 2.0 reference
 *  implementation at https://github.com/TrustedComputingGroup/TPM.  Unlike
 *  the swtpm "emulator" backend, the mssim protocol is a plain TCP stream and
 *  does not rely on UNIX-domain sockets or file-descriptor passing, so it
 *  works on hosts (e.g. native Windows) that lack those POSIX facilities.
 *
 * This work is licensed under the terms of the GNU GPL, version 2 or later.
 * See the COPYING file in the top-level directory.
 */

#include "qemu/osdep.h"
#include "qemu/error-report.h"
#include "qemu/module.h"
#include "qemu/cutils.h"
#include "qemu/lockable.h"
#include "io/channel-socket.h"
#include "system/tpm_backend.h"
#include "system/tpm_util.h"
#include "tpm_int.h"
#include "qapi/error.h"
#include "qapi/clone-visitor.h"
#include "qapi/qapi-visit-tpm.h"
#include "trace.h"
#include "qom/object.h"

#define TYPE_TPM_MSSIM "tpm-mssim"
OBJECT_DECLARE_SIMPLE_TYPE(TPMMssim, TPM_MSSIM)

#define TPM_MSSIM_DEFAULT_HOST "127.0.0.1"
#define TPM_MSSIM_DEFAULT_PORT "2321"

/*
 * mssim TCP interface command codes; see TpmTcpProtocol.h in the TCG TPM 2.0
 * reference implementation. All integers on the wire are big-endian.
 */
#define MSSIM_SIGNAL_POWER_ON   1
#define MSSIM_SIGNAL_POWER_OFF  2
#define MSSIM_SEND_COMMAND      8
#define MSSIM_SIGNAL_CANCEL_ON  9
#define MSSIM_SIGNAL_CANCEL_OFF 10
#define MSSIM_SIGNAL_NV_ON      11
#define MSSIM_SIGNAL_NV_OFF     12
#define MSSIM_SESSION_END       20

struct TPMMssim {
    TPMBackend parent;

    TPMMssimOptions *options;

    QIOChannelSocket *cmd_ioc;   /* command port */
    QIOChannelSocket *plat_ioc;  /* platform port (command port + 1) */

    TPMVersion tpm_version;

    /* Serializes access to the platform port (startup, cancel). */
    QemuMutex mutex;
};

static int tpm_mssim_write_u32(QIOChannel *ioc, uint32_t val, Error **errp)
{
    uint32_t be = cpu_to_be32(val);

    return qio_channel_write_all(ioc, (const char *)&be, sizeof(be), errp);
}

static int tpm_mssim_read_u32(QIOChannel *ioc, uint32_t *val, Error **errp)
{
    uint32_t be;

    if (qio_channel_read_all(ioc, (char *)&be, sizeof(be), errp) < 0) {
        return -1;
    }
    *val = be32_to_cpu(be);
    return 0;
}

static QIOChannelSocket *tpm_mssim_connect(const char *host, const char *port,
                                           Error **errp)
{
    QIOChannelSocket *ioc;
    SocketAddress *addr = g_new0(SocketAddress, 1);

    addr->type = SOCKET_ADDRESS_TYPE_INET;
    addr->u.inet = (InetSocketAddress) {
        .host = g_strdup(host),
        .port = g_strdup(port),
    };

    ioc = qio_channel_socket_new();
    if (qio_channel_socket_connect_sync(ioc, addr, errp) < 0) {
        object_unref(OBJECT(ioc));
        ioc = NULL;
    }

    qapi_free_SocketAddress(addr);
    return ioc;
}

/*
 * Send a single platform signal and wait for its acknowledgement. The
 * caller must hold tpm_mssim->mutex.
 */
static int tpm_mssim_platform_signal(TPMMssim *m, uint32_t sig, Error **errp)
{
    QIOChannel *ioc = QIO_CHANNEL(m->plat_ioc);
    uint32_t ack;

    if (tpm_mssim_write_u32(ioc, sig, errp) < 0 ||
        tpm_mssim_read_u32(ioc, &ack, errp) < 0) {
        return -1;
    }
    if (ack != 0) {
        error_setg(errp, "tpm-mssim: platform signal 0x%x failed (ack 0x%x)",
                   sig, ack);
        return -1;
    }
    return 0;
}

/*
 * Exchange a single TPM command/response on the command port using the
 * mssim TPM_SEND_COMMAND envelope:
 *   send: u32 cmd, u8 locality, u32 length, command bytes
 *   recv: u32 length, response bytes, u32 acknowledgement
 */
static int tpm_mssim_do_command(TPMMssim *m, const TPMBackendCmd *cmd,
                                uint32_t *actual_len, Error **errp)
{
    QIOChannel *ioc = QIO_CHANNEL(m->cmd_ioc);
    uint8_t locty = cmd->locty;
    uint32_t resp_len, ack;

    if (tpm_mssim_write_u32(ioc, MSSIM_SEND_COMMAND, errp) < 0 ||
        qio_channel_write_all(ioc, (const char *)&locty, 1, errp) < 0 ||
        tpm_mssim_write_u32(ioc, cmd->in_len, errp) < 0 ||
        qio_channel_write_all(ioc, (const char *)cmd->in, cmd->in_len,
                              errp) < 0) {
        return -1;
    }

    if (tpm_mssim_read_u32(ioc, &resp_len, errp) < 0) {
        return -1;
    }
    if (resp_len > cmd->out_len) {
        error_setg(errp,
                   "tpm-mssim: response of %u bytes exceeds buffer of %u bytes",
                   resp_len, cmd->out_len);
        return -1;
    }
    if (qio_channel_read_all(ioc, (char *)cmd->out, resp_len, errp) < 0) {
        return -1;
    }
    if (tpm_mssim_read_u32(ioc, &ack, errp) < 0) {
        return -1;
    }

    if (actual_len) {
        *actual_len = resp_len;
    }
    return 0;
}

static void tpm_mssim_handle_request(TPMBackend *tb, TPMBackendCmd *cmd,
                                     Error **errp)
{
    TPMMssim *m = TPM_MSSIM(tb);

    trace_tpm_mssim_handle_request();

    if (tpm_mssim_do_command(m, cmd, NULL, errp) < 0) {
        tpm_util_write_fatal_error_response(cmd->out, cmd->out_len);
    }
}

/*
 * Probe the simulator with a TPM2_GetCapability command to confirm a live
 * TPM 2.0 is reachable and that the command-channel framing works.
 *
 * At device-creation time the guest firmware has not yet issued TPM2_Startup,
 * so the simulator legitimately answers with TPM_RC_INITIALIZE (0x100). That
 * still proves a live TPM 2.0 is on the other end, so any well-formed TPM 2.0
 * response (recognized tag) is accepted; the backend must not send Startup
 * itself, as the guest firmware owns that step.
 */
static int tpm_mssim_probe(TPMMssim *m, Error **errp)
{
    static const uint8_t getcap[] = {
        0x80, 0x01,             /* TPM_ST_NO_SESSIONS */
        0x00, 0x00, 0x00, 0x16, /* commandSize = 22 */
        0x00, 0x00, 0x01, 0x7a, /* TPM2_CC_GetCapability */
        0x00, 0x00, 0x00, 0x06, /* TPM_CAP_TPM_PROPERTIES */
        0x00, 0x00, 0x01, 0x00, /* TPM_PT_FAMILY_INDICATOR */
        0x00, 0x00, 0x00, 0x01, /* propertyCount = 1 */
    };
    uint8_t resp[64];
    uint32_t resp_len = 0;
    uint16_t tag;
    const TPMBackendCmd cmd = {
        .locty = 0,
        .in = getcap,
        .in_len = sizeof(getcap),
        .out = resp,
        .out_len = sizeof(resp),
    };

    if (tpm_mssim_do_command(m, &cmd, &resp_len, errp) < 0) {
        return -1;
    }
    if (resp_len < 10) {
        error_setg(errp, "tpm-mssim: short response (%u bytes) to probe; is "
                   "'%s:%s' a TPM 2.0 simulator?",
                   resp_len, m->options->host, m->options->port);
        return -1;
    }
    tag = lduw_be_p(resp);
    if (tag != 0x8001 && tag != 0x8002) {
        error_setg(errp, "tpm-mssim: unexpected response tag 0x%04x; '%s:%s' "
                   "does not look like a TPM 2.0 simulator",
                   tag, m->options->host, m->options->port);
        return -1;
    }

    return 0;
}

static int tpm_mssim_startup_tpm(TPMBackend *tb, size_t buffersize)
{
    TPMMssim *m = TPM_MSSIM(tb);
    Error *err = NULL;
    int ret = 0;

    WITH_QEMU_LOCK_GUARD(&m->mutex) {
        if (tpm_mssim_platform_signal(m, MSSIM_SIGNAL_POWER_ON, &err) < 0 ||
            tpm_mssim_platform_signal(m, MSSIM_SIGNAL_NV_ON, &err) < 0) {
            error_report_err(err);
            ret = -1;
        }
    }
    return ret;
}

static void tpm_mssim_cancel_cmd(TPMBackend *tb)
{
    TPMMssim *m = TPM_MSSIM(tb);
    Error *err = NULL;

    /*
     * The mssim platform interface has no single asynchronous cancel; assert
     * and immediately deassert the cancel signal. This runs on the platform
     * port, independently of an in-flight command on the command port.
     */
    WITH_QEMU_LOCK_GUARD(&m->mutex) {
        if (tpm_mssim_platform_signal(m, MSSIM_SIGNAL_CANCEL_ON, &err) < 0 ||
            tpm_mssim_platform_signal(m, MSSIM_SIGNAL_CANCEL_OFF, &err) < 0) {
            error_report_err(err);
        }
    }
}

static TPMVersion tpm_mssim_get_tpm_version(TPMBackend *tb)
{
    TPMMssim *m = TPM_MSSIM(tb);

    return m->tpm_version;
}

static size_t tpm_mssim_get_buffer_size(TPMBackend *tb)
{
    /* The mssim protocol has no buffer-size negotiation; use the TPM2 min. */
    return 4096;
}

static int tpm_mssim_handle_device_opts(TPMMssim *m, QemuOpts *opts)
{
    const char *host, *port;
    unsigned long portnum;
    char *plat_port;
    Error *err = NULL;

    host = qemu_opt_get(opts, "host");
    if (!host || host[0] == '\0') {
        host = TPM_MSSIM_DEFAULT_HOST;
    }

    port = qemu_opt_get(opts, "port");
    if (!port || port[0] == '\0') {
        port = TPM_MSSIM_DEFAULT_PORT;
    }

    if (qemu_strtoul(port, NULL, 10, &portnum) < 0 ||
        portnum == 0 || portnum >= 65535) {
        error_report("tpm-mssim: invalid command port '%s'", port);
        return -1;
    }

    m->options->host = g_strdup(host);
    m->options->port = g_strdup(port);

    m->cmd_ioc = tpm_mssim_connect(host, port, &err);
    if (!m->cmd_ioc) {
        error_reportf_err(err, "tpm-mssim: cannot connect to command port "
                          "%s:%s: ", host, port);
        return -1;
    }

    /* The simulator's platform port is always the command port plus one. */
    plat_port = g_strdup_printf("%lu", portnum + 1);
    m->plat_ioc = tpm_mssim_connect(host, plat_port, &err);
    if (!m->plat_ioc) {
        error_reportf_err(err, "tpm-mssim: cannot connect to platform port "
                          "%s:%s: ", host, plat_port);
        g_free(plat_port);
        return -1;
    }
    g_free(plat_port);

    /* Power on and enable NV so the simulator can answer the probe. */
    if (tpm_mssim_platform_signal(m, MSSIM_SIGNAL_POWER_ON, &err) < 0 ||
        tpm_mssim_platform_signal(m, MSSIM_SIGNAL_NV_ON, &err) < 0) {
        error_reportf_err(err, "tpm-mssim: ");
        return -1;
    }

    if (tpm_mssim_probe(m, &err) < 0) {
        error_reportf_err(err, "tpm-mssim: ");
        return -1;
    }
    m->tpm_version = TPM_VERSION_2_0;

    return 0;
}

static TPMBackend *tpm_mssim_create(QemuOpts *opts)
{
    TPMBackend *tb = TPM_BACKEND(object_new(TYPE_TPM_MSSIM));

    if (tpm_mssim_handle_device_opts(TPM_MSSIM(tb), opts)) {
        object_unref(OBJECT(tb));
        return NULL;
    }

    return tb;
}

static TpmTypeOptions *tpm_mssim_get_tpm_options(TPMBackend *tb)
{
    TPMMssim *m = TPM_MSSIM(tb);
    TpmTypeOptions *options = g_new0(TpmTypeOptions, 1);

    options->type = TPM_TYPE_MSSIM;
    options->u.mssim.data = QAPI_CLONE(TPMMssimOptions, m->options);

    return options;
}

static const QemuOptDesc tpm_mssim_cmdline_opts[] = {
    TPM_STANDARD_CMDLINE_OPTS,
    {
        .name = "host",
        .type = QEMU_OPT_STRING,
        .help = "IP address or hostname of the TPM simulator "
                "(default 127.0.0.1)",
    },
    {
        .name = "port",
        .type = QEMU_OPT_STRING,
        .help = "command port of the TPM simulator (default 2321); "
                "the platform port is this port number plus one",
    },
    { /* end of list */ },
};

static void tpm_mssim_inst_init(Object *obj)
{
    TPMMssim *m = TPM_MSSIM(obj);

    trace_tpm_mssim_inst_init();

    m->options = g_new0(TPMMssimOptions, 1);
    m->tpm_version = TPM_VERSION_UNSPEC;
    qemu_mutex_init(&m->mutex);
}

static void tpm_mssim_inst_finalize(Object *obj)
{
    TPMMssim *m = TPM_MSSIM(obj);

    if (m->cmd_ioc) {
        /* Best-effort: tell the simulator we are done with this session. */
        Error *err = NULL;

        if (tpm_mssim_write_u32(QIO_CHANNEL(m->cmd_ioc), MSSIM_SESSION_END,
                                &err) < 0) {
            error_free(err);
        }
        qio_channel_close(QIO_CHANNEL(m->cmd_ioc), NULL);
        object_unref(OBJECT(m->cmd_ioc));
    }
    if (m->plat_ioc) {
        /* Best-effort graceful close so the simulator does not log a reset. */
        Error *err = NULL;

        if (tpm_mssim_write_u32(QIO_CHANNEL(m->plat_ioc), MSSIM_SESSION_END,
                                &err) < 0) {
            error_free(err);
        }
        qio_channel_close(QIO_CHANNEL(m->plat_ioc), NULL);
        object_unref(OBJECT(m->plat_ioc));
    }

    qapi_free_TPMMssimOptions(m->options);
    qemu_mutex_destroy(&m->mutex);
}

static void tpm_mssim_class_init(ObjectClass *klass, const void *data)
{
    TPMBackendClass *tbc = TPM_BACKEND_CLASS(klass);

    tbc->type = TPM_TYPE_MSSIM;
    tbc->opts = tpm_mssim_cmdline_opts;
    tbc->desc = "TPM mssim (Microsoft simulator) backend driver";
    tbc->create = tpm_mssim_create;
    tbc->startup_tpm = tpm_mssim_startup_tpm;
    tbc->cancel_cmd = tpm_mssim_cancel_cmd;
    tbc->get_tpm_version = tpm_mssim_get_tpm_version;
    tbc->get_buffer_size = tpm_mssim_get_buffer_size;
    tbc->get_tpm_options = tpm_mssim_get_tpm_options;
    tbc->handle_request = tpm_mssim_handle_request;
}

static const TypeInfo tpm_mssim_info = {
    .name = TYPE_TPM_MSSIM,
    .parent = TYPE_TPM_BACKEND,
    .instance_size = sizeof(TPMMssim),
    .class_init = tpm_mssim_class_init,
    .instance_init = tpm_mssim_inst_init,
    .instance_finalize = tpm_mssim_inst_finalize,
};

static void tpm_mssim_register(void)
{
    type_register_static(&tpm_mssim_info);
}

type_init(tpm_mssim_register)
