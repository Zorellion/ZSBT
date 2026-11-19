# Spec: Line-Anchored Pairing (partial `Mine` port)

Status: **SPEC — not implemented.** Written 2025-11-19 at commit `954e900`
(backup: `F:\REPOS\ZSBT-backup-20251119-954e900.zip`).

## Goal

Foreign hits currently pass the veto by *proximity* — any unconsumed damage
line near their timestamp confirms them. The named-attribution layer is
solved (tooltip facts + provenance learning + class resolution); what leaks
is **unnamed foreign numbers** shown as `src=generic`. This spec closes most
of that without a full `Mine.lua` port, by making line claims *competitive
and ordered* instead of first-come-first-served.

## What already exists (verified in code)

- `ZBattleText` records palette lines `{at, kind, consumed}` and
  `takeDamageLine(tHit, window, kinds)` already consumes **one line = one
  claim** (`ZBattleText.lua` ~line 195).
- Kind-restricted pairing already exists: `isAuto` candidates may only take
  `MELEE_KINDS` (OfferOutgoing fast path ~791, flushPending ~679); school-1
  hits prefer melee/ranged via `preferredKinds`.
- Deferred queue: `ZB._pending`, `DEFER_SEC`/`DEFER_WINDOW`, flushed by
  `flushPending` (~line 665) **in FIFO order**.
- Provenance flags: `payload.spellId`/`petSpellId` (sid-bearing candidates)
  vs `sid=nil` generics; `_sidLearn`/`_petSidLearn` mark cast-record
  provenance.

## The actual gap

`flushPending` drains FIFO. In a dense fight, own and foreign candidates
interleave in the queue; whichever drains first takes the line. A sid=nil
foreign hit queued *before* your real hit can consume the line yours needed —
yours then drops (`AUDROP`), the foreign one displays.

Additionally the **fast path** (`OfferOutgoing` immediate consume) lets any
candidate — including generic ones — claim a line instantly, before stronger
candidates even arrive.

## Design: provenance-tiered claiming

### Phase A — sorted drain (the 60% win)

In `flushPending`, sort `pend` before the consume loop:

- **Tier 1 — sid-bearing**: `payload.spellId ~= nil or payload.petSpellId ~= nil`.
  These are hits that consumed a real cast record, pet cast, or class-resolved
  guardian name — all already school-gated. They are overwhelmingly ours.
- **Tier 2 — generic**: `sid == nil`. Foreign bleed lives here.

Within a tier, keep FIFO (arrival order). Lines still consume one-for-one via
`takeDamageLine` — unchanged. Effect: real hits claim their lines first;
generic candidates only see leftovers, and in a busy fight there are none.

New audit marker per claim: `AUDCLAIM t=N tier=N sid=X kind=K` so diffs can
verify tier ordering worked.

### Phase B — generic candidates always defer

In `OfferOutgoing`: keep the fast path **only for tier-1 (sid-bearing)**
candidates — they get immediate confirmation and low display latency.
`sid=nil` candidates always queue to `_pending` and resolve in the sorted
batch at flush. This prevents an early generic from grabbing a line a
sid-bearing hit will need ~50ms later.

Cost: generic (legitimately own, unattributed) hits display up to
`DEFER_SEC` later — imperceptible, and already the norm for the deferred
path.

### Phase C — overflow ordering

`ZB._pending` cap (200) evicts oldest-first today. On overflow, evict
lowest-tier oldest first — a sid-bearing candidate should never be evicted
while a generic sits in the queue. Marker `AUDPENDOVERFLOW` already exists;
extend it with the evicted tier.

## Explicitly out of scope (full-port items)

- **Plate keys** (`token:generation`) — per-enemy identity. Needs nameplate
  generation tracking; big subsystem, deferred.
- **DoT rhythm learning** — tick-cadence evidence per nameplate. Deferred.
- **Per-cast outcome budgets for player casts** — consume-once exists
  already; per-target budgets need plate keys first.
- **Adaptive pair window** (median gap ×2+4ms) — nice-to-have; fixed
  windows are acceptable at current volumes.
- **Amount matching** — impossible on Retail (secret). Permanently out.

## Files touched

- `Parser/ZBattleText.lua` — `flushPending` sort (A), `OfferOutgoing`
  fast-path tier check (B), overflow eviction order (C), `AUDCLAIM` marker.
- Nothing else. `Event_Collector`, class modules, presentation untouched.

## Risks / honest tradeoffs

- Generic own hits (real damage that got no sid) may starve in saturated
  fights — they defer and can lose every line. They'd previously have
  displayed; now some drop. The same trade holds here: generic beats
  wrong, and dropped beats stolen.
- Sort is O(n log n) per flush on ≤200 items — negligible.
- `school=nil` sid-bearing hits are still tier-1 (unverifiable but
  provenanced). Correct: provenance is what earns the line.

## Verification

Same audit ritual (`/zsbt audit` + `/combatlog`, fight, reload, diff).

Expected deltas vs. current baseline:
- `AUDROP` count should rise for `sid=nil` candidates and fall for
  sid-bearing ones.
- `src=generic` AUDs should drop substantially in foreign-heavy fights.
- Real own named hits must not drop — tier-1 claim rate is the metric to
  watch in `AUDCLAIM` lines.
