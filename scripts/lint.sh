#!/usr/bin/env bash
# Lint all RTL with Verilator. Run before every push.
# Usage: bash scripts/lint.sh [top_module]   (default: top)
# Works with the old bash 3.2 that ships on macOS.
set -eu

cd "$(dirname "$0")/.."
TOP="${1:-top}"

# The package must be compiled before any module that imports it,
# so list mesi_pkg.sv first, then every other .sv file in rtl/.
if [ ! -f rtl/mesi_pkg.sv ]; then
  echo "lint: rtl/mesi_pkg.sv not found (create it before linting)" >&2
  exit 1
fi
OTHERS=$(find rtl -name '*.sv' ! -name 'mesi_pkg.sv' | sort)

echo "lint: top=$TOP, files: rtl/mesi_pkg.sv" $OTHERS
# $OTHERS is left unquoted on purpose so each file becomes its own argument
# (file names in rtl/ must not contain spaces).
verilator --lint-only -Wall --top-module "$TOP" -Irtl rtl/mesi_pkg.sv $OTHERS
echo "lint: clean"
