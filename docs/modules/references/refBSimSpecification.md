---
title: "bSim Specification"
description: "The authoritative renderer requirements and acceptance targets"
audience: [humans, agents]
stability: evolving
last-reviewed: 2026-09-27
ms.topic: reference
---

# bSim Specification {#bsim-specification}

**TL;DR.** Build an independent Gargantua renderer in Zig 0.16.0 and Metal for the M4 MacBook Air. Target prepared 60 fps playback and native 4K exports. Quality has priority over offline speed. Thermal limits have priority over throughput. The targets below require measured acceptance.

## Scope

The target has an 8-core GPU and 16 GB memory.
Provide an iconic wide shot, an oblique orbit, and a close disk pass.
Use editable preset compositions and animated camera paths outside the horizon.

Provide a minimal animated CLI and a separate preview window.
Production textures, lens measurements, and exact movie compositions are unavailable.

## Optics

Trace past-directed null geodesics through Kerr spacetime with adaptive Runge-Kutta-Fehlberg integration.
Construct an orthonormal camera frame with a specified local velocity.
Use a scalar f64 CPU reference solver and an f32 Metal production solver.

Propagate beam footprints to filter disk structure and point stars.
Resolve higher disk images and narrow shadow features.
Track integration error and conserved quantities.

Refine difficult rays and route exceptional offline rays to the CPU solver.
An exhausted integration budget produces an unresolved result. It never implies capture.

## Appearance

Use dimensionless spin 0.6, a thin warm disk, suppressed relativistic color and brightness shifts, and soft veiling flare.
Use Figure 16 of the DNGR paper as the primary composition reference.
Derive orbit and close shots from the same disk model.

Use deterministic filaments, radial structure, differential rotation, and a thin volume density profile.
Preserve the shadow silhouette through motion.
Use an energy-normalized optical point spread function, controlled exposure, and a documented filmic display transform.


## Transport

Integrate unscattered emission and extinction along beams.
Trace the scattered contribution with volumetric paths.
Use importance sampling, directional path guiding, Russian roulette, and adaptive sampling.

Evaluate scattering in the local material frame.
Propagate each segment through Kerr spacetime. Evaluate animated material at the ray travel time.
Keep direct and scattered contributions separate to avoid double counting.

Retain a simple reference estimator for convergence checks.
Use full transport for final exports and prepared approximations for playback.
VCM and bidirectional tracing are outside the release requirements.


## Scheduling and Memory

Batch ray generation, integration, volume evaluation, shading, accumulation, and optics in Metal kernels.
Use compact work queues and compatible work groups for expensive tracing.
Select threadgroup sizes from measured results.

Reserve two logical CPU cores by default. Use a bounded worker pool.
Use measured explicit Zig vectors for suitable CPU batch operations. Compare scalar output and inspect generated code.
Overlap rendering, readback, compression, and file output with bounded queues.

Reuse allocations and allow at most three frames in flight.
Use f32 or f64 geometry and half color storage where appropriate.
Enable numerical shortcuts only after accuracy and timing checks.

Limit the default application working set to 6 GiB and the evictable disk cache to 8 GiB.

## Prepared Playback

Cache adaptive lens maps along each path with disk intersections, volume segments, background directions, and filtering data.
Interpolate only compatible outcomes within validated error bounds.
Trace discontinuities and difficult regions directly.

Invalidate caches on camera, spacetime, disk geometry, or renderer changes.
Benchmark a 2560 by 1440 viewport after preparation and thermal warm-up.
Permit internal dimensions from 50 to 100 percent. Use MetalFX spatial reconstruction.

Target an average of at least 59 presented fps with a 99th percentile frame interval no greater than 33.4 ms.
Record internal dimensions, CPU and GPU timings, memory, preparation duration, and thermal state for each shot.
Report offline time and convergence separately.


## Thermal Contract

The user requires battery temperature below 40 degrees Celsius and conservative CPU and GPU temperatures.
Read live battery and maximum available CPU and GPU sensors before sustained work.
Pause submissions at 37.5 degrees Celsius battery temperature, 75 degrees Celsius CPU or GPU temperature, or non-nominal system thermal state.

Resume below 36 degrees Celsius battery temperature and 65 degrees Celsius CPU and GPU temperature with nominal system thermal state.
Reject missing, invalid, or stale sensor samples. Do not provide a bypass flag.
Use bounded GPU submissions to limit work after a pause.

Thermal policy overrides fps targets and export speed. Preserve resumable output on cancellation.
Software cannot guarantee an absolute temperature ceiling or prevent all battery aging.
Ambient conditions, sensor lag, residual heat, and other processes remain outside application control.


## Interface

```text
bSim doctor
bSim shots
bSim prepare --shot wide
bSim preview --shot orbit
bSim render --shot close --format exr
bSim render --shot orbit --format prores --fps 24
bSim benchmark --all
```

Each rendering command accepts an editable versioned JSON scene with camelCase fields.
Include camera paths, disk parameters, optics, quality, timing, and deterministic seeds.
Freeze scene settings into an immutable export job.

Zig owns scene state, allocation, scheduling, cancellation, and errors.
The Objective-C bridge owns Apple framework integration through opaque handles and checked C layouts.
Share structured events between terminal progress and JSON output.

Use terminal colors F5F5F5, D4D4D4, and 949494 over the existing background.
Use short aligned labels, generous spacing, and a compact live area at approximately 10 updates per second.
Preserve scrollback. Support NO_COLOR, no-animation, narrow terminals, redirection, and JSON.

Show preparation, rendering, encoding, elapsed time, and estimates when available.
Restore terminal state on cancellation and failure.
The preview supports playback, pause, restart, scrubbing, fullscreen, and scene reload.


## Exports

Render native 3840 by 2160 stills and animations.
Default to 24 fps and a 180-degree shutter. Support 30 and 60 fps.
Use scene-linear RGB with Rec.709 primaries and documented chromaticities.

Export scene-linear half-float OpenEXR with lossless ZIP before exposure and display mapping.
Export finished 16-bit sRGB PNG images.
Export ProRes 422 HQ and H.264 MP4 with explicit Rec.709 metadata.

Use hardware encoding when supported.
Save settings and provenance beside outputs. Support resume, atomic completion, and bounded export queues.
Do not impose a hard offline time limit.


## Verification

Test the Schwarzschild limit, Kerr constants, capture, escape, disk hits, and CPU to GPU agreement.
Target shadow and disk image boundaries within half a pixel at 4K against the CPU solver.
Test volume attenuation, scattering conservation, and convergence against the reference estimator.

Review all three stills and moving sequences for silhouette, color, detail, secondary images, flare, and temporal stability.
Compare caches against direct tracing. Test geometry edits, invalidation, path transitions, and frame timing.
Test EXR values above display white, video counts and metadata, cancellation, resume, and disk-full failure.

Test terminal resize, redirection, animation suppression, and interruption.
Use separate correctness, GPU validation, and benchmark commands.

## Toolchain and Delivery

Pin Zig and ZLS to 0.16.0. Default to ReleaseSafe.
Compile the native bridge with Apple Clang and the Apple SDK.
Use Nix-managed FFmpeg and reproducibly pinned OpenEXRCore from the global dotfiles flake.

Start with runtime Metal compilation and cached pipelines.
Select developer tools per project. Do not change the global developer directory.
Follow the dotfiles master prompt, Zig prompt, ASD documentation rules, and commit standard.

Keep generated caches, renders, and build output outside version control.
Create one commit per concern and verify each automatic push to the public repository.
After implementation and verification, update ASD documentation in the same change set.


## References

- [DNGR paper and Figure 16](https://arxiv.org/html/1502.03808v2)
- [Metal language specification](https://developer.apple.com/metal/Metal-Shading-Language-Specification.pdf)
- [Apple threadgroup guidance](https://developer.apple.com/documentation/metal/calculating-threadgroup-and-grid-sizes)
- [Apple operating temperature guidance](https://support.apple.com/en-us/102336)

## Related Pages

- [Validation Record](refValidation.md#validation-record)
- [Documentation Index](../../index.md#documentation-index)
- [File and Command Index](refAnnexBIndexOfFilesAndCommands.md#file-and-command-index)
- [bSim](../../../README.md#bsim)
- [Agent Rules](../../../AGENTS.md#agent-rules)
