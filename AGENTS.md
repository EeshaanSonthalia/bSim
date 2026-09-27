---
title: "Agent Rules"
description: "The build and delivery contract for bSim"
audience: [agents]
stability: stable
last-reviewed: 2026-09-27
ms.topic: reference
---

# Agent Rules {#agent-rules}

**TL;DR.** Follow the dotfiles master prompt and Zig contract. Run guarded checks before each commit. Keep all generated images and caches local.

Read `~/dotfiles/MASTER.md` and `~/dotfiles/prompts/zig.md` before changes.
Follow [the specification](docs/modules/references/refBSimSpecification.md#bsim-specification).
Use camelCase identifiers, kebab-case directories, and the existing module naming convention.
Pin Zig and ZLS to 0.16.0. Ship ReleaseSafe.
Use `scripts/thermal-run.py` for sustained development workloads.
Never bypass a thermal guard or change the hardware thermal controls.
Use one concern per commit. End the summary with a period and keep it within 72 characters.
Every commit pushes with `.githooks/post-commit`. Verify the remote commit.
Never amend or force-push. Do not retry a failed push without user instruction.
Use plain web-facing READMEs named `ghREADME` with no frontmatter.
Write ASD-STE100-compliant documentation.

## Related Pages

- [Specification](docs/modules/references/refBSimSpecification.md#bsim-specification)
- [Documentation Index](docs/index.md#documentation-index)
