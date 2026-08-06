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
swtpm_state="$work_dir/swtpm"
swtpm_socket="$work_dir/swtpm.sock"
mkdir "$swtpm_state"

start_swtpm()
{
    rm -f "$swtpm_socket"
    swtpm socket \
        --tpm2 \
        --tpmstate "dir=$swtpm_state" \
        --ctrl "type=unixio,path=$swtpm_socket,terminate" \
        --flags not-need-init \
        --daemon
}

start_swtpm

printf '%s\n' \
    '{"execute":"qmp_capabilities"}' \
    '{"execute":"qom-get","arguments":{"path":"/machine","property":"hybrid-shadow-bootstrap-passed"}}' \
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
        -chardev "socket,id=chrtpm,path=$swtpm_socket" \
        -tpmdev emulator,id=tpm0,chardev=chrtpm \
        -device tpm-tis-device,tpmdev=tpm0 \
        -display none \
        -monitor none \
        -serial "file:$normal_log" \
        -serial "file:$secure_log" \
        -qmp stdio >"$qmp_log"

true_count=$(grep -cF '{"return": true}' "$qmp_log" || true)
bl33_pc_count=$(grep -cF '{"return": 67108864}' "$qmp_log" || true)
cpu_count=$(grep -o '"qom-type": "host-arm-cpu"' "$qmp_log" | wc -l)
bootstrap_count=$(grep -c 'Finished bootstrapping all SPs on CPU0' "$normal_log" || true)

printf 'gates=%d bl33_pc=%d kvm_cpus=%d bootstrap=%d\n' \
    "$true_count" "$bl33_pc_count" "$cpu_count" \
    "$bootstrap_count"

if [[ "$true_count" -ne 3 || "$bl33_pc_count" -ne 2 ||
      "$cpu_count" -ne 2 || "$bootstrap_count" -ne 1 ]]; then
    cat "$qmp_log"
    tail -n 120 "$normal_log"
    tail -n 40 "$secure_log"
    exit 1
fi

uefi_log="$work_dir/uefi.log"
qemu_log="$work_dir/qemu.log"
cp "$secure_flash" "$work_dir/secure-flash.fd"
truncate -s 1G "$work_dir/nvme.img"
start_swtpm
set +e
timeout 30s "$qemu" \
    -machine virt,hybrid-secure=on,gic-version=3,iommu=smmuv3 \
    -cpu host \
    -smp 2 \
    -m 8192M \
    -accel kvm,arm-ffa-forward=on \
    -global driver=cfi.pflash01,property=secure,value=on \
    -drive "if=pflash,format=raw,unit=0,file=$work_dir/secure-flash.fd" \
    -drive "if=pflash,format=raw,unit=1,file=$normal_flash,readonly=on" \
    -drive "file=$work_dir/nvme.img,format=raw,if=none,id=test_nvme" \
    -device nvme,serial=test-nvme,drive=test_nvme \
    -chardev "socket,id=chrtpm,path=$swtpm_socket" \
    -tpmdev emulator,id=tpm0,chardev=chrtpm \
    -device tpm-tis-device,tpmdev=tpm0 \
    -display none \
    -monitor none \
    -serial "file:$uefi_log" \
    -serial null \
    > /dev/null 2>"$qemu_log"
uefi_status=$?
set -e

uefi_count=$(grep -c '^UEFI firmware' "$uefi_log" || true)
dxe_count=$(grep -c 'DXE Core Platform Binary' "$uefi_log" || true)
bds_count=$(grep -c '\[Bds\] Entry' "$uefi_log" || true)
timeout_count=$(grep -c 'hybrid secure call .* timed out' "$qemu_log" || true)
erase_error_count=$(grep -c 'EraseSingleBlock.*Error' "$uefi_log" || true)
exception_count=$(grep -c 'EXCEPTION: Synchronous' "$uefi_log" || true)
nvme_count=$(grep -c 'NvmExpressDriverBindingStart: end successfully' "$uefi_log" || true)
nvme_timeout_count=$(grep -c 'NvmExpressPassThru: Timeout' "$uefi_log" || true)
sid10_fault_count=$(grep -c 'StreamId=0x10 FaultRecord' "$uefi_log" || true)
smmu_assert_count=$(grep -c 'ASSERT \[SmmuDxe\]' "$uefi_log" || true)
printf 'uefi_status=%d uefi=%d dxe=%d bds=%d timeout=%d erase_errors=%d exception=%d nvme=%d nvme_timeout=%d sid10_faults=%d smmu_assert=%d\n' \
    "$uefi_status" "$uefi_count" "$dxe_count" "$bds_count" \
    "$timeout_count" "$erase_error_count" "$exception_count" \
    "$nvme_count" "$nvme_timeout_count" "$sid10_fault_count" \
    "$smmu_assert_count"

if [[ "$uefi_status" -ne 124 || "$uefi_count" -lt 1 ||
      "$dxe_count" -lt 1 || "$bds_count" -lt 1 ||
      "$timeout_count" -ne 0 || "$erase_error_count" -ne 0 ||
      "$exception_count" -ne 0 || "$nvme_count" -lt 1 ||
      "$nvme_timeout_count" -ne 0 || "$sid10_fault_count" -ne 0 ||
      "$smmu_assert_count" -ne 0 ]]; then
    cat "$qemu_log"
    tail -n 120 "$uefi_log"
    exit 1
fi
