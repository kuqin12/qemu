#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
build_dir=${BUILD_DIR:-"$root_dir/build"}
qemu=${QEMU:-"$build_dir/qemu-system-aarch64"}
iterations=${ITERATIONS:-1}
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

"${CC:-cc}" -c -nostdlib -ffreestanding -march=armv8-a \
    "$root_dir/tests/arm-kvm/ffa-smccc-smp.S" \
    -o "$work_dir/ffa-smccc-smp.o"
"${LD:-ld}" -nostdlib \
    -T "$root_dir/tests/arm-kvm/ffa-smccc-smp.ld" \
    "$work_dir/ffa-smccc-smp.o" \
    -o "$work_dir/ffa-smccc-smp.elf"

for iteration in $(seq 1 "$iterations"); do
    serial_log="$work_dir/serial-$iteration.log"
    trace_log="$work_dir/trace-$iteration.log"

    set +e
    timeout 15s "$qemu" \
        -machine virt,gic-version=3 \
        -cpu host \
        -smp 4 \
        -m 256M \
        -accel kvm,arm-ffa-forward=on \
        -kernel "$work_dir/ffa-smccc-smp.elf" \
        -display none \
        -monitor none \
        -serial "file:$serial_log" \
        -trace "enable=kvm_arm_ffa_stub,file=$trace_log"
    status=$?
    set -e

    trace_count=$(grep -c '^kvm_arm_ffa_stub' "$trace_log" || true)
    pass_count=$(grep -c '^PASS$' "$serial_log" || true)
    per_cpu=true
    for cpu in 0 1 2 3; do
        cpu_count=$(grep -c "^kvm_arm_ffa_stub cpu $cpu " "$trace_log" || true)
        if [[ "$cpu_count" -ne 2 ]]; then
            per_cpu=false
        fi
    done

    printf 'iteration=%d status=%d traces=%d pass=%d per_cpu=%s\n' \
        "$iteration" "$status" "$trace_count" "$pass_count" "$per_cpu"

    if [[ "$status" -ne 0 || "$trace_count" -ne 8 ||
          "$pass_count" -ne 1 || "$per_cpu" != true ]]; then
        cat "$trace_log"
        cat "$serial_log"
        exit 1
    fi
done