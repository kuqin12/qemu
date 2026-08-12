#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
build_dir=${BUILD_DIR:-"$root_dir/build"}
qemu=${QEMU:-"$build_dir/qemu-system-aarch64"}
secure_flash=${SECURE_FLASH:?Set SECURE_FLASH to SECURE_FLASH0.fd}
memory=${MEMORY:-2048M}
work_dir=$(mktemp -d)
qemu_pid=
guest_reset=${GUEST_RESET:-0}
defines=(-DEXPECT_COLD_RESET)
if [[ "$guest_reset" == 1 ]]; then
    defines+=(-DEXPECT_GUEST_COLD_RESET)
fi

cleanup()
{
    if [[ -n "$qemu_pid" ]] && kill -0 "$qemu_pid" 2>/dev/null; then
        kill "$qemu_pid"
        wait "$qemu_pid" 2>/dev/null || true
    fi
    rm -rf "$work_dir"
}
trap cleanup EXIT

"${CC:-cc}" -c -nostdlib -ffreestanding -march=armv8-a \
    "${defines[@]}" \
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
qmp_socket="$work_dir/qmp.sock"

swtpm socket \
    --tpm2 \
    --tpmstate "dir=$work_dir" \
    --ctrl "type=unixio,path=$work_dir/swtpm.sock,terminate" \
    --flags not-need-init \
    --daemon

"$qemu" \
    -machine virt,hybrid-secure=on,gic-version=3 \
    -cpu host \
    -smp 2 \
    -m "$memory" \
    -accel kvm,arm-ffa-forward=on \
    -global driver=cfi.pflash01,property=secure,value=on \
    -drive "if=pflash,format=raw,unit=0,file=$secure_flash,readonly=on" \
    -drive "if=pflash,format=raw,unit=1,file=$work_dir/normal-flash.fd,readonly=on" \
    -chardev "socket,id=chrtpm,path=$work_dir/swtpm.sock" \
    -tpmdev emulator,id=tpm0,chardev=chrtpm \
    -device tpm-tis-device,tpmdev=tpm0 \
    -display none \
    -monitor none \
    -qmp "unix:$qmp_socket,server=on,wait=off" \
    -serial "file:$normal_log" \
    -serial "file:$secure_log" \
    -trace "enable=kvm_arm_*,file=$trace_log" &
qemu_pid=$!

python3 - "$qmp_socket" "$normal_log" "$guest_reset" <<'PY'
import json
import socket
import sys
import time

qmp_path, log_path, guest_reset = sys.argv[1:]
deadline = time.monotonic() + 60

while True:
    try:
        qmp = socket.socket(socket.AF_UNIX)
        qmp.connect(qmp_path)
        break
    except (FileNotFoundError, ConnectionRefusedError):
        if time.monotonic() >= deadline:
            raise RuntimeError("timed out connecting to QMP")
        time.sleep(0.01)

stream = qmp.makefile("rwb", buffering=0)


def receive_response(command_id):
    while True:
        message = json.loads(stream.readline())
        if message.get("id") == command_id:
            return message


def execute(command, command_id):
    request = {"execute": command, "id": command_id}
    stream.write(json.dumps(request).encode() + b"\n")
    response = receive_response(command_id)
    if "error" in response:
        raise RuntimeError(response["error"])


def wait_for_ready(count):
    while time.monotonic() < deadline:
        try:
            with open(log_path, encoding="utf-8", errors="replace") as log:
                if log.read().count("HYBRID FFA COLD READY") >= count:
                    return
        except FileNotFoundError:
            pass
        time.sleep(0.05)
    raise RuntimeError(f"timed out waiting for cold boot {count}")


json.loads(stream.readline())
execute("qmp_capabilities", "capabilities")
wait_for_ready(1)
if guest_reset != "1":
    execute("system_reset", "cold-reset")
wait_for_ready(2)
execute("quit", "quit")
PY

wait "$qemu_pid"
qemu_status=$?
qemu_pid=

ready_count=$(grep -c '^HYBRID FFA COLD READY$' "$normal_log" || true)
trace_count=$(grep -c \
    '^kvm_arm_ffa_stub cpu 0 function 0xc400008d ' "$trace_log" || true)
direct_count=$(grep -c 'MsgSendDirectReq2' "$normal_log" || true)
reset_count=$(grep -c \
    '^kvm_arm_psci_system_reset cpu 0 function 0x84000009 warm 0$' \
    "$trace_log" || true)
tfa_reset_count=$(grep -c 'QEMU System Reset: with GPIO' \
    "$normal_log" || true)
expected_resets=$guest_reset

printf 'ready=%d kvm_exit=%d mssp_direct=%d reset=%d tfa_reset=%d\n' \
    "$ready_count" "$trace_count" "$direct_count" "$reset_count" \
    "$tfa_reset_count"

if [[ "$qemu_status" -ne 0 || "$ready_count" -ne 2 ||
    "$trace_count" -ne 2 || "$direct_count" -lt 2 ||
    "$reset_count" -ne "$expected_resets" ||
    "$tfa_reset_count" -ne "$expected_resets" ]]; then
    printf 'qemu_status=%d\n' "$qemu_status"
    cat "$trace_log"
    tail -n 200 "$normal_log"
    tail -n 80 "$secure_log"
    exit 1
fi