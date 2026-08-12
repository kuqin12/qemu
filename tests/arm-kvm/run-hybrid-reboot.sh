#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)

PSCI_RESET_FID=0x84000012 EXPECT_REBOOT=1 \
	exec "$root_dir/tests/arm-kvm/run-hybrid-ffa-runtime.sh"