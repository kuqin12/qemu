#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
build_dir=${BUILD_DIR:-"$root_dir/build"}
qemu=${QEMU:-"$build_dir/qemu-system-aarch64"}
secure_flash=${SECURE_FLASH:?Set SECURE_FLASH to SECURE_FLASH0.fd}
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

"${CC:-cc}" -DEXPECT_TIMEOUT -c -nostdlib -ffreestanding -march=armv8-a \
    "$root_dir/tests/arm-kvm/hybrid-ffa-runtime.S" \
    -o "$work_dir/hybrid-ffa-timeout.o"
"${LD:-ld}" -nostdlib \
    -T "$root_dir/tests/arm-kvm/hybrid-ffa-runtime.ld" \
    "$work_dir/hybrid-ffa-timeout.o" \
    -o "$work_dir/hybrid-ffa-timeout.elf"
"${OBJCOPY:-objcopy}" -O binary \
    "$work_dir/hybrid-ffa-timeout.elf" \
    "$work_dir/hybrid-ffa-timeout.bin"
cp "$work_dir/hybrid-ffa-timeout.bin" "$work_dir/normal-flash.fd"
truncate -s 64M "$work_dir/normal-flash.fd"

normal_log="$work_dir/normal.log"
secure_log="$work_dir/secure.log"
qemu_log="$work_dir/qemu.log"

swtpm socket \
    --tpm2 \
    --tpmstate "dir=$work_dir" \
    --ctrl "type=unixio,path=$work_dir/swtpm.sock,terminate" \
    --flags not-need-init \
    --daemon

set +e
timeout --kill-after=5s 30s "$qemu" \
    -machine virt,hybrid-secure=on,hybrid-secure-call-timeout-ms=1,gic-version=3 \
    -cpu host \
    -smp 2 \
    -m 2048M \
    -accel kvm,arm-ffa-forward=on \
    -global driver=cfi.pflash01,property=secure,value=on \
    -drive "if=pflash,format=raw,unit=0,file=$secure_flash,readonly=on" \
    -drive "if=pflash,format=raw,unit=1,file=$work_dir/normal-flash.fd,readonly=on" \
    -chardev "socket,id=chrtpm,path=$work_dir/swtpm.sock" \
    -tpmdev emulator,id=tpm0,chardev=chrtpm \
    -device tpm-tis-device,tpmdev=tpm0 \
    -display none \
    -monitor none \
    -serial "file:$normal_log" \
    -serial "file:$secure_log" \
    > /dev/null 2>"$qemu_log"
status=$?
set -e

pass_count=$(grep -c '^HYBRID FFA TIMEOUT PASS$' "$normal_log" || true)
timeout_count=$(grep -c 'hybrid secure call .* timed out after 1 ms' "$qemu_log" || true)
forced_stop_count=$(grep -c 'did not stop; stopping the VM' "$qemu_log" || true)
printf 'status=%d pass=%d timeout=%d forced_stop=%d\n' \
    "$status" "$pass_count" "$timeout_count" "$forced_stop_count"

if [[ "$status" -ne 0 || "$pass_count" -ne 1 ||
      "$timeout_count" -ne 1 || "$forced_stop_count" -ne 0 ]]; then
    cat "$qemu_log"
    tail -n 80 "$normal_log"
    tail -n 40 "$secure_log"
    exit 1
fi
