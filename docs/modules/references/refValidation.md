---
title: "Validation Record"
description: "Measured correctness and current acceptance limits"
audience: [humans, agents]
stability: evolving
last-reviewed: 2026-09-27
ms.topic: reference
---

# Validation Record {#validation-record}

**TL;DR.** The scalar solver passes the current physics checks. A small wide-shot grid agrees with the Metal solver. Full 4K acceptance remains open.

## Current Checks

The CPU solver uses f64 RKF45 integration and a local orthonormal camera frame.
The Metal solver uses inverse radius to reduce rounding error in f32.
The integrators keep explicit capture, escape, and unresolved outcomes.

The unit checks cover the Schwarzschild critical impact parameter, Kerr constraint drift, disk crossings, exhausted budgets, invalid scenes, and thermal hysteresis.
The reference renderer produced a 320 by 180 wide image.
The image shows the main disk band and secondary arcs.

The Metal comparison uses a 64 by 36 wide-shot grid.
All 2304 rays agree on capture or escape and disk-hit counts.
The maximum first-hit radius error is 0.000667 mass units.

This grid does not establish the half-pixel boundary target at 4K.
Full boundary, transport, export, and sustained playback checks remain open.
No 60 fps acceptance claim applies yet.

## Commands

```sh
just test
just build
just validate-gpu
python3 scripts/thermal-run.py ./zig-out/bin/bSim reference
```

## Related Pages

- [Documentation Index](../../index.md#documentation-index)
- [Specification](refBSimSpecification.md#bsim-specification)
- [File and Command Index](refAnnexBIndexOfFilesAndCommands.md#file-and-command-index)
