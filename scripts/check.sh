#!/usr/bin/env bash
# The complete local check. Offline: Foundry with solc 0.8.26 and Python 3 must already be installed.
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
forge build
forge test
forge fmt --check
bash scripts/export-abi.sh --check
python3 -m unittest discover -s scripts -p '*_test.py'
