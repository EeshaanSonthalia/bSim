---
title: "File and Command Index"
description: "The source and command inventory"
audience: [humans, agents]
stability: evolving
last-reviewed: 2026-09-27
ms.topic: reference
---

# File and Command Index {#file-and-command-index}

**TL;DR.** This index maps the main source files and commands. The build uses a local thermal guard.

| Path | Purpose |
|------|---------|
| `native/thermal.m` | Read-only M4 thermal sensors |
| `scripts/bootstrap.sh` | Verify tools and build the sensor reader |
| `scripts/thermal-run.py` | Guard development process groups |
| `scripts/check-asd-docs.sh` | Check ASD documentation conventions |
| `.githooks/post-commit` | Push each commit |
| `flake.nix` | Pin the project package environment |
| `locks/toolchains.json` | Record toolchain versions |
| `src/geodesic.zig` | Scalar f64 Kerr reference solver |
| `src/scene.zig` | Validated versioned scene data |
| `src/material.zig` | Deterministic disk emission |
| `src/thermal.zig` | Scheduling thresholds and hysteresis |
| `src/gpu.zig` | Bounded Metal scheduling |
| `shaders/renderer.metal` | Ray queues and map shading |
| `native/renderer.m` | Metal framework bridge |
| `build.zig` | Zig build graph |
| `justfile` | Build and validation commands |

## Related Pages

- [Validation Record](refValidation.md#validation-record)
- [Documentation Index](../../index.md#documentation-index)
- [Specification](refBSimSpecification.md#bsim-specification)
