#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
build_dir=${BUILD_DIR:-"$root_dir/build"}
qemu=${QEMU:-"$build_dir/qemu-system-aarch64"}
secure_flash=${SECURE_FLASH:?Set SECURE_FLASH to SECURE_FLASH0.fd}
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

"${CC:-cc}" -c -nostdlib -ffreestanding -march=armv8-a \
    "$root_dir/tests/arm-kvm/hybrid-ffa-busy.S" \
    -o "$work_dir/hybrid-ffa-busy.o"
"${LD:-ld}" -nostdlib \
    -T "$root_dir/tests/arm-kvm/hybrid-ffa-busy.ld" \
    "$work_dir/hybrid-ffa-busy.o" \
    -o "$work_dir/normal-flash.elf"
"${OBJCOPY:-objcopy}" -O binary \
    "$work_dir/normal-flash.elf" "$work_dir/normal-flash.fd"
truncate -s 64M "$work_dir/normal-flash.fd"

normal_log="$work_dir/normal.log"
trace_log="$work_dir/trace.log"
set +e
timeout --kill-after=5s 30s "$qemu" \
    -machine virt,hybrid-secure=on,gic-version=3 \
    -cpu host \
    -smp 2 \
    -m 2048M \
    -accel kvm,arm-ffa-forward=on,arm-ffa-stub-delay-ms=100 \
    -global driver=cfi.pflash01,property=secure,value=on \
    -drive "if=pflash,format=raw,unit=0,file=$secure_flash,readonly=on" \
    -drive "if=pflash,format=raw,unit=1,file=$work_dir/normal-flash.fd,readonly=on" \
    -display none \
    -monitor none \
    -serial "file:$normal_log" \
    -serial null \
    -trace "enable=kvm_arm_ffa_stub,file=$trace_log"
status=$?
set -e

pass_count=$(grep -c '^HYBRID FFA BUSY PASS$' "$normal_log" || true)
trace_count=$(grep -c '^kvm_arm_ffa_stub' "$trace_log" || true)
cpu0_count=$(grep -c '^kvm_arm_ffa_stub cpu 0 ' "$trace_log" || true)
cpu1_count=$(grep -c '^kvm_arm_ffa_stub cpu 1 ' "$trace_log" || true)
printf 'status=%d pass=%d kvm_exits=%d cpu0=%d cpu1=%d\n' \
    "$status" "$pass_count" "$trace_count" "$cpu0_count" "$cpu1_count"

if [[ "$status" -ne 0 || "$pass_count" -ne 1 || "$trace_count" -ne 2 ||
      "$cpu0_count" -ne 1 || "$cpu1_count" -ne 1 ]]; then
    cat "$trace_log"
    tail -n 100 "$normal_log"
    exit 1
fi
