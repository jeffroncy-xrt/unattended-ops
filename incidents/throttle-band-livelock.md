# Incident: a process froze for ten hours inside the memory throttle band

## Symptom

The daily pipeline produced no output. The unit was still `active`. The process
was still running, had not crashed, had not been killed, and had written
nothing for roughly ten hours.

## Impact

A full day's output was missing. Nothing alerted, because from the supervisor's
point of view the job was running normally.

## Diagnosis

The unit had both `MemoryHigh` and `MemoryMax` set. `MemoryHigh` does not kill
— it throttles reclaim aggressively once the process exceeds it. `MemoryMax`
kills.

The speech-synthesis step sat at roughly 1.5 GB resident, between the two
limits. That is the worst possible place to be:

- Above `MemoryHigh`, so the kernel throttled it continuously.
- Below `MemoryMax`, so it was never killed and never restarted.

It could not shrink, because the allocator's arena high-water mark does not
return to the OS just because the work finished — it stays claimed for reuse.
So the process was permanently throttled, making progress too slowly to ever
finish, and nothing in the system considered that an error.

**Diagnostic lesson:** a stalled render does not produce a short file. It
produces a full-length file with repeated frames. Checking output duration
suggested everything was fine. The freeze was only visible by comparing
successive frames — PSNR between neighbours collapses to identical — not by
inspecting file metadata.

## Root cause

A soft limit and a hard limit together created a band in which a process could
be permanently punished but never terminated. Livelock, not deadlock: it was
doing work, just never enough.

## Fix

- **Removed `MemoryHigh` entirely.** With only `MemoryMax`, the process either
  fits or is killed immediately. A fast, loud failure is recoverable; a silent
  ten-hour stall is not.
- **Isolated the memory-hungry step into a subprocess per unit of work**, so
  the allocator arena is returned to the OS after each unit instead of
  accumulating across the whole run.

Measured after the change: the step's resident memory sawtooths between roughly
260 MB and 760 MB against a 1400 MB ceiling, with no kills.

## What it changed permanently

Soft and hard memory limits are not combined on the same unit. Either bound a
process hard and let it die, or do not bound it — but never create a band where
it can be throttled indefinitely without ever failing.
