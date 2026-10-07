#!/usr/bin/env bash
set -euo pipefail
# Compatibility entry point: audit the actual final profile without rewriting.
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
exec bash "$HERE/run-test02.sh" "$@"
