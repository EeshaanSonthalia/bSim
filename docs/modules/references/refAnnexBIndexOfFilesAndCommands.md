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

## Related Pages

- [Documentation Index](../../index.md#documentation-index)
- [Specification](refBSimSpecification.md#bsim-specification)
