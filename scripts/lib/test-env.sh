#!/usr/bin/env bash
# Source-only test environment bootstrap.
#
# Removes every exported variable whose name starts with NOGG_, plus NOGGING_ROOT,
# in the calling process without printing variable values or using eval.
# Operates safely under `set -euo pipefail`, handles empty match sets, is idempotent,
# and preserves all unrelated environment variables.

for _nogg_clean_var in "${!NOGG_@}"; do
  unset -v "$_nogg_clean_var"
done
unset -v NOGGING_ROOT _nogg_clean_var
