#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
build_dir=${BUILD_DIR:-"$root_dir/build"}
qemu=${QEMU:-"$build_dir/qemu-system-aarch64"}
work_dir=$(mktemp -d)
swtpm_pid=

cleanup()
{
    if [[ -n "$swtpm_pid" ]]; then
        kill "$swtpm_pid" 2>/dev/null || true
    fi
    rm -rf "$work_dir"
}
trap cleanup EXIT

swtpm socket \
    --tpm2 \
    --tpmstate "dir=$work_dir" \
    --ctrl "type=unixio,path=$work_dir/swtpm.sock" \
    --flags not-need-init \
    --daemon \
    --pid "file=$work_dir/swtpm.pid"
swtpm_pid=$(cat "$work_dir/swtpm.pid")

qmp_log="$work_dir/qmp.log"
printf '%s\n' \
    '{"execute":"qmp_capabilities"}' \
    '{"execute":"qom-get","arguments":{"path":"/machine","property":"hybrid-shared-crb-verified"}}' \
    '{"execute":"human-monitor-command","arguments":{"command-line":"info mtree -f"}}' \
    '{"execute":"quit"}' |
    "$qemu" \
        -S \
        -machine virt,hybrid-secure=on,gic-version=3 \
        -cpu host \
        -smp 1 \
        -m 256M \
        -accel kvm,arm-ffa-forward=on \
        -nodefaults \
        -display none \
        -chardev "socket,id=chrtpm,path=$work_dir/swtpm.sock" \
        -tpmdev emulator,id=tpm0,chardev=chrtpm \
        -device tpm-crb,tpmdev=tpm0 \
        -qmp stdio >"$qmp_log"

python3 - "$qmp_log" <<'PY'
import json
import sys

responses = []
errors = []
with open(sys.argv[1], encoding="utf-8") as stream:
    for line in stream:
        message = json.loads(line)
        if "return" in message:
            responses.append(message["return"])
        if "error" in message:
            errors.append(message["error"])

if True not in responses:
    raise SystemExit(
        f"internal CRB alias check did not pass: responses={responses!r} "
        f"errors={errors!r}"
    )

mtree = next(
    value for value in responses
    if isinstance(value, str) and "FlatView" in value
)
sections = mtree.split("FlatView #")
secure = next(section for section in sections if 'AS "cpu-secure-memory-0"' in section)
system = next(section for section in sections if 'AS "memory", root: system' in section)

if "000000000c000000-000000000c00007f" not in secure or "tpm-crb-mmio" not in secure:
    raise SystemExit("external CRB MMIO is missing from the secure view")
if "000000000c000080-000000000c000fff" not in secure or "tpm-crb-cmd" not in secure:
    raise SystemExit("external CRB command buffer is missing from the secure view")
if "tpm-crb" in system:
    raise SystemExit("external CRB leaked into the KVM system view")

print("shared_internal_crb=pass secure_external_crb=pass kvm_external_crb=absent")
PY
