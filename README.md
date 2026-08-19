# unattended-ops

Patterns for running several services and scheduled pipelines on one small
cloud instance, unattended, without them taking each other down.

> **Portfolio excerpt.** These are generalised versions of the units, scripts
> and postmortems from a private production host. Hostnames, paths and
> credentials are removed; the reasoning is kept, because the reasoning is the
> part that transfers.

## The host

A single 8 GB cloud instance runs, concurrently:

- **2 always-on services** — latency-sensitive, uncapped, normal priority
- **3 scheduled pipelines** — batch video work, memory-capped, lowest priority

All three pipelines publish daily on schedule with no manual intervention.
The host runs for weeks at a time; the only planned interruptions are kernel
patches, after which every service and timer comes back on its own.

## Tiered resource governance

A video render will take whatever memory it is given, and it shares the host
with services that must not be interrupted. That is a scheduling problem, not a
hardware problem, and it is solved by deciding in advance who loses when
resources are contended.

| Tier | Memory | Swap | Priority | Rationale |
|---|---|---|---|---|
| Always-on services | uncapped | uncapped | `Nice=0` | Capping trades a visible failure for a silent one |
| Batch pipeline A | `MemoryMax=3000M` | `256M` | `Nice=19`, `idle` IO | Heaviest render; the ceiling is the point |
| Batch pipeline B | `MemoryMax=2500M` | `256M` | `Nice=19`, `idle` IO | |
| Batch pipeline C | `MemoryMax=1500M` | `256M` | `Nice=19`, `idle` IO | Lightest job, tightest cap |

The batch jobs also stand down if a sibling pipeline is already running, so two
renders never overlap on one host.

See `systemd/` for the units, with the reasoning preserved in comments —
including why `MemoryHigh` is deliberately absent.

## Deploying without drift

`deploy/verified-deploy.sh` enforces one invariant: **a file on the server is a
committed file.**

- Refuses to deploy from a tree with uncommitted changes
- Compares `sha256` on both ends after transferring each file
- `--verify` proves the server matches git without transferring anything

This exists because servers drift. Somebody edits a file in place to fix
something at 2am, and from then on nobody knows what is actually running — and
the next deploy silently reverts the fix. A verify mode turns "I think the
server is up to date" into a command that answers the question.

## Incidents

Two write-ups, because unattended systems are judged on how they fail:

- [**A batch render took the whole host down**](incidents/oom-host-hang.md) —
  cron gives a job no cgroup and no memory accounting; the fix was timer-driven
  units with hard ceilings and a priority tier.
- [**A process froze for ten hours inside the memory throttle band**](incidents/throttle-band-livelock.md)
  — `MemoryHigh` and `MemoryMax` together created a range where a process could
  be throttled forever but never killed. Includes the diagnostic lesson that a
  stalled render produces a full-length file, so it must be detected by
  comparing frames rather than by checking duration.

## Cloud history

Services previously ran on **Azure**, were consolidated onto a **single AWS EC2
instance** to cut cost — from several always-on instances down to one — and were
later migrated again to a **different cloud provider**, which cut the monthly
bill by roughly 60% for more RAM and more vCPU than the instance it replaced.
Both moves were plain cost engineering: the workload is batch video and can live
anywhere, so it lives wherever it is cheapest to keep running.

Some of the Azure work never reached production; the consolidations, the
migration and everything else described here did.

## Stack

Ubuntu, systemd (units, timers, cgroup resource control), bash, Python,
ffmpeg, Linux cloud instances (Azure, AWS EC2, and current host),
private mesh networking for administrative access.
