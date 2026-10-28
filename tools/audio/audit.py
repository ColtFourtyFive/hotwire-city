#!/usr/bin/env python3
"""Audio audit for Hotwire City (PLAN C3 · BACKLOG audio): every Config/Sounds id must be public, downloadable,
audible and sane.

    python3 -I tools/audio/audit.py                       audit Config/Sounds -> docs/v2/evidence/audio_audit.md (+ .json)
    python3 -I tools/audio/audit.py --ids 1,2,3           audit candidate ids (table on stdout, nothing written)
    python3 -I tools/audio/audit.py --envelope ID [--hop S] [--from A --to B]
                                                          RMS / spectral-centroid timeline + steady segments
                                                          (engine loop-region picking: idle, on-load, off-load)
    python3 -I tools/audio/audit.py --search "query" [--all-creators] [--limit N]
                                                          Creator Store audio search, licensed creators only

What it checks per id:
  * toolbox-service item details (public endpoint): exists, visibilityStatus 0 (public), hash approved, free,
    creator (Pro Sound Effects / APM / Audioscape / Roblox are Roblox-licensed; anything else is flagged THIRD_PARTY
    for a human look), title / description / duration.
  * Open Cloud asset delivery (tools/sources/rbxdl.py helpers, API key never printed): downloadable, format.
  * ffmpeg decode -> numpy: duration, peak dBFS, active RMS dBFS (a loudness proxy: un-weighted RMS of the frames
    above the silence floor), clipped-sample ratio, leading / trailing silence, silent share. For defs with a
    PlaybackRegion (start / stop) or LoopRegion (loopStart / loopEnd): region inside the file, region RMS, loop seam
    jump (dB between the region's last and first 50 ms) and region steadiness.
  * Flags: MISSING (no details), PRIVATE, NOT_APPROVED, NOT_FREE, DL_FAIL, DECODE_FAIL, SILENT, CLIP, LONG,
    LEAD_SILENCE, REGION_OOB, QUIET_REGION, SEAM, THIRD_PARTY, VOICE? (description mentions speech: content-safety
    review; our rule is no voices saying names / numbers / real agencies).

Downloads go to a temporary directory that is deleted at the end (disk is tight); nothing is cached.
No uploads happen here.
"""
import argparse
import concurrent.futures as cf
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "tools"))
sys.path.insert(0, os.path.join(ROOT, "tools", "sources"))

import rbxdl  # noqa: E402  (asset delivery helpers; key handled inside rbxcloud, never printed)

import numpy as np  # noqa: E402

SR = 22050
FRAME = 0.05  # s, analysis frame
SILENCE_DB = -50.0
OUT_MD = os.path.join(ROOT, "docs", "v2", "evidence", "audio_audit.md")
OUT_JSON = os.path.join(ROOT, "docs", "v2", "evidence", "audio_audit.json")

# Roblox-licensed audio publishers (platform licence deals): Pro Sound Effects, APM Music, Audioscape, plus Roblox's
# own accounts (Roblox, the verified Roblox Resources group).
LICENSED = {
    7462895450: "Pro Sound Effects",
    7462718749: "APM Music",
    34159607: "Audioscape",
    1: "Roblox",
    3529469: "Roblox Resources",  # verified group run by Roblox's CreatorKnowledge account (template / docs assets)
}
# Soft flags a human reviewed and accepted, with the reason (shown in the report; the flag stays in the table so a
# changed file is still visible). Keyed by Config/Sounds key; "Radio_*" covers every radio track.
REVIEWED = {
    "Radio_*": {"CLIP": "APM masters are loud (inter-sample overs after lossy decode); played at Volume 0.26-0.32 on "
                        "HC_Music under a 0.85 group base, > 10 dB of headroom in the mix."},
    "Melee_Punch2": {"CLIP": "0.3 % of samples on a punch transient; played at 0.62, inaudible."},
    "HotwireCrackle": {"QUIET_REGION": "a soft electrical-arcing take (-41 dB RMS); compensated with Volume 3.0."},
    "Amb_Plane1": {"QUIET_REGION": "a distant overhead plane: meant to sit under the bed; Volume raised to 0.7.",
                   "LONG": "34 s PlaybackRegion of a 76 s fly-over: an overhead pass is long by nature."},
}
VOICE_WORDS = re.compile(r"\b(voice|voices|talk|talking|speech|speaks?|dispatcher|announcer|chatter|vocal|says|"
                         r"spoken|conversation|walla|crowd talk|scanner)\b", re.I)
TOOLBOX_DETAILS = "https://apis.roblox.com/toolbox-service/v1/items/details?assetIds={ids}"
TOOLBOX_SEARCH = "https://apis.roblox.com/toolbox-service/v2/assets:search?searchCategoryType=Audio&query={q}" \
                 "&maxPageSize={n}{tok}"


def http_json(url, tries=4):
    delay = 1.5
    last = None
    for _ in range(tries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "HotwireCity-audio-audit/1.0",
                                                       "Accept": "application/json"})
            with urllib.request.urlopen(req, timeout=60) as r:
                return json.loads(r.read().decode("utf-8", "replace"))
        except Exception as e:  # noqa: BLE001
            last = e
            time.sleep(delay)
            delay *= 2
    raise RuntimeError(f"GET failed: {type(last).__name__}: {str(last)[:120]}")


def details(ids):
    """toolbox-service details for many ids -> {id: dict}."""
    out = {}
    ids = list(dict.fromkeys(int(i) for i in ids))
    for i in range(0, len(ids), 25):
        chunk = ids[i:i + 25]
        try:
            j = http_json(TOOLBOX_DETAILS.format(ids=",".join(str(x) for x in chunk)))
        except RuntimeError as e:
            for x in chunk:
                out[x] = {"error": str(e)}
            continue
        for item in j.get("data") or []:
            a = item.get("asset") or {}
            c = item.get("creator") or {}
            fp = item.get("fiatProduct") or {}
            ad = a.get("audioDetails") or {}
            out[int(a.get("id"))] = {
                "name": a.get("name"),
                "title": ad.get("title"),
                "artist": ad.get("artist"),
                "audioType": ad.get("audioType"),
                "typeId": a.get("typeId"),
                "duration": a.get("duration"),
                "description": (a.get("description") or "")[:400],
                "visibility": a.get("visibilityStatus"),
                "approved": a.get("isAssetHashApproved"),
                "creatorId": c.get("id"),
                "creator": c.get("name"),
                "verified": c.get("isVerifiedCreator"),
                "free": fp.get("isFree"),
            }
        time.sleep(0.4)
    return out


def download(aid, tmp):
    """Asset delivery -> local file path, or (None, error)."""
    st, body = rbxdl._api_get(rbxdl.API.format(id=aid))
    if st != 200:
        return None, f"HTTP {st}: {(body or '')[:120]}"
    j = json.loads(body)
    loc = j.get("location")
    if not loc:
        errs = j.get("errors") or []
        msg = errs[0].get("message") if errs and isinstance(errs[0], dict) else "no location"
        return None, str(msg)[:120]
    data = rbxdl._decompress(rbxdl._cdn_get(loc))
    kind, ext, _ = rbxdl.detect(data)
    path = os.path.join(tmp, f"{aid}.{ext}")
    with open(path, "wb") as f:
        f.write(data)
    return path, kind


def decode(path):
    p = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-ac", "1", "-ar", str(SR), "-f", "f32le", "-"],
                       capture_output=True, timeout=180)
    if p.returncode != 0 or not p.stdout:
        raise RuntimeError((p.stderr or b"").decode("utf-8", "replace")[:160])
    return np.frombuffer(p.stdout, dtype=np.float32)


def db(x):
    return 20.0 * math.log10(max(float(x), 1e-9))


def frames_db(x, frame=FRAME):
    n = max(1, int(SR * frame))
    m = len(x) // n
    if m == 0:
        return np.array([db(np.sqrt(np.mean(x ** 2)) if len(x) else 0.0)])
    f = x[: m * n].reshape(m, n)
    rms = np.sqrt(np.mean(f.astype(np.float64) ** 2, axis=1))
    return 20.0 * np.log10(np.maximum(rms, 1e-9))


def analyse(x, region=None, loop=False):
    out = {}
    out["duration"] = round(len(x) / SR, 2)
    peak = float(np.max(np.abs(x))) if len(x) else 0.0
    out["peak_db"] = round(db(peak), 1)
    fdb = frames_db(x)
    active = fdb[fdb > SILENCE_DB]
    if len(active):
        lin = 10 ** (active / 20.0)
        out["rms_db"] = round(db(np.sqrt(np.mean(lin ** 2))), 1)
    else:
        out["rms_db"] = -99.0
    out["silent_share"] = round(float(np.mean(fdb <= SILENCE_DB)), 2)
    lead = 0
    while lead < len(fdb) and fdb[lead] <= SILENCE_DB:
        lead += 1
    trail = 0
    while trail < len(fdb) and fdb[len(fdb) - 1 - trail] <= SILENCE_DB:
        trail += 1
    out["lead_silence"] = round(lead * FRAME, 2)
    out["trail_silence"] = round(trail * FRAME, 2)
    clipped = np.abs(x) >= 0.995
    out["clip_ratio"] = round(float(np.mean(clipped)) if len(x) else 0.0, 5)
    if region:
        a, b = region
        b = min(b, len(x) / SR) if b else len(x) / SR
        seg = x[int(a * SR): int(b * SR)]
        out["region"] = [a, round(b, 2)]
        out["region_oob"] = a >= len(x) / SR or (region[1] is not None and region[1] > len(x) / SR + 0.05)
        if len(seg):
            sdb = frames_db(seg)
            act = sdb[sdb > SILENCE_DB]
            out["region_rms_db"] = round(db(np.sqrt(np.mean((10 ** (act / 20.0)) ** 2))), 1) if len(act) else -99.0
            out["region_steady_db"] = round(float(np.std(sdb)), 1)
            if loop and len(sdb) >= 2:
                out["seam_db"] = round(abs(float(sdb[-1] - sdb[0])), 1)
    return out



def feature_track(x, hop=0.01, win=1024):
    """(rms dB, spectral centroid Hz) every `hop` seconds."""
    n = max(1, int(SR * hop))
    w = np.hanning(win)
    freqs = np.fft.rfftfreq(win, 1.0 / SR)
    out = []
    for start in range(0, max(1, len(x) - win), n):
        seg = x[start:start + win]
        if len(seg) < win:
            break
        spec = np.abs(np.fft.rfft(seg * w))
        s = float(np.sum(spec))
        c = float(np.sum(spec * freqs) / s) if s > 1e-9 else 0.0
        out.append((db(np.sqrt(np.mean(seg.astype(np.float64) ** 2))), c))
    return np.array(out) if out else np.zeros((0, 2))


def zero_cross_near(x, i, rising=True, span=400):
    """Index of the closest zero crossing (same slope) to sample i."""
    lo, hi = max(1, i - span), min(len(x) - 1, i + span)
    seg = x[lo - 1:hi]
    if rising:
        idx = np.where((seg[:-1] <= 0) & (seg[1:] > 0))[0]
    else:
        idx = np.where((seg[:-1] >= 0) & (seg[1:] < 0))[0]
    if len(idx) == 0:
        return i
    idx = idx + lo
    return int(idx[np.argmin(np.abs(idx - i))])


def loop_candidates(x, a, b, min_len, max_len, top=5, win=0.35):
    """Best LoopRegion lengths inside [a, b] s: compares the feature track (level + brightness) just after the loop
    start with the track just after start+L (what plays after the seam), so the seam does not jump. Returns
    [(start s, end s, cost)] with both ends snapped to rising zero crossings."""
    tr = feature_track(x[int(a * SR): int(b * SR)])
    if len(tr) < 10:
        return []
    hop = 0.01
    w = max(5, int(win / hop))
    ref = tr[:w]
    cmean = max(1.0, float(np.mean(tr[:, 1])))
    res = []
    for L in range(int(min_len / hop), int(max_len / hop) + 1):
        if L + w > len(tr):
            break
        cand = tr[L:L + w]
        cost = float(np.mean(np.abs(cand[:, 0] - ref[:, 0])) + 12 * np.mean(np.abs(cand[:, 1] - ref[:, 1])) / cmean)
        res.append((cost, L))
    res.sort()
    picked = []
    for cost, L in res:
        if any(abs(L - q) < 20 for _, q in picked):
            continue
        picked.append((cost, L))
        if len(picked) >= top:
            break
    out = []
    s0 = zero_cross_near(x, int(a * SR))
    for cost, L in picked:
        e = zero_cross_near(x, s0 + int(L * hop * SR))
        out.append((round(s0 / SR, 3), round(e / SR, 3), round(cost, 2)))
    return out


def flags_for(meta, info, def_):
    f = []
    if not meta or meta.get("error"):
        f.append("MISSING")
        return f
    if meta.get("visibility") not in (0, None):
        f.append("PRIVATE")
    if meta.get("approved") is False:
        f.append("NOT_APPROVED")
    if meta.get("free") is False:
        f.append("NOT_FREE")
    if meta.get("creatorId") not in LICENSED:
        f.append("THIRD_PARTY")
    text = f"{meta.get('name') or ''} {meta.get('description') or ''}"
    if VOICE_WORDS.search(text):
        f.append("VOICE?")
    if info is None:
        return f
    if info.get("dl_error"):
        f.append("DL_FAIL")
        return f
    if info.get("decode_error"):
        f.append("DECODE_FAIL")
        return f
    music = bool(def_ and def_.get("station")) or (meta.get("audioType") == "Music")
    looped = bool(def_ and (def_.get("looped") or def_.get("loopStart") is not None))
    if info["rms_db"] < -45 or info["silent_share"] > 0.9:
        f.append("SILENT")
    if info["clip_ratio"] > 0.002:
        f.append("CLIP")
    if (not music and not looped and info["duration"] > 60) or info["duration"] > 330:
        f.append("LONG")
    has_start = bool(def_ and (def_.get("start") is not None or def_.get("loopStart") is not None))
    if not music and not looped and not has_start and info["lead_silence"] > 0.3:
        f.append("LEAD_SILENCE")
    if info.get("region_oob"):
        f.append("REGION_OOB")
    if info.get("region_rms_db") is not None and info["region_rms_db"] < -40:
        f.append("QUIET_REGION")
    if info.get("seam_db") is not None and info["seam_db"] > 6:
        f.append("SEAM")
    return f


def dump_sounds(tmp):
    out = os.path.join(tmp, "sounds.json")
    p = subprocess.run(["lune", "run", "tools/audio/dump_sounds.luau", out], cwd=ROOT, capture_output=True,
                       text=True, timeout=120)
    if p.returncode != 0:
        raise SystemExit("dump_sounds failed: " + (p.stderr or p.stdout)[-400:])
    return json.load(open(out))


def id_of(s):
    m = re.search(r"rbxassetid://(\d+)", s or "")
    return int(m.group(1)) if m else None


def audit_ids(ids, tmp, regions=None, defs_by_id=None, jobs=4):
    meta = details(ids)
    infos = {}

    def work(aid):
        path, kind = download(aid, tmp)
        if not path:
            return aid, {"dl_error": kind}
        try:
            x = decode(path)
        except Exception as e:  # noqa: BLE001
            return aid, {"decode_error": str(e)[:120], "format": kind}
        finally:
            try:
                os.remove(path)
            except OSError:
                pass
        res = {"format": kind, "_x": x}
        return aid, res

    with cf.ThreadPoolExecutor(max_workers=jobs) as ex:
        for aid, res in ex.map(work, ids):
            if "_x" in res:
                x = res.pop("_x")
                base = analyse(x)
                res.update(base)
                res["regions"] = {}
                for key, (reg, loop) in (regions or {}).get(aid, {}).items():
                    res["regions"][key] = analyse(x, reg, loop)
                del x
            infos[aid] = res
    return meta, infos


def fmt_row(cells):
    return "| " + " | ".join(str(c).replace("|", "/") for c in cells) + " |"


def run_config(args):
    tmp = tempfile.mkdtemp(prefix="hc_audio_")
    try:
        rows = dump_sounds(tmp)
        by_id = {}
        regions = {}
        builtin = []
        for r in rows:
            aid = id_of(r.get("id"))
            if aid is None:
                builtin.append(r)
                continue
            by_id.setdefault(aid, []).append(r)
            if r.get("start") is not None or r.get("stop") is not None:
                regions.setdefault(aid, {})[r["key"]] = ((r.get("start") or 0, r.get("stop")), False)
            if r.get("loopStart") is not None or r.get("loopEnd") is not None:
                regions.setdefault(aid, {})[r["key"]] = ((r.get("loopStart") or 0, r.get("loopEnd")), True)
        ids = sorted(by_id)
        print(f"auditing {len(ids)} ids ({len(rows)} keys, {len(builtin)} built-in rbxasset sounds)", flush=True)
        meta, infos = audit_ids(ids, tmp, regions)
        report = []
        bad = 0
        for aid in ids:
            m = meta.get(aid)
            info = infos.get(aid)
            keys = by_id[aid]
            fl = set()
            for d in keys:
                sub = dict(info or {})
                reg = (info or {}).get("regions", {}).get(d["key"])
                if reg:
                    sub.update({k: v for k, v in reg.items() if k.startswith("region") or k == "seam_db"})
                fl.update(flags_for(m, sub if info else None, d))
            hard = fl & {"MISSING", "PRIVATE", "NOT_APPROVED", "NOT_FREE", "DL_FAIL", "DECODE_FAIL", "SILENT",
                         "REGION_OOB"}
            if hard:
                bad += 1
            report.append({"id": aid, "keys": [d["key"] for d in keys], "meta": m, "info": info,
                           "flags": sorted(fl), "hard": sorted(hard)})
        write_report(report, builtin, bad)
        print(f"{len(ids)} ids, {bad} with hard failures -> {os.path.relpath(OUT_MD, ROOT)}")
        for r in report:
            if r["flags"]:
                print(f"  {r['id']:>16}  {','.join(r['keys'])[:60]:<60} {' '.join(r['flags'])}")
        return 1 if bad else 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def write_report(report, builtin, bad):
    lines = []
    lines.append("# Audio audit (Config/Sounds)")
    lines.append("")
    lines.append(f"Generated by `python3 -I tools/audio/audit.py` on {time.strftime('%Y-%m-%d %H:%M UTC', time.gmtime())}."
                 " Every id is checked against the public toolbox-service details (exists, public, approved, free,"
                 " creator) and downloaded through Open Cloud asset delivery, decoded with ffmpeg and measured with"
                 " numpy. Downloads are deleted after analysis.")
    lines.append("")
    total = len(report)
    licensed = sum(1 for r in report if r["meta"] and r["meta"].get("creatorId") in LICENSED)
    lines.append(f"**{total} unique ids**, {licensed} from Roblox-licensed publishers (Pro Sound Effects, APM, Audioscape,"
                 f" Roblox); **{bad} with hard failures**. {len(builtin)} keys use built-in `rbxasset://` engine sounds"
                 " (always available, not audited).")
    lines.append("")
    lines.append("Columns: dur = measured seconds; peak / RMS = dBFS (RMS over frames above -50 dBFS, an un-weighted"
                 " loudness proxy); clip = share of samples at full scale; lead = leading silence (s); region = the"
                 " PlaybackRegion / LoopRegion used by that key with its RMS, steadiness (std dB) and loop seam jump.")
    lines.append("")
    lines.append("Flag legend: hard = MISSING, PRIVATE, NOT_APPROVED, NOT_FREE, DL_FAIL, DECODE_FAIL, SILENT, REGION_OOB"
                 " (must be fixed); soft = CLIP, LONG, LEAD_SILENCE, QUIET_REGION, SEAM, THIRD_PARTY (not a licensed"
                 " publisher: human check), VOICE? (description mentions speech: content-safety check).")
    lines.append("")
    lines.append(fmt_row(["id", "keys", "title (creator)", "dur", "peak", "RMS", "clip", "lead", "regions", "flags"]))
    lines.append(fmt_row(["---"] * 10))
    for r in report:
        m = r["meta"] or {}
        i = r["info"] or {}
        regs = []
        for k, v in (i.get("regions") or {}).items():
            s = f"{k}: {v.get('region')} {v.get('region_rms_db')} dB ±{v.get('region_steady_db')}"
            if v.get("seam_db") is not None:
                s += f" seam {v['seam_db']}"
            regs.append(s)
        title = f"{m.get('name') or '?'} ({LICENSED.get(m.get('creatorId'), m.get('creator') or '?')})"
        lines.append(fmt_row([
            r["id"], ", ".join(r["keys"]), title[:70],
            i.get("duration", i.get("dl_error", i.get("decode_error", "-"))),
            i.get("peak_db", "-"), i.get("rms_db", "-"), i.get("clip_ratio", "-"), i.get("lead_silence", "-"),
            "<br>".join(regs) or "-", " ".join(r["flags"]) or "ok",
        ]))
    lines.append("")
    lines.append("Built-in engine sounds (not audited): " + ", ".join(f"`{b['key']}`" for b in builtin))
    lines.append("")
    # reviewed soft flags (REVIEWED): which flagged keys a human accepted, and why
    reviewed = []
    for r in report:
        for key in r["keys"]:
            rules = REVIEWED.get(key) or (REVIEWED.get("Radio_*") if key.startswith("Radio_") else None) or {}
            for flag in r["flags"]:
                if flag in rules:
                    reviewed.append((key, flag, rules[flag]))
    if reviewed:
        lines.append("## Reviewed soft flags")
        lines.append("")
        lines.append(fmt_row(["key", "flag", "decision"]))
        lines.append(fmt_row(["---"] * 3))
        for key, flag, why in sorted(reviewed):
            lines.append(fmt_row([key, flag, why]))
        lines.append("")
    open_soft = []
    for r in report:
        for flag in r["flags"]:
            covered = any(
                flag in (REVIEWED.get(k) or (REVIEWED.get("Radio_*") if k.startswith("Radio_") else None) or {})
                for k in r["keys"])
            if not covered:
                open_soft.append(f"{r['id']} {flag} ({', '.join(r['keys'])})")
    lines.append(f"Unreviewed flags: {len(open_soft)}" + (": " + "; ".join(open_soft) if open_soft else "."))
    lines.append("")
    os.makedirs(os.path.dirname(OUT_MD), exist_ok=True)
    with open(OUT_MD, "w") as f:
        f.write("\n".join(lines))
    slim = [{k: v for k, v in r.items()} for r in report]
    with open(OUT_JSON, "w") as f:
        json.dump(slim, f, indent=1, sort_keys=True)


def run_ids(args):
    ids = [int(x) for x in re.split(r"[,\s]+", args.ids) if x.strip()]
    tmp = tempfile.mkdtemp(prefix="hc_audio_")
    try:
        meta, infos = audit_ids(ids, tmp)
        for aid in ids:
            m = meta.get(aid) or {}
            i = infos.get(aid) or {}
            fl = flags_for(m, i, None)
            print(f"{aid:>16} {str(m.get('name'))[:44]:<44} {LICENSED.get(m.get('creatorId'), m.get('creator'))!s:<18}"
                  f" dur {i.get('duration', '-')!s:>6} peak {i.get('peak_db', '-')!s:>6} rms {i.get('rms_db', '-')!s:>6}"
                  f" lead {i.get('lead_silence', '-')!s:>5} {' '.join(fl)}")
            if args.verbose and m.get("description"):
                print("                 " + m["description"].replace("\n", " ")[:300])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def centroid_track(x, hop):
    n = int(SR * hop)
    win = 2048
    out = []
    w = np.hanning(win)
    freqs = np.fft.rfftfreq(win, 1.0 / SR)
    for start in range(0, max(1, len(x) - win), n):
        seg = x[start:start + win]
        if len(seg) < win:
            break
        spec = np.abs(np.fft.rfft(seg * w))
        s = float(np.sum(spec))
        c = float(np.sum(spec * freqs) / s) if s > 1e-9 else 0.0
        rms = float(np.sqrt(np.mean(x[start:start + n] ** 2)))
        out.append((start / SR, db(rms), c))
    return out


def steady_segments(track, hop, min_len=1.5, max_db_std=1.6, max_c_rel=0.09):
    """Greedy: longest windows whose RMS (dB) std and centroid relative std stay under the limits."""
    segs = []
    n = len(track)
    i = 0
    need = max(2, int(min_len / hop))
    while i < n - need:
        j = i + need
        if track[i][1] < -40:
            i += 1
            continue

        def ok(a, b):
            d = np.array([t[1] for t in track[a:b]])
            c = np.array([t[2] for t in track[a:b]])
            return np.std(d) <= max_db_std and np.std(c) <= max_c_rel * max(np.mean(c), 1) and np.min(d) > -40

        if not ok(i, j):
            i += 1
            continue
        while j < n and ok(i, j + 1):
            j += 1
        d = [t[1] for t in track[i:j]]
        c = [t[2] for t in track[i:j]]
        segs.append((round(track[i][0], 2), round(track[j - 1][0] + hop, 2), round(float(np.mean(d)), 1),
                     int(np.mean(c))))
        i = j
    segs.sort(key=lambda s: -(s[1] - s[0]))
    return segs


def run_envelope(args):
    aid = int(args.envelope)
    tmp = tempfile.mkdtemp(prefix="hc_audio_")
    try:
        meta = details([aid]).get(aid) or {}
        print(f"{aid} {meta.get('name')} ({LICENSED.get(meta.get('creatorId'), meta.get('creator'))})")
        if meta.get("description"):
            print("  " + meta["description"].replace("\n", " ")[:400])
        path, kind = download(aid, tmp)
        if not path:
            print("download failed:", kind)
            return 1
        x = decode(path)
        a = int((args.frm or 0) * SR)
        b = int(args.to * SR) if args.to else len(x)
        x = x[a:b]
        off = (args.frm or 0)
        info = analyse(x)
        print(f"  dur {info['duration']} s  peak {info['peak_db']} dB  rms {info['rms_db']} dB  clip {info['clip_ratio']}")
        tr = centroid_track(x, args.hop)
        if not args.quiet:
            for t, d, c in tr:
                bar = "#" * max(0, int((d + 60) / 2))
                print(f"  {t + off:7.2f}  {d:6.1f} dB  {c:6.0f} Hz  {bar}")
        print("  steady segments (start, end, mean dB, mean centroid Hz), longest first:")
        for s in steady_segments(tr, args.hop)[:12]:
            print(f"    {s[0] + off:7.2f} .. {s[1] + off:7.2f}  ({s[1] - s[0]:5.2f} s)  {s[2]:6.1f} dB  {s[3]:5d} Hz")
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def search_one(query, args, seen):
    q = urllib.parse.quote(query)
    tok = ""
    found = 0
    pages = 0
    while found < args.limit and pages < args.pages:
        j = http_json(TOOLBOX_SEARCH.format(q=q, n=100, tok=tok))
        pages += 1
        for item in j.get("creatorStoreAssets") or []:
            a = item.get("asset") or {}
            c = item.get("creator") or {}
            cid = c.get("userId") or c.get("groupId")
            if not args.all_creators and cid not in LICENSED:
                continue
            aid = a.get("id")
            if aid in seen:
                continue
            seen.add(aid)
            found += 1
            desc = (a.get("description") or "").replace("\n", " ")
            print(f"{aid:>16}  {a.get('durationSeconds')!s:>4}s  {LICENSED.get(cid, c.get('name'))!s:<18} "
                  f"{(a.get('name') or '')[:60]:<60} {desc[:110] if args.verbose else ''}", flush=True)
            if found >= args.limit:
                break
        nt = j.get("nextPageToken")
        if not nt:
            break
        tok = "&pageToken=" + urllib.parse.quote(nt)
        time.sleep(0.5)


def run_search(args):
    """--search "q1;q2;..." : one block per query, ids de-duplicated across the queries."""
    seen = set()
    for query in [x.strip() for x in args.search.split(";") if x.strip()]:
        print(f"== {query}", flush=True)
        try:
            search_one(query, args, seen)
        except RuntimeError as e:
            print(f"   search failed: {e}")
        time.sleep(0.3)
    return 0


def run_loop(args):
    """--loop ID --from A --to B [--min L] [--max L]: best LoopRegion candidates inside [A, B]."""
    aid = int(args.loop)
    tmp = tempfile.mkdtemp(prefix="hc_audio_")
    try:
        path, kind = download(aid, tmp)
        if not path:
            print("download failed:", kind)
            return 1
        x = decode(path)
        a = args.frm or 0.0
        b = args.to or len(x) / SR
        lo = args.min or 1.0
        hi = args.max or max(lo, (b - a) * 0.95)
        print(f"{aid}: loop candidates in [{a}, {b}] s, length {lo}..{hi} s (start, end, seam cost; lower is better)")
        for st, en, cost in loop_candidates(x, a, b, lo, hi):
            print(f"  loopStart={st:.3f}  loopEnd={en:.3f}  ({en - st:.2f} s)  cost {cost}")
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--ids")
    ap.add_argument("--envelope")
    ap.add_argument("--hop", type=float, default=0.25)
    ap.add_argument("--from", dest="frm", type=float)
    ap.add_argument("--to", type=float)
    ap.add_argument("--quiet", action="store_true", help="envelope: only the steady-segment summary")
    ap.add_argument("--search")
    ap.add_argument("--all-creators", action="store_true")
    ap.add_argument("--limit", type=int, default=25)
    ap.add_argument("--pages", type=int, default=4)
    ap.add_argument("-v", "--verbose", action="store_true")
    ap.add_argument("--loop", help="loop-point search for one id (with --from / --to / --min / --max)")
    ap.add_argument("--min", type=float)
    ap.add_argument("--max", type=float)
    args = ap.parse_args()
    if args.loop:
        return run_loop(args)
    if args.search:
        return run_search(args)
    if args.envelope:
        return run_envelope(args)
    if args.ids:
        return run_ids(args)
    return run_config(args)


if __name__ == "__main__":
    sys.exit(main())
