# Horizontal sharding — splitting a tenant across many machines

When a tenant has thousands of subscriptions, one machine can take a long time
to inventory all of them. Horizontal sharding lets you run the same tool on
several machines at once, with each machine responsible for a slice of the
subscriptions — no central coordinator, no shared database, and no risk of two
machines doing the same subscription or of a subscription being missed.

This document explains how it works in plain terms and how to use it.

## The problem it solves

Say you have 10 machines and a very large tenant. You want each machine to do a
roughly equal share of the subscriptions (about a tenth each), with two hard
rules:

- **No subscription is done twice** (that would waste time).
- **No subscription is skipped** (that would leave gaps in the report).

The catch: you don't want the machines talking to each other or sharing a
database to divide the work. Each machine should simply *know* which
subscriptions are its job. That is exactly what hash sharding does.

## The one idea: a repeatable fingerprint

Every Azure subscription has an ID that looks like a GUID
(`4a1f9c2b-....-............`). A **hash function** (SHA-256) takes that ID and
turns it into a large, scrambled number. The key property is that it is
**repeatable**: the same subscription ID always produces the same number — on
every machine, every time. Feed in the ID, always get the same fingerprint out.

We then take that big number and compute `number mod ShardCount` (the remainder
after dividing by the number of machines). With 10 machines that always yields a
result from 0 to 9 — a **bucket number**. So every subscription is permanently
assigned to one bucket, based purely on its own ID.

That is the whole trick. In the code this is the function
`Get-ShardKeyForSubscription` in `Functions/RunAllSubscriptions.Functions.ps1`:

```powershell
Get-ShardKeyForSubscription -SubscriptionId <the GUID> -ShardCount 10
# -> returns a bucket number 0..9
```

(If `ShardCount` is 1, it simply returns 0 — the "no sharding" case, which is
the normal single-machine behaviour.)

### Why SHA-256 and not a simpler hash

The bucket must be identical on every machine and every OS. `[string].GetHashCode()`
is *randomized per process* in modern .NET, so two machines would disagree.
SHA-256 of the lowercased ID is stable across processes, operating systems, and
CPU architectures. The first 4 bytes of the hash are assembled big-endian into a
number before the `mod`, so an x64 host and an ARM host compute the same bucket
for the same ID.

## How each machine uses it

Every machine runs the same command, changing only **which bucket is mine**:

```powershell
# Machine 0
./Run-AllSubscriptions.ps1 -ShardIndex 0 -ShardCount 10
# Machine 1
./Run-AllSubscriptions.ps1 -ShardIndex 1 -ShardCount 10
# ...
# Machine 9
./Run-AllSubscriptions.ps1 -ShardIndex 9 -ShardCount 10
```

Inside, each machine does three things:

1. Asks Azure for the **full list** of all subscriptions (every machine sees the
   same list).
2. For each subscription, computes its bucket number (0–9).
3. **Keeps only the subscriptions whose bucket matches its own `-ShardIndex`**
   and ignores the rest.

Steps 2 and 3 are the function `Select-ShardSubscriptions`. Machine 3 keeps only
subscriptions that hash to bucket 3; machine 7 keeps only bucket 7; and so on.

## A worked example

Four subscriptions, 10 machines:

| Subscription ID | Hash → bucket (mod 10) | Handled by |
|-----------------|------------------------|------------|
| `aaaa…`         | 7                      | Machine 7  |
| `bbbb…`         | 2                      | Machine 2  |
| `cccc…`         | 7                      | Machine 7  |
| `dddd…`         | 0                      | Machine 0  |

Machine 7 looks at all four, sees `aaaa` and `cccc` land in bucket 7, and does
those two. Machine 2 does `bbbb`. Machine 0 does `dddd`. Machines 1, 3, 4, 5, 6,
8, and 9 look at the same four subscriptions and keep none of them. Every
subscription is done exactly once, and no machine coordinated with any other.

## Why the two hard rules hold automatically

- **Nothing is done twice:** a subscription has exactly one hash, so it lands in
  exactly one bucket, so exactly one machine claims it.
- **Nothing is skipped:** every subscription lands in *some* bucket from 0 to
  `ShardCount-1`, and there is a machine for every bucket, so all of them are
  covered.
- **No coordination is needed:** the bucket depends *only* on the subscription's
  own ID — not on what other subscriptions exist, and not on what the other
  machines are doing — so all machines independently reach the same conclusions.
  They never have to talk to each other.

There is also a useful safety property: if a subscription is created or deleted,
it only affects its *own* bucket. It never reshuffles where the other
subscriptions go. That stability is why the split cannot be computed "per
machine" for the weighted variant — see the limitation below.

## The one limitation: balanced by count, not by size

Buckets are balanced by **number of subscriptions**, not by how big each
subscription is. Each machine gets roughly the same *count* of subscriptions,
but if one of them happens to be a very large subscription (say 40,000
resources), the machine that draws it will take longer than the others. Hash
sharding spreads the *number* of subscriptions evenly; it cannot see that one
subscription is a "whale".

For most tenants, with thousands of subscriptions, this evens out well enough in
practice. If subscription size is very uneven and wall-clock balance matters,
two other approaches address it:

- **Weighted plan:** do one cheap pre-pass that counts resources per
  subscription, then split so each machine's *total resource count* is roughly
  equal. This must be computed **once** and shared with all machines (evenness is
  a global property — it depends on all subscriptions together — so it cannot be
  computed independently per machine without risking overlaps or gaps).
- **Dynamic work-queue:** workers claim subscriptions from a shared store (e.g.
  Azure Table Storage) as they finish, so a machine that draws a whale simply
  claims fewer subscriptions. This balances by actual wall-clock and recovers
  from a crashed worker, at the cost of an external dependency and a claim
  protocol.

## Parameters reference

| Parameter      | Meaning                                                        | Default |
|----------------|----------------------------------------------------------------|---------|
| `-ShardCount`  | Total number of machines (buckets) splitting the tenant        | `1` (no sharding) |
| `-ShardIndex`  | Which bucket *this* machine handles, from `0` to `ShardCount-1` | `0`     |

Notes:

- `ShardCount = 1` (the default) means no sharding — the machine processes every
  eligible subscription, exactly as before.
- `ShardIndex` must be in the range `0 .. ShardCount-1`; the wrapper validates
  this up front and stops with a clear message otherwise.
- Run **one shard per machine**. Each machine should use its own inventory
  output folder. The resume-state file is scoped per shard, so `-Resume` on a
  machine only resumes that machine's own slice.

## Collecting the results

Each machine runs its own copy of `Run-AllSubscriptions.ps1`, so each one
produces its **own** consolidated outer zip
(`AllSubscriptions_ResourcesReport_<timestamp>.zip`) covering **only its slice**
of subscriptions. After 10 machines you therefore have **10 separate outer
zips**.

### Recommended: upload the shard zips separately

Each shard zip is a complete, self-contained report artifact — identical in
shape to what an ordinary single-machine run produces, just covering fewer
subscriptions. So the ingestion server accepts each one exactly like any normal
run's output: uploading the 10 shard zips is simply 10 normal ingestions.

Uploading them separately is usually the better choice:

- It spreads the ingestion load across 10 smaller uploads instead of one large
  merged archive.
- Because the shards are disjoint by construction, the 10 uploads together cover
  the whole tenant exactly once, with no duplicates and no gaps — no local merge
  step is required.

### Optional: merge locally into one MainSummary

You only need to merge locally if you want a single combined `MainSummary.html`
on your own machine (rather than one summary per shard). Note the tooling here:

- `Build-MainSummaryFromZip.ps1` rebuilds the aggregate `MainSummary.html` from
  **one** already-consolidated outer zip (via `-InputZip`). It does **not**
  combine multiple outer zips, and there is currently no single built-in command
  that merges the per-machine shard zips into one.

Merging is still straightforward, because each outer zip is just a flat
container holding one inner zip per subscription, and the shard slices are
disjoint (no two machines produce a zip for the same subscription, so there are
no name collisions). Gather the shard zips into a folder and run:

```powershell
# 1. Extract the inner per-subscription zips out of every shard's outer zip
#    into one staging folder.
$staging = New-Item -ItemType Directory -Path ./tenant-merge -Force
Get-ChildItem ./shard-zips -Filter 'AllSubscriptions_ResourcesReport_*.zip' |
    ForEach-Object { Expand-Archive -Path $_.FullName -DestinationPath $staging -Force }

# 2. Re-zip the collected per-subscription zips into one tenant-wide outer zip
#    (the same shape a single run produces).
$merged = './AllSubscriptions_ResourcesReport_tenant.zip'
Compress-Archive -Path (Join-Path $staging '*.zip') -DestinationPath $merged -Force

# 3. Build the aggregate MainSummary from the merged zip.
./Build-MainSummaryFromZip.ps1 -InputZip $merged
```
