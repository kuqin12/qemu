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
        -device tpm-tis-device,tpmdev=tpm0 \
        -qmp stdio >"$qmp_log"

python3 - "$qmp_log" <<'PY'
import json
import re
import sys

responses = []
with open(sys.argv[1], encoding="utf-8") as stream:
    for line in stream:
        message = json.loads(line)
        if "return" in message:
            responses.append(message["return"])

mtree = next(
    value for value in responses
    if isinstance(value, str) and "FlatView" in value
)
sections = mtree.split("FlatView #")
secure = next(section for section in sections if 'AS "cpu-secure-memory-0"' in section)
system = next(section for section in sections if 'AS "memory", root: system' in section)

match = re.search(
    r"([0-9a-f]{16})-([0-9a-f]{16}).*tpm-tis-mmio",
    secure,
)
if match is None:
    raise SystemExit("dynamic TPM TIS MMIO is missing from the secure view")
if "tpm-tis-mmio" in system or "tpm-ppi" in system:
    raise SystemExit("external TPM device leaked into the KVM system view")

print(
    "dynamic_tpm_model=tpm-tis-device "
    f"secure_mmio=0x{match.group(1)}-0x{match.group(2)} "
    "kvm_tpm=absent"
)
PY
