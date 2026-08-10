# Incident: a batch render took the whole host down

## Symptom

The instance stopped responding. SSH timed out. The always-on services were
unreachable. Recovery required a hard reboot from the cloud console.

## Impact

Every service on the host was down until someone noticed and rebooted it. The
scheduled output for that day never ran.

## Diagnosis

The host is a 2 GB shared instance. A video render was started by cron. Cron
gives a job no memory accounting and no cgroup of its own, so the render was
free to allocate until the kernel began thrashing. Once swap filled, the box
was not dead — it was too busy to answer SSH, which looks identical from
outside and is worse, because you cannot log in to fix it.

The specific allocation was an ffmpeg filter graph that buffered full-size
frames: a still image looped behind a filter whose branches consumed at
different rates, so frames accumulated without limit.

## Root cause

Two failures compounding:

1. **No resource ceiling.** Nothing bounded the render's memory, so a bug in
   one job could exhaust the host.
2. **No priority tiering.** The render competed on equal terms with services
   that must stay responsive.

## Fix

- Moved the job from cron to a systemd timer, so it inherits a unit with
  `MemoryMax` and `MemorySwapMax`. A runaway job now dies instead of taking
  the host with it.
- Gave the batch tier `Nice=19`, `IOSchedulingClass=idle` and a reduced
  `CPUWeight`, so it yields to the always-on services under contention.
- Capped swap per unit. Unbounded swap converts a fast crash into a slow hang,
  which is strictly harder to diagnose and recover from.
- Fixed the filter graph to process in bounded chunks rather than looping a
  still behind a rate-mismatched split.

## What it changed permanently

Any recurring job on a shared host runs as a timer-driven unit with an explicit
memory ceiling. The design rule is that a failing job must fail *loudly and
alone* — a job that can hang the host is a worse outcome than a job that dies.
