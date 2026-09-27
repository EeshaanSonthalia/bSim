default:
    @just --list

bootstrap:
    sh scripts/bootstrap.sh

build:
    nix develop --command python3 scripts/thermal-run.py zig build -j2 -Doptimize=ReleaseSafe

test:
    nix develop --command python3 scripts/thermal-run.py zig build test -j2 -Doptimize=ReleaseSafe

fmt:
    zig fmt build.zig src

fmt-check:
    zig fmt --check build.zig src

docs-check:
    sh scripts/check-asd-docs.sh

check: fmt-check docs-check test build
    git diff --check

run *args:
    ./zig-out/bin/bSim {{args}}

validate-gpu: build
    python3 scripts/thermal-run.py ./zig-out/bin/bSim validate-gpu

validate-export: build
    python3 scripts/thermal-run.py python3 scripts/verify-exports.py
