#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
build_dir=${BUILD_DIR:-"$root_dir/build"}
qemu=${QEMU:-"$build_dir/qemu-system-aarch64"}
secure_flash=${SECURE_FLASH:?Set SECURE_FLASH to SECURE_FLASH0.fd}
normal_flash=${NORMAL_FLASH:?Set NORMAL_FLASH to QEMU_EFI.fd}
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

normal_log="$work_dir/normal.log"
secure_log="$work_dir/secure.log"
qmp_log="$work_dir/qmp.log"

printf '%s\n' \
    '{"execute":"qmp_capabilities"}' \
    '{"execute":"qom-get","arguments":{"path":"/machine","property":"hybrid-shadow-bootstrap-passed"}}' \
    '{"execute":"qom-get","arguments":{"path":"/machine","property":"hybrid-shadow-direct-passed"}}' \
    '{"execute":"qom-get","arguments":{"path":"/machine","property":"hybrid-kvm-handoff-ready"}}' \
    '{"execute":"qom-get","arguments":{"path":"/machine","property":"hybrid-shadow-worker-alive"}}' \
    '{"execute":"qom-get","arguments":{"path":"/machine","property":"hybrid-shadow-stop-pc"}}' \
    '{"execute":"qom-get","arguments":{"path":"/machine","property":"hybrid-shadow-current-pc"}}' \
    '{"execute":"query-cpus-fast"}' \
    '{"execute":"quit"}' |
    timeout 60s "$qemu" \
        -machine virt,hybrid-secure=on,gic-version=3 \
        -cpu host \
        -smp 2 \
        -m 2048M \
        -accel kvm,arm-ffa-forward=on \
        -global driver=cfi.pflash01,property=secure,value=on \
        -drive "if=pflash,format=raw,unit=0,file=$secure_flash,readonly=on" \
        -drive "if=pflash,format=raw,unit=1,file=$normal_flash,readonly=on" \
        -display none \
        -monitor none \
        -serial "file:$normal_log" \
        -serial "file:$secure_log" \
        -qmp stdio >"$qmp_log"

true_count=$(grep -cF '{"return": true}' "$qmp_log" || true)
stop_count=$(grep -cF '{"return": 184549384}' "$qmp_log" || true)
current_count=$(grep -cF '{"return": 67108864}' "$qmp_log" || true)
cpu_count=$(grep -o '"qom-type": "host-arm-cpu"' "$qmp_log" | wc -l)
bootstrap_count=$(grep -c 'Finished bootstrapping all SPs on CPU0' "$normal_log" || true)
direct_count=$(grep -c 'MsgSendDirectReq2' "$normal_log" || true)

printf 'gates=%d stop_pc=%d current_pc=%d kvm_cpus=%d bootstrap=%d direct_req=%d\n' \
    "$true_count" "$stop_count" "$current_count" "$cpu_count" \
    "$bootstrap_count" "$direct_count"

if [[ "$true_count" -ne 4 || "$stop_count" -ne 1 ||
    "$current_count" -ne 1 ||
      "$cpu_count" -ne 2 || "$bootstrap_count" -ne 1 ||
      "$direct_count" -lt 1 ]]; then
    cat "$qmp_log"
    tail -n 120 "$normal_log"
    tail -n 40 "$secure_log"
    exit 1
fi

uefi_log="$work_dir/uefi.log"
set +e
timeout 20s "$qemu" \
    -machine virt,hybrid-secure=on,gic-version=3 \
    -cpu host \
    -smp 2 \
    -m 2048M \
    -accel kvm,arm-ffa-forward=on \
    -global driver=cfi.pflash01,property=secure,value=on \
    -drive "if=pflash,format=raw,unit=0,file=$secure_flash,readonly=on" \
    -drive "if=pflash,format=raw,unit=1,file=$normal_flash,readonly=on" \
    -display none \
    -monitor none \
    -serial "file:$uefi_log" \
    -serial null
uefi_status=$?
set -e

uefi_count=$(grep -c '^UEFI firmware' "$uefi_log" || true)
dxe_count=$(grep -c 'DXE Core Platform Binary' "$uefi_log" || true)
printf 'uefi_status=%d uefi=%d dxe=%d\n' \
    "$uefi_status" "$uefi_count" "$dxe_count"

if [[ "$uefi_status" -ne 124 || "$uefi_count" -lt 1 ||
      "$dxe_count" -lt 1 ]]; then
    tail -n 120 "$uefi_log"
    exit 1
fi
