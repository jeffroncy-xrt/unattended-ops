# Three hosts in one year: Azure → AWS → Hetzner

> **Portfolio excerpt.** Generalised from a private production estate. Hostnames,
> IPs and credentials are removed; the reasoning and the measured numbers are
> kept, because those are the parts that transfer.

Five workloads — two latency-sensitive always-on trading services and three
scheduled video pipelines that publish daily — moved hosts twice. Each move was
driven by a different constraint, and the third one was measured before it was
committed to.

| | Azure | AWS | Hetzner |
|---|---|---|---|
| Shape | managed Functions + a VM | one `t3.small` | one shared-vCPU VPS |
| CPU / RAM | mixed | 2 burstable / 1.9 GB | 4 / 8 GB |
| Cost | credits, then a bill | **~$26/mo** | **~€6.81/mo** |
| Left because | serverless fought long jobs | RAM ceiling, price | — |

The headline is a 74% cost reduction with **4× the RAM and 2× the CPU**. The
interesting part is not the price, though: it is what a migration actually costs
you if you treat it as copying files.

## Why each move happened

**Azure → AWS.** The work was not serverless-shaped. A render that takes 2½ hours
and holds a gigabyte of intermediate state is a poor fit for a platform billed
and timed around short invocations, and the workarounds — chunking, external
state, keep-warm — were adding failure modes rather than removing them. A plain
VM was the honest answer.

**AWS → Hetzner.** Two constraints arrived together. The 1.9 GB instance had
produced two incidents where a render took the whole host down (see
`incidents/`), and both fixes were ceilings and caps — engineering around a RAM
shortage rather than fixing it. Meanwhile the same money bought four times the
memory elsewhere. Once the cheaper host was also the *more capable* one, staying
needed a justification nobody could give.

## Measure before you migrate

The move was triggered by wanting to run an **open-weights video model**
(LTX-2.5, 22B parameters) on **rented GPU capacity (RunPod)** instead of a
managed generation API. That is easy to assume and expensive to assume wrongly,
so it was measured first:

- Rented one 32 GB card by the hour, **spent about $0.70**, and answered three
  questions: does a 22B model fit in that VRAM under fp8, how many seconds of
  compute per second of output, and what does one unit of real work cost end to
  end. Measured: ~130 s per 8 s clip, **28.5 GB peak of 32.6** — which also ruled
  out the cheaper 24 GB cards that had looked adequate on paper.
- The answer was **$0.17 per unit against €5.60** for the managed API — but the
  point is that the number came *before* the commitment, not after.

That single measurement also killed a plan: a persistent network volume for the
~66 GB of model weights looked obviously right, and turned out to be both more
expensive and worse. Re-downloading the weights each run costs a few cents and
avoids pinning the job to one datacentre — which for a fixed-time daily job is
the difference between "runs" and "runs when capacity exists".

**Rent the GPU, don't own it.** A 24/7 GPU host is ~$245/mo for something used
under 4% of the time. Renting per-minute alongside a €7 always-on box costs
about $5/mo. The always-on tier and the burst tier have genuinely different
shapes; buying one machine for both is how you overpay for idle silicon.

## What a migration actually costs

Git had the code. Git had none of the things that broke.

**State that lives outside the repository.** Ledgers that record what has already
been published, credentials cached by third-party CLIs, model weights, log
directories a service creates on first run. One service kept 17 MB of live state
in a directory outside both the repo and `/var`; a path audit that checked
`/var`, `/opt` and `/etc` missed it entirely, and it was only found because the
service crashed loudly on start. Had it started *quietly*, it would have traded
with no memory of its own history.

**Cloud SDK credentials.** A video API authenticated through application-default
credentials cached in a dotfile directory. Nothing referenced it explicitly, so
nothing flagged it. Missing, it would have failed the next scheduled run only.

**Toolchain, not just dependencies.** The old host ran a hand-built static
`ffmpeg 7.1.5`; the new distribution shipped `6.1.1`. Every filter the pipelines
use exists in both, so nothing would have errored — the renders would simply have
come out subtly different, with no failure to investigate. The binary was copied
across rather than the version bumped as a side effect of changing hosts.

**Interpreter version.** One trading service pinned dependencies against Python
3.10; the new host defaulted to 3.12. Silently bumping the interpreter under code
that signs transactions is not a migration step, it is an unrelated change
wearing a migration's clothes. 3.10 was installed to match.

The general rule: **enumerate what a rebuild would need, not what the repo
contains.** Check `~/.config`, `/var/log`, home directories outside the project,
and anything a CLI wrote for itself.

## Cutting over without double-publishing

Every scheduled unit used `Persistent=true`, so a host that misses a run fires it
on next boot. Two hosts armed simultaneously therefore means the same work runs
twice — for publishing pipelines, a duplicate upload; for a trading service
sharing one wallet, two competing orders against one balance.

The invariant is **exactly one owner per workload at any instant**, enforced by a
cutover tool rather than by care:

1. Refuse if *that* workload is mid-run — checked per workload, so a long render
   of one pipeline does not block moving an unrelated one.
2. Disarm the old host. *The window opens here.*
3. Re-sync mutable state — ledgers, and OAuth tokens, **which rotate on use**, so
   a copy taken hours earlier can already be dead.
4. Arm the new host. *The window closes.*
5. Verify exactly one owner, and shout if the answer is "both" or "neither".

Copy-once-then-enable-later is the tempting shortcut and it is wrong: the state
moves between the copy and the cutover.

For the trading service the safe form was different again. An earlier plan to run
it on both hosts in parallel "to compare" was abandoned once it was clear both
instances would place orders against the same wallet. It became a clean handover
during a verified zero-open-orders window instead, with an authenticated
read-only API call from the new host as the pre-check.

## The regression a migration quietly introduces

The old provider's security group blocked inbound traffic, so SSH was
effectively private without anyone configuring it that way. The new provider
ships **no firewall at all**. After the move, the port was open — and so, on the
raw public IP over plain HTTP, was a service dashboard that had only ever been
reachable through a private mesh network.

Nothing broke. Nothing logged an error. The protection had simply been a property
of the old environment, and it did not travel.

Now: default-deny inbound, allow outbound, permit only the mesh network's address
range and interfaces, key-only SSH. The dashboards still work because mesh-network
tunnels arrive *through* the daemon rather than an open port — worth verifying
rather than assuming, because "close everything" and "the dashboards still work"
are not obviously compatible.

When changing a remote firewall, arm a rollback before the change and cancel it
after verifying. A locked-out host is a rescue-console problem.

## What transfers

- **Measure the expensive assumption first.** Under a dollar bought the number
  that justified the whole migration — and killed one plan inside it.
- **Match the toolchain, don't upgrade it mid-move.** Change one variable.
- **Inventory what a rebuild needs, not what the repo has.** The gaps are all
  outside version control, and they fail later, quietly.
- **One owner per workload,** enforced mechanically, with mutable state synced
  inside the cutover window.
- **Re-verify the security posture on the new host.** Some of it was the old
  environment's property, not your configuration.
- **Separate the always-on tier from the burst tier.** They have different
  shapes; one machine sized for both is idle silicon you paid for.
