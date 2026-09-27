#!/bin/sh
set -eu
repo_root() { git -C "$(dirname -- "$0")/.." rev-parse --show-toplevel; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
make_temp_dir() { mktemp -d; }
