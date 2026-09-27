#!/bin/sh
set -eu
. "$(dirname -- "$0")/common.sh"
cd "$(repo_root)"
[ "$(zig version)" = 0.16.0 ] || die 'Zig 0.16.0 required'
[ "$(zls --version)" = 0.16.0 ] || die 'ZLS 0.16.0 required'
command -v nix >/dev/null 2>&1 || die 'Nix is required for the global profile'
[ -d "$HOME/dotfiles" ] || die 'The dotfiles checkout is required at HOME/dotfiles'
[ -d "$HOME/.local/state/dotfiles/nix-profile/include/OpenEXR" ] || die 'OpenEXR headers are missing from the global profile'
[ -e "$HOME/.local/state/dotfiles/nix-profile/lib/libOpenEXRCore-3_4.dylib" ] || die 'OpenEXR libraries are missing from the global profile'
command -v ffmpeg >/dev/null 2>&1 || die 'FFmpeg is required from the global profile'
command -v ffprobe >/dev/null 2>&1 || die 'FFprobe is required from the global profile'
mkdir -p .cache
DEVELOPER_DIR=/Library/Developer/CommandLineTools /usr/bin/xcrun clang -O1 -fobjc-arc -DBSIM_THERMAL_TOOL native/thermal.m -framework Foundation -framework IOKit -o .cache/thermal-monitor
git config core.hooksPath .githooks
chmod +x .githooks/post-commit
.cache/thermal-monitor
