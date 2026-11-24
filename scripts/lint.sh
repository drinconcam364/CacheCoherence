#!/usr/bin/env bash
# Lint all RTL with Verilator. Run locally before every push; CI runs the same script.
# Usage: scripts/lint.sh [top_module]   (default: top)
set -euo pipefail

cd "$(dirname "$0")/.."
TOP="${1:-top}"

# The package must be compiled before any module that imports it,
# so list mesi_pkg.sv first, then every other .sv file in rtl/.
if [[ ! -f rtl/mesi_pkg.sv ]]; then
  echo "lint: rtl/mesi_pkg.sv not found (create it before linting)" >&2
  exit 1
fi
mapfile -t OTHERS < <(find rtl -name '*.sv' ! -name 'mesi_pkg.sv' | sort)

echo "lint: top=$TOP, files: rtl/mesi_pkg.sv ${OTHERS[*]}"
verilator --lint-only -Wall --top-module "$TOP" -Irtl rtl/mesi_pkg.sv "${OTHERS[@]}"
echo "lint: clean"
