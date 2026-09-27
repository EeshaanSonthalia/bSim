#!/bin/sh
set -eu
. "$(dirname -- "$0")/common.sh"
cd "$(repo_root)"
[ "$(zig version)" = 0.16.0 ] || die 'Zig 0.16.0 required'
[ "$(zls --version)" = 0.16.0 ] || die 'ZLS 0.16.0 required'
mkdir -p .cache
DEVELOPER_DIR=/Library/Developer/CommandLineTools /usr/bin/xcrun clang -O1 -fobjc-arc -DBSIM_THERMAL_TOOL native/thermal.m -framework Foundation -framework IOKit -o .cache/thermal-monitor
git config core.hooksPath .githooks
chmod +x .githooks/post-commit
.cache/thermal-monitor
