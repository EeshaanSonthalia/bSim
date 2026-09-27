---
title: "bSim"
description: "Cinematic Kerr black hole rendering for Apple Silicon"
audience: [humans, agents]
stability: evolving
last-reviewed: 2026-09-27
ms.topic: overview
---

# bSim {#bsim}

**TL;DR.** bSim recreates the published Gargantua appearance with Zig 0.16.0 and Metal. Development follows the specification and uses strict thermal limits.

The renderer targets the M4 MacBook Air with 16 GB memory.
The release requirements are in the [specification](docs/modules/references/refBSimSpecification.md#bsim-specification).
Performance targets require measured validation.

## Development

```sh
sh scripts/bootstrap.sh
just check
```

Bootstrap requires the dotfiles checkout at HOME/dotfiles.
Run `just build` to build. Run `just test` to test.
The profile at HOME/.local/state/dotfiles/nix-profile provides OpenEXR, Imath, and FFmpeg.

The thermal guard pauses workloads at 37.5 degrees Celsius battery temperature or 75 degrees Celsius CPU or GPU temperature.
It also stops work when a sensor fails.
Readings below 5 degrees Celsius are invalid on this host.
Cancellation stops new work and restores the terminal cursor.
These limits do not guarantee a physical temperature ceiling. Other applications and ambient heat remain outside application control.

## Related Pages

- [Documentation Index](docs/index.md#documentation-index)
- [Specification](docs/modules/references/refBSimSpecification.md#bsim-specification)
- [Agent Rules](AGENTS.md#agent-rules)
