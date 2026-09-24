#!/usr/bin/env bash
# Export the reviewed ABIs to docs/abi/<Contract>.json, or verify them with --check. Needs Foundry only.
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
mode="${1:-export}"
contracts=("src/PVP.sol:PVP" "src/PvPadHook.sol:PvPadHook")
forge build --silent
for entry in "${contracts[@]}"; do
  name="${entry##*:}"
  target="docs/abi/${name}.json"
  rendered="$(forge inspect "$entry" abi --json)"
  if [[ "$mode" == "--check" ]]; then
    if [[ ! -f "$target" ]] || ! diff -q <(printf '%s\n' "$rendered") "$target" >/dev/null; then
      echo "ABI mismatch: $target (run scripts/export-abi.sh)" >&2
      exit 1
    fi
    echo "$name: checked"
  else
    printf '%s\n' "$rendered" > "$target"
    echo "$name: exported to $target"
  fi
done
