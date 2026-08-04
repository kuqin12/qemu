#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
build_dir=${BUILD_DIR:-"$root_dir/build"}
qemu=${QEMU:-"$build_dir/qemu-system-aarch64"}
iterations=${ITERATIONS:-1}
delay_ms=${FFA_STUB_DELAY_MS:-250}
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

"${CC:-cc}" -c -nostdlib -ffreestanding -march=armv8-a \
    "$root_dir/tests/arm-kvm/ffa-smccc-irq.S" \
    -o "$work_dir/ffa-smccc-irq.o"
"${LD:-ld}" -nostdlib \
    -T "$root_dir/tests/arm-kvm/ffa-smccc-smp.ld" \
    "$work_dir/ffa-smccc-irq.o" \
    -o "$work_dir/ffa-smccc-irq.elf"

for iteration in $(seq 1 "$iterations"); do
    serial_log="$work_dir/serial-$iteration.log"
    trace_log="$work_dir/trace-$iteration.log"

    set +e
    timeout 15s "$qemu" \
        -machine virt,gic-version=3 \
        -cpu host \
        -smp 4 \
        -m 256M \
        -accel "kvm,arm-ffa-forward=on,arm-ffa-stub-delay-ms=$delay_ms" \
        -kernel "$work_dir/ffa-smccc-irq.elf" \
        -display none \
        -monitor none \
        -serial "file:$serial_log" \
        -trace "enable=kvm_arm_ffa_stub,file=$trace_log"
    status=$?
    set -e

    trace_count=$(grep -c '^kvm_arm_ffa_stub cpu 0 ' "$trace_log" || true)
    pass_count=$(grep -c '^PASS$' "$serial_log" || true)

    printf 'iteration=%d status=%d cpu0_traces=%d pass=%d\n' \
        "$iteration" "$status" "$trace_count" "$pass_count"

    if [[ "$status" -ne 0 || "$trace_count" -ne 1 ||
          "$pass_count" -ne 1 ]]; then
        cat "$trace_log"
        cat "$serial_log"
        exit 1
    fi

done
