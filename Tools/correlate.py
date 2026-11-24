#!/usr/bin/env python3
"""correlate.py — reconcile ZSBT's audit ring against WoWCombatLog.txt ground truth.

The disk combat log is the reference tape: every event carries sourceGUID +
sourceFlags (affiliation bit 0x1 = MINE, covers the player and owned
pets/guardians). The audit ring is ZSBT's own account: SHOW emits plus
AUDSUPP/AUDROP/AUDPASS suppression records, all timestamped in GetTime()
uptime. This script aligns the two clocks and reports:

  precision  — of everything ZSBT emitted, what actually came from MINE lines
  recall     — of all MINE damage in the log, what ZSBT actually displayed
  leakage    — emits whose only matching log event is foreign
  gate stats — of suppressed wounds, how many were actually ours (recall loss)
               vs correctly foreign kills

Usage:
    python correlate.py [--log PATH] [--sv PATH] [--tol MS] [--heals]

Defaults auto-detect the newest WoWCombatLog-*.txt in _retail_/Logs and the
retail SavedVariables file. Dev tool only — never packaged (.pkgmeta ignores
Tools/).
"""

import argparse
import csv
import io
import os
import re
import sys
from collections import Counter, defaultdict
from datetime import datetime, timedelta

RETAIL = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..")
DEFAULT_LOG_DIR = os.path.abspath(os.path.join(RETAIL, "Logs"))
DEFAULT_SV = os.path.abspath(os.path.join(
    RETAIL, "WTF", "Account", "ZARGON2006", "SavedVariables", "ZSBT.lua"))

DAMAGE_EVENTS = {
    "SPELL_DAMAGE", "SPELL_PERIODIC_DAMAGE", "RANGE_DAMAGE",
    "SWING_DAMAGE", "DAMAGE_SHIELD", "DAMAGE_SPLIT", "ENVIRONMENTAL_DAMAGE",
}
HEAL_EVENTS = {"SPELL_HEAL", "SPELL_PERIODIC_HEAL"}
OUTGOING_SHOW = {"OUTGOING_DAMAGE_COMBAT", "PET_DAMAGE_COMBAT", "OUTGOING_MISS_COMBAT"}

LOG_TS = re.compile(r"^(\d+)/(\d+)/(\d+) (\d+):(\d+):(\d+)\.(\d+)([+-]\d+)\s+([^,\s]+),(.*)$")
RING_LINE = re.compile(r"^\s*\"(.*)\",?\s*$")
KV = re.compile(r"(\w+)=(\S+)")


def log_seconds(line):
    m = LOG_TS.match(line)
    if not m:
        return None, None, None
    mo, d, y, hh, mm, ss, ms, tz = (int(m.group(i)) for i in range(1, 9))
    ev = m.group(9)
    rest = m.group(10)
    t = datetime(y, mo, d, hh, mm, ss) - timedelta(hours=tz)
    return t.timestamp() + ms / 1000.0, ev, rest


def parse_log_fields(rest):
    # One csv row; quoted names may contain spaces (commas inside names are
    # not emitted by the writer).
    return next(csv.reader(io.StringIO(rest)))


def scan_log(path, mine_only=True, lo=None, hi=None, include_heals=False):
    """Return list of (t, mine, sid, name, school, guid_is_player, heal)."""
    wanted = DAMAGE_EVENTS | (HEAL_EVENTS if include_heals else set())
    out = []
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            t, ev, rest = log_seconds(line)
            if ev is None or ev not in wanted:
                continue
            if lo is not None and not (lo <= t <= hi):
                continue
            f_ = parse_log_fields(rest)
            if len(f_) < 9:
                continue
            src_guid, src_flags = f_[0], f_[2]
            try:
                flags = int(src_flags, 16)
            except ValueError:
                continue
            mine = bool(flags & 0x1)
            if mine_only and not mine:
                continue
            heal = ev in HEAL_EVENTS
            if ev == "SWING_DAMAGE":
                sid, name = 0, "Melee"
                school = int(f_[10], 16) if len(f_) > 10 and f_[10].startswith("0x") else 1
            elif ev == "ENVIRONMENTAL_DAMAGE":
                sid, name, school = -1, f_[8] if len(f_) > 8 else "?", 0
            else:
                try:
                    sid = int(f_[8])
                except (ValueError, IndexError):
                    continue
                name = f_[9].strip('"') if len(f_) > 9 else "?"
                school = int(f_[10], 16) if len(f_) > 10 and f_[10].startswith("0x") else 0
            out.append((t, mine, sid, name, school,
                        src_guid.startswith("Player-"), heal))
    out.sort()
    return out


def read_ring(path, key):
    """Extract every string array ("key" = { "...", ... }) from ZSBT.lua.

    Each profile carries its own diagnostics ring, so the file may hold
    several blocks at different GetTime spans. Merge them all — downstream
    clock alignment keys on timestamps and self-selects the session that
    overlaps the combat log.
    """
    entries = []
    pat = re.compile(r'\["%s"\]\s*=\s*\{' % re.escape(key))
    in_block = False
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            if not in_block:
                if pat.search(line):
                    in_block = True
                continue
            if re.match(r"^\s*\},?\s*$", line):
                in_block = False
                continue
            m = RING_LINE.match(line)
            if m:
                entries.append(m.group(1))
    # Profiles that share a session hold byte-identical copies of the same
    # ring — dedupe so each event counts once.
    return list(dict.fromkeys(entries))


def parse_ring(entries):
    """Split ring entries into (ts, tag, kv-dict, raw)."""
    out = []
    for e in entries:
        m = re.match(r"^(\d+\.\d+)\s+(\S+)\s*(.*)$", e)
        if not m:
            continue
        ts, tag, rest = float(m.group(1)), m.group(2), m.group(3)
        kv = dict(KV.findall(rest))
        out.append((ts, tag, kv, e))
    return out


def scan_names(path):
    """sid -> spell name for every spell-bearing row (any source).

    Cast and damage spellIds diverge on retail — a wound binds the *cast* id
    (Black Arrow 466930, Kill Command 34026) while the log records the
    *damage* id (468572, 83381). Name equality joins alias sids without
    collapsing distinct spells (Bleak Arrows stays separate from Black
    Arrow)."""
    out = {}
    for line in open(path, "r", encoding="utf-8", errors="replace"):
        t, ev, rest = log_seconds(line)
        if ev is None:
            continue
        f_ = parse_log_fields(rest)
        if len(f_) < 10:
            continue
        try:
            sid = int(f_[8])
        except (ValueError, IndexError):
            continue
        name = f_[9].strip('"')
        if name:
            out.setdefault(sid, name)
    return out


CAST_EVENTS = {"SPELL_CAST_SUCCESS", "SPELL_CAST_START"}


def scan_anchor_events(path):
    """(t, sid) for MINE-flagged damage+cast events — alignment anchors only.

    Cast events vastly outnumber sid-bearing damage emits (a warlock's
    damage emits are mostly generic), so they are the anchor supply that
    makes the histogram peak unambiguous.
    """
    wanted = DAMAGE_EVENTS | CAST_EVENTS
    out = []
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            t, ev, rest = log_seconds(line)
            if ev is None or ev not in wanted:
                continue
            f_ = parse_log_fields(rest)
            if len(f_) < 9:
                continue
            try:
                flags = int(f_[2], 16)
            except ValueError:
                continue
            if not (flags & 0x1):
                continue
            if ev in CAST_EVENTS:
                try:
                    sid = int(f_[8])
                except (ValueError, IndexError):
                    continue
            elif ev == "SWING_DAMAGE":
                sid = 0
            else:
                try:
                    sid = int(f_[8])
                except (ValueError, IndexError):
                    continue
            out.append((t, sid))
    out.sort()
    return out


def align(shows, anchors):
    """Histogram (log_t - wound_t) over same-sid pairs; best offset wins.

    Merged profile rings hold several disjoint sessions — the strongest
    histogram peak can belong to a session that isn't in this log. Score
    each candidate offset by (peak bin count, emits it places inside the
    log's own span) and take the best.
    """
    by_sid = defaultdict(list)
    for t, sid in anchors:
        if sid:
            by_sid[sid].append(t)
    bins = defaultdict(int)
    for s in shows:
        sid = s["sid"]
        if sid is None or sid not in by_sid:
            continue
        for lt in by_sid[sid]:
            # No delta clamp: GetTime is process uptime vs wall-clock, so the
            # true offset may be hours. True pairs pile into one ~60ms bin
            # (wound->line jitter); false pairs smear across the whole span.
            bins[round((lt - s["wound_t"]) * 17) / 17] += 1
    if not bins or not anchors:
        return None, 0
    # Direct evidence scoring: a combat log spanning multiple fights holds
    # several histogram peaks — an earlier/later fight's same-sid events
    # form a rival offset that span-coverage cannot reject (both offsets
    # place emits inside the log's span). The true offset is the one under
    # which session emits actually land on same-sid anchor events.
    best = None  # ((tight, matched, peak), offset)
    for cand, peak in sorted(bins.items(), key=lambda kv: -kv[1])[:40]:
        matched = 0
        tight = 0
        for s in shows:
            sid = s["sid"]
            if sid is None or sid not in by_sid:
                continue
            wt = s["wound_t"] + cand
            dmin = None
            for lt in by_sid[sid]:
                d = abs(lt - wt)
                if dmin is None or d < dmin:
                    dmin = d
            if dmin is None:
                continue
            # Tightness beats raw match count: a wrong offset still lands
            # emits within the loose window of *some* same-sid anchor in a
            # dense fight (accidental matches), but only the true offset
            # clusters pairs at ~10-50ms.
            if dmin <= 0.15:
                matched += 1
            if dmin <= 0.06:
                tight += 1
        key = (tight, matched, peak)
        if best is None or key > best[0]:
            best = (key, cand)
    if best is None or best[0][0] < 3:
        return None, 0
    # Refine: mean delta of pairs inside +/-150ms of the winning bin.
    lo, hi = best[1] - 0.15, best[1] + 0.15
    ds = []
    for s in shows:
        sid = s["sid"]
        if sid is None or sid not in by_sid:
            continue
        for lt in by_sid[sid]:
            if lo < (lt - s["wound_t"]) < hi:
                ds.append(lt - s["wound_t"])
    off = sum(ds) / len(ds) if ds else best[1]
    return off, best[0][1]


def find_nearest(events, t, tol):
    """All events within +/-tol of t (events sorted by time)."""
    import bisect
    times = [e[0] for e in events]
    i = bisect.bisect_left(times, t - tol)
    out = []
    while i < len(events) and events[i][0] <= t + tol:
        out.append(events[i])
        i += 1
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", default=None)
    ap.add_argument("--sv", default=DEFAULT_SV)
    ap.add_argument("--tol", type=float, default=80, help="match tolerance ms")
    ap.add_argument("--heals", action="store_true")
    ap.add_argument("--sess", type=int, default=-1,
                    help="emit-session index from newest (-1=latest, -2=previous, ...)")
    ap.add_argument("--off", type=float, default=None,
                    help="force GetTime->log clock offset (skip auto-align)")
    args = ap.parse_args()

    log_path = args.log
    if not log_path:
        files = [f for f in os.listdir(DEFAULT_LOG_DIR)
                 if f.startswith("WoWCombatLog") and f.endswith(".txt")]
        if not files:
            sys.exit("no WoWCombatLog-*.txt in %s" % DEFAULT_LOG_DIR)
        log_path = os.path.join(DEFAULT_LOG_DIR,
                                max(files, key=lambda f: os.path.getmtime(
                                    os.path.join(DEFAULT_LOG_DIR, f))))
    print("log: %s" % log_path)
    print("sv:  %s" % args.sv)

    ucdrop = parse_ring(read_ring(args.sv, "ucdropLog"))
    audit = parse_ring(read_ring(args.sv, "auditLog"))
    if not ucdrop and not audit:
        sys.exit("both rings empty — enable /zsbt audit + /zsbt ucdrop first")

    # Emits: "T SHOW <type> sid=<n> dly=<d>" -> wound time = T - d.
    shows = []
    for ts, tag, kv, raw in ucdrop:
        if tag != "SHOW":
            continue
        m = re.match(r"^(\S+) sid=(\S+)", raw.split("SHOW", 1)[1].strip())
        kind = kv.get("__")  # unused
        parts = raw.split()
        typ = parts[2] if len(parts) > 2 else "?"
        sid = None if kv.get("sid") in (None, "nil") else int(float(kv["sid"]))
        dly = float(kv.get("dly") or 0)
        # ht= is the wound's UNIT_COMBAT timestamp — the exact join key.
        # Older records lack it; ts - dly approximates the same instant.
        wound_t = float(kv["ht"]) if kv.get("ht") else ts - dly
        shows.append({"wound_t": wound_t, "emit_t": ts, "type": typ,
                      "sid": sid, "via": kv.get("via", "emit"), "raw": raw})
    out_shows = [s for s in shows if s["type"] in OUTGOING_SHOW]
    print("ring: %d entries, %d emits (%d outgoing)" %
          (len(ucdrop) + len(audit), len(shows), len(out_shows)))

    # Merged profile rings hold several disjoint sessions. The newest one —
    # the test just run — is the target: split on >60s emit gaps and keep
    # the last cluster. (GetTime survives /reload, so all sessions in one
    # process share the offset; relogins/restarts change it.)
    sessions = []
    for s in sorted(out_shows, key=lambda x: x["emit_t"]):
        if sessions and s["emit_t"] - sessions[-1][-1]["emit_t"] > 60:
            sessions.append([])
        if not sessions:
            sessions.append([])
        sessions[-1].append(s)
    if sessions:
        pick = args.sess if -len(sessions) <= args.sess < len(sessions) else -1
        out_shows = sessions[pick]
        print("sessions found: %d — using index %d (%.0fs, %d emits, t=%.0f-%.0f)" %
              (len(sessions), pick,
               out_shows[-1]["emit_t"] - out_shows[0]["emit_t"],
               len(out_shows),
               out_shows[0]["emit_t"], out_shows[-1]["emit_t"]))
    all_shows = shows

    # Pass 1: MINE damage only — anchors for alignment + recall set.
    mine = scan_log(log_path, mine_only=True, include_heals=args.heals)
    print("log mine damage events: %d" % len(mine))
    if not out_shows or not mine:
        sys.exit("nothing to align")

    # Alignment anchors: sid-bearing SHOWs (casts included) *from the same
    # session* against MINE damage+cast events — denser and unambiguous.
    anchors = scan_anchor_events(log_path)
    s_lo, s_hi = out_shows[0]["emit_t"] - 5, out_shows[-1]["emit_t"] + 5
    anchor_shows = [s for s in shows
                    if s["sid"] is not None and s_lo <= s["emit_t"] <= s_hi]
    if args.off is not None:
        off, peak = args.off, -1
    else:
        off, peak = align(anchor_shows, anchors)
        if off is None or peak < 3:
            sys.exit("no confident clock alignment (peak=%d) — ring and log may "
                     "be different sessions" % peak)
    print("clock offset: %+.3fs (peak anchors=%d)" % (off, peak))

    tol = args.tol / 1000.0

    # Multiple profile rings are merged — only the session overlapping this
    # log is under test. Drop emits whose aligned time falls outside the
    # log's own span so foreign sessions can't pollute the stats.
    log_lo, log_hi = mine[0][0] - 2.0, mine[-1][0] + 2.0
    out_shows = [s for s in out_shows
                 if log_lo <= s["wound_t"] + off <= log_hi]
    print("emits in session: %d" % len(out_shows))

    # Pass 2: every damage event inside the audit window (foreign context).
    w_lo = min(s["wound_t"] for s in out_shows) + off - 1.0
    w_hi = max(s["wound_t"] for s in out_shows) + off + 1.0
    window = scan_log(log_path, mine_only=False, lo=w_lo, hi=w_hi,
                      include_heals=args.heals)
    print("log events in window: %d (%.1fs)" % (len(window), w_hi - w_lo))

    # sid -> name across the whole log: joins cast-ids to their damage-ids
    # by name so alias pairs (466930->468572) don't read as misattributions.
    names = scan_names(log_path)

    def sid_named_eq(emit_sid, log_ev):
        """Emit sid matches the log event by exact id or by spell name."""
        if emit_sid == log_ev[2]:
            return True
        if emit_sid is None or log_ev[2] is None:
            return False
        n = names.get(emit_sid)
        return n is not None and n == log_ev[3]

    # ---- Precision / leakage: classify each outgoing emit.
    cats = defaultdict(int)
    leaks = []
    matched_log = set()
    for s in out_shows:
        near = find_nearest(window, s["wound_t"] + off, tol)
        mine_hits = [e for e in near if e[1] and e[2] == s["sid"]]
        mine_alias = [e for e in near if e[1]
                      and e[2] != s["sid"] and sid_named_eq(s["sid"], e)]
        mine_any = [e for e in near if e[1]]
        foreign = [e for e in near if not e[1]]
        for e in mine_hits or mine_alias or mine_any:
            matched_log.add(id(e))
        if s["sid"] is not None and mine_hits:
            cat = "own_exact"
        elif s["sid"] is not None and mine_alias:
            cat = "own_alias"  # right name, cast-id vs damage-id sid
        elif s["sid"] is None and mine_any:
            cat = "own_generic" if not foreign else "own_generic_ambig"
        elif mine_any:
            # Named emit whose only near match is a different-NAME own event —
            # displayed under the wrong spell name.
            cat = "own_wrong_sid"
        elif foreign:
            cat = "LEAK"
            leaks.append((s["emit_t"], s["type"], s["sid"],
                          foreign[0][3], foreign[0][2]))
        else:
            cat = "no_log_match"
        # Stream-prefixed verdict: pet scroll and outgoing scroll are
        # separate questions — a leak into PET_DAMAGE_COMBAT answers the
        # "my damage is in the pet scroll" suspicion directly.
        cats["%s:%s" % (s["type"], cat)] += 1

    # ---- Recall: of all MINE damage in window, what was emitted.
    missed = Counter()
    per_spell = Counter()  # spellName -> matched
    per_spell_total = Counter()
    total_mine = 0
    for e in window:
        if not e[1] or e[6]:
            continue
        total_mine += 1
        per_spell_total[e[3]] += 1
        if id(e) not in matched_log:
            missed[e[3]] += 1
        else:
            per_spell[e[3]] += 1

    # ---- Gate accuracy: suppressed/dropped wounds vs the tape.
    # DROP carries the wound ht since the audit-enrichment pass; AUDROP
    # always did. UC_DROP BYPASS_* reasons are diagnostics (the wound
    # survives as unattributed), so they are excluded here by tag.
    gate = defaultdict(int)
    for ts, tag, kv, raw in ucdrop + audit:
        if tag not in ("AUDSUPP", "AUDROP", "AUDD", "AUDPASS", "DROP"):
            continue
        ht = kv.get("ht")
        if not ht:
            continue
        # Same session scoping: ignore ring entries outside this log's span.
        if not (log_lo <= float(ht) + off <= log_hi):
            continue
        # "killed own" needs evidence the dropped wound was OURS, not just a
        # mine event co-existing in a dense raid window: a sid match for
        # named drops, a school match for unattributed ones. Bare
        # co-occurrence at raid density is coincidence, reported separately.
        dsid = kv.get("sid")
        dsid = None if dsid in (None, "nil") else int(float(dsid))
        dsch = kv.get("school")
        dsch = None if dsch in (None, "nil") else int(float(dsch))
        near = find_nearest(window, float(ht) + off, tol)
        mine_near = [e for e in near if e[1]]
        if dsid is not None and any(e[2] == dsid for e in mine_near):
            gate["%s_killed_own_sid" % tag] += 1
        elif dsid is None and dsch is not None and any(
                e[4] == dsch for e in mine_near):
            gate["%s_killed_own_school" % tag] += 1
        elif mine_near:
            gate["%s_mine_nearby_ambig" % tag] += 1
        elif near:
            gate["%s_correct_foreign" % tag] += 1
        else:
            gate["%s_no_evidence" % tag] += 1

    print("\n=== EMIT CLASSIFICATION (precision) ===")
    for k, v in sorted(cats.items()):
        print("  %-30s %d" % (k, v))
    if leaks:
        print("\n  leaks (emit matched only foreign log events):")
        for t, typ, sid, lname, lsid in leaks[:20]:
            print("    t=%.3f emit sid=%s <- foreign %s (%s)" % (t, sid, lname, lsid))

    print("\n=== RECALL: MINE damage in window = %d ===" % total_mine)
    if total_mine:
        print("  displayed: %d (%.1f%%)  missed: %d" % (
            total_mine - sum(missed.values()),
            100.0 * (total_mine - sum(missed.values())) / total_mine,
            sum(missed.values())))
    for name, n in missed.most_common(15):
        print("    missed %-30s %d" % (name, n))

    print("\n=== PER-SPELL COVERAGE (own events shown vs total) ===")
    print("  %-28s %8s %8s %7s" % ("spell", "shown", "total", "pct"))
    for name, tot in per_spell_total.most_common(25):
        got = per_spell[name]
        print("  %-28s %8d %8d %6.1f%%" % (name, got, tot, 100.0 * got / tot))

    print("\n=== GATE ACCURACY (suppressed wounds vs tape) ===")
    for k, v in sorted(gate.items()):
        print("  %-32s %d" % (k, v))


if __name__ == "__main__":
    main()
