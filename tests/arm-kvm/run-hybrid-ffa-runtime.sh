#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
build_dir=${BUILD_DIR:-"$root_dir/build"}
qemu=${QEMU:-"$build_dir/qemu-system-aarch64"}
secure_flash=${SECURE_FLASH:?Set SECURE_FLASH to SECURE_FLASH0.fd}
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

"${CC:-cc}" -c -nostdlib -ffreestanding -march=armv8-a \
    "$root_dir/tests/arm-kvm/hybrid-ffa-runtime.S" \
    -o "$work_dir/hybrid-ffa-runtime.o"
"${LD:-ld}" -nostdlib \
    -T "$root_dir/tests/arm-kvm/hybrid-ffa-runtime.ld" \
    "$work_dir/hybrid-ffa-runtime.o" \
    -o "$work_dir/hybrid-ffa-runtime.elf"
"${OBJCOPY:-objcopy}" -O binary \
    "$work_dir/hybrid-ffa-runtime.elf" \
    "$work_dir/hybrid-ffa-runtime.bin"
cp "$work_dir/hybrid-ffa-runtime.bin" "$work_dir/normal-flash.fd"
truncate -s 64M "$work_dir/normal-flash.fd"

normal_log="$work_dir/normal.log"
secure_log="$work_dir/secure.log"
trace_log="$work_dir/trace.log"

set +e
timeout --kill-after=5s 30s "$qemu" \
    -machine virt,hybrid-secure=on,gic-version=3 \
    -cpu host \
    -smp 2 \
    -m 2048M \
    -accel kvm,arm-ffa-forward=on \
    -global driver=cfi.pflash01,property=secure,value=on \
    -drive "if=pflash,format=raw,unit=0,file=$secure_flash,readonly=on" \
    -drive "if=pflash,format=raw,unit=1,file=$work_dir/normal-flash.fd,readonly=on" \
    -display none \
    -monitor none \
    -serial "file:$normal_log" \
    -serial "file:$secure_log" \
    -trace "enable=kvm_arm_ffa_stub,file=$trace_log"
status=$?
set -e

pass_count=$(grep -c '^HYBRID FFA RUNTIME PASS$' "$normal_log" || true)
trace_count=$(grep -c '^kvm_arm_ffa_stub cpu 0 function 0xc400008d ' "$trace_log" || true)
direct_count=$(grep -c 'MsgSendDirectReq2' "$normal_log" || true)

printf 'pass=%d kvm_exit=%d mssp_direct=%d\n' \
    "$pass_count" "$trace_count" "$direct_count"

if [[ "$status" -ne 0 || "$pass_count" -ne 1 || "$trace_count" -ne 1 ||
    "$direct_count" -lt 1 ]]; then
    printf 'qemu_status=%d\n' "$status"
    cat "$trace_log"
    tail -n 160 "$normal_log"
    tail -n 40 "$secure_log"
    exit 1
fi
