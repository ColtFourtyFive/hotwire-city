#!/usr/bin/env python3
"""Idempotent Roblox Open Cloud sync for Hotwire City game passes and developer products.

Reads tools/monetization/spec.json (built from LOOP_V2 §8 by gen_spec.py), lists what already exists in the universe,
matches each spec item (by the id recorded in state.json, else by exact name), then creates what is missing and
updates price / description / sale status / icon of what exists. It never creates a second item with the same name.

  python3 tools/monetization/sync.py                 # dry run (default): print the plan, change nothing
  python3 tools/monetization/sync.py --apply         # execute, then write MonetizationIds.luau + state.json
  options: --only key,key   --skip-icons   --force-icons

--apply writes:
  src/shared/Config/MonetizationIds.luau   { passes = { key = id }, products = { key = id } } (generated)
  tools/monetization/state.json            ids, icon hashes and the verified live price / sale status

Open Cloud endpoints (x-api-key; create.roblox.com/docs/cloud/reference/features/game-passes and
.../developer-products, checked 2026-10-27; all Beta):
  GET   /game-passes/v1/universes/{u}/game-passes/creator?pageSize=&pageToken=      game-pass:read
  POST  /game-passes/v1/universes/{u}/game-passes            multipart/form-data   game-pass:write (5/s)
  PATCH /game-passes/v1/universes/{u}/game-passes/{id}       multipart, 204        game-pass:write
  GET   /developer-products/v2/universes/{u}/developer-products/creator             developer-product:read
  POST  /developer-products/v2/universes/{u}/developer-products       multipart     developer-product:write (3/s)
  PATCH /developer-products/v2/universes/{u}/developer-products/{id}  multipart, 204
  multipart fields: name, description, price, isForSale, imageFile (PNG), isRegionalPricingEnabled (left unset)

The API key comes from tools/rbxcloud.py key() ($ROBLOX_API_KEY or ~/.config/hotwire/roblox_api_key). It is never
printed or logged.
"""
import argparse
import hashlib
import json
import os
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import rbxcloud  # noqa: E402

SPEC = os.path.join(ROOT, "tools", "monetization", "spec.json")
STATE = os.path.join(ROOT, "tools", "monetization", "state.json")
IDS_LUAU = os.path.join(ROOT, "src", "shared", "Config", "MonetizationIds.luau")

EXPECTED_UNIVERSE = 10773288390
FORBIDDEN_UNIVERSES = {10767670318}

API = "https://apis.roblox.com"
KINDS = {
    "pass": {
        "list": "/game-passes/v1/universes/{u}/game-passes/creator",
        "create": "/game-passes/v1/universes/{u}/game-passes",
        "update": "/game-passes/v1/universes/{u}/game-passes/{id}",
        "items": "gamePasses",
        "id": "gamePassId",
        "icon": "iconAssetId",
        "gap": 0.25,  # 5 writes/s
    },
    "product": {
        "list": "/developer-products/v2/universes/{u}/developer-products/creator",
        "create": "/developer-products/v2/universes/{u}/developer-products",
        "update": "/developer-products/v2/universes/{u}/developer-products/{id}",
        "items": "developerProducts",
        "id": "productId",
        "icon": "iconImageAssetId",
        "gap": 0.4,  # 3 writes/s
    },
}


# ---------------------------------------------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------------------------------------------


def call(method, path, fields=None, files=None, attempts=5):
    url = API + path
    data, headers = None, {}
    if fields is not None or files:
        data, ctype = rbxcloud.multipart(fields or {}, files or {})
        headers["Content-Type"] = ctype
    for attempt in range(attempts):
        status, body, hdrs = rbxcloud.req(method, url, data=data, headers=headers)
        if status == 429 or status >= 500:
            wait = float(hdrs.get("Retry-After") or hdrs.get("retry-after") or 0) or (1.5 * (attempt + 1))
            time.sleep(min(wait, 20))
            continue
        return status, body
    return status, body


def list_all(kind, universe):
    k = KINDS[kind]
    out, token = [], None
    while True:
        path = k["list"].format(u=universe) + "?pageSize=100" + (f"&pageToken={token}" if token else "")
        status, body = call("GET", path)
        if status != 200:
            raise SystemExit(f"list {kind}s failed: HTTP {status} {body[:400]}")
        doc = json.loads(body)
        out.extend(doc.get(k["items"]) or [])
        token = doc.get("nextPageToken")
        if not token:
            return out


def price_of(obj):
    """Robux price from a GamePassConfigV2 / DeveloperProductConfigV2 (priceInformation is untyped in the docs)."""
    info = obj.get("priceInformation")
    if isinstance(info, dict):
        for key in ("defaultPriceInRobux", "priceInRobux", "price"):
            if isinstance(info.get(key), (int, float)):
                return int(info[key])
    if isinstance(obj.get("price"), (int, float)):
        return int(obj["price"])
    return None


def norm(name):
    return " ".join((name or "").split()).lower()


def sha256(path):
    return hashlib.sha256(open(path, "rb").read()).hexdigest()


# ---------------------------------------------------------------------------------------------------------------
# Plan
# ---------------------------------------------------------------------------------------------------------------


def load_json(path, default):
    if os.path.exists(path):
        return json.load(open(path, encoding="utf-8"))
    return default


def plan_items(spec, state, live, args):
    plan = []
    st_items = state.get("items", {})
    for item in spec["items"]:
        if args.only and item["key"] not in args.only:
            continue
        kind = item["kind"]
        k = KINDS[kind]
        by_id = {str(o[k["id"]]): o for o in live[kind]}
        existing = None
        rec = st_items.get(item["key"])
        if rec and rec.get("kind") == kind and str(rec.get("id")) in by_id:
            existing = by_id[str(rec["id"])]
        else:
            matches = [o for o in live[kind] if norm(o.get("name")) == norm(item["name"])]
            if len(matches) > 1:
                raise SystemExit(f"{item['key']}: {len(matches)} existing {kind}s named {item['name']!r}; fix by hand")
            existing = matches[0] if matches else None
        icon_path = os.path.join(ROOT, item["icon"])
        icon_sha = sha256(icon_path) if os.path.exists(icon_path) else None
        if not icon_sha and not args.skip_icons:
            raise SystemExit(f"missing icon {item['icon']}: run python3 tools/monetization/icons.py")

        step = {"item": item, "kind": kind, "existing": existing, "changes": {}, "upload": False, "iconSha": icon_sha}
        if existing is None:
            step["action"] = "create"
            step["changes"] = {
                "name": item["name"],
                "description": item["description"],
                "price": item["price"],
                "isForSale": item["onSale"],
            }
            step["upload"] = not args.skip_icons
        else:
            ch = {}
            if existing.get("name") != item["name"]:
                ch["name"] = item["name"]
            if (existing.get("description") or "") != item["description"]:
                ch["description"] = item["description"]
            if price_of(existing) != item["price"]:
                ch["price"] = item["price"]
            if bool(existing.get("isForSale")) != item["onSale"]:
                ch["isForSale"] = item["onSale"]
            step["changes"] = ch
            if not args.skip_icons:
                recorded = (rec or {}).get("iconSha256")
                has_icon = bool(existing.get(k["icon"]))
                step["upload"] = args.force_icons or not has_icon or recorded != icon_sha
            step["action"] = "update" if (ch or step["upload"]) else "ok"
        plan.append(step)
    return plan


def describe(step):
    item, ex = step["item"], step["existing"]
    if step["action"] == "create":
        sale = "on sale" if item["onSale"] else "OFF sale"
        return f"CREATE  {item['price']} R$, {sale}" + (", icon" if step["upload"] else "")
    if step["action"] == "ok":
        return "ok"
    parts = []
    for f, v in step["changes"].items():
        if f == "price":
            parts.append(f"price {price_of(ex)} -> {v}")
        elif f == "isForSale":
            parts.append(f"isForSale {ex.get('isForSale')} -> {v}")
        else:
            parts.append(f"{f}")
    if step["upload"]:
        parts.append("icon")
    return "UPDATE  " + ", ".join(parts)


def print_plan(plan):
    print(f"{'key':22} {'kind':8} {'id':>12}  plan")
    for step in plan:
        k = KINDS[step["kind"]]
        ex_id = step["existing"][k["id"]] if step["existing"] else "-"
        print(f"{step['item']['key']:22} {step['kind']:8} {str(ex_id):>12}  {describe(step)}")
    counts = {}
    for step in plan:
        counts[step["action"]] = counts.get(step["action"], 0) + 1
    print("summary:", ", ".join(f"{n} {a}" for a, n in sorted(counts.items())))


# ---------------------------------------------------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------------------------------------------------


def form_fields(changes):
    out = {}
    for f, v in changes.items():
        out[f] = ("true" if v else "false") if isinstance(v, bool) else str(v)
    return out


def apply_plan(plan, universe):
    failures = []
    for step in plan:
        if step["action"] == "ok":
            continue
        kind, item = step["kind"], step["item"]
        k = KINDS[kind]
        files = None
        if step["upload"]:
            path = os.path.join(ROOT, item["icon"])
            files = {"imageFile": (os.path.basename(path), open(path, "rb").read(), "image/png")}
        if step["action"] == "create":
            status, body = call("POST", k["create"].format(u=universe), form_fields(step["changes"]), files)
            step["ok"] = status == 200
            if step["ok"]:
                obj = json.loads(body)
                step["createdId"] = obj.get(k["id"])
                print(f"  created {kind} {item['key']} -> {step['createdId']}")
            else:
                failures.append((item["key"], status, body[:300]))
                print(f"  FAILED create {item['key']}: HTTP {status} {body[:300]}")
        else:
            oid = step["existing"][k["id"]]
            status, body = call("PATCH", k["update"].format(u=universe, id=oid), form_fields(step["changes"]), files)
            step["ok"] = status in (200, 204)
            if step["ok"]:
                print(f"  updated {kind} {item['key']} ({oid}): {describe(step)[8:]}")
            else:
                failures.append((item["key"], status, body[:300]))
                print(f"  FAILED update {item['key']} ({oid}): HTTP {status} {body[:300]}")
        time.sleep(k["gap"])
    return failures


def write_ids(spec, ids):
    lines = [
        "--!strict",
        "-- GENERATED by tools/monetization/sync.py from tools/monetization/spec.json (LOOP_V2 §8). Do not edit by hand:",
        "-- run `python3 tools/monetization/sync.py --apply` instead.",
        f"-- Roblox ids for universe {spec['universeId']}. A missing key or id 0 means not created: the item stays hidden.",
        "",
        "export type Ids = { passes: { [string]: number }, products: { [string]: number } }",
        "",
        "local MonetizationIds: Ids = {",
    ]
    for kind, table in (("pass", "passes"), ("product", "products")):
        lines.append(f"\t{table} = {{")
        for item in spec["items"]:
            if item["kind"] == kind:
                lines.append(f"\t\t{item['key']} = {int(ids.get(item['key']) or 0)},")
        lines.append("\t},")
    lines += ["}", "", "return MonetizationIds", ""]
    open(IDS_LUAU, "w", encoding="utf-8").write("\n".join(lines))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--apply", action="store_true", help="execute the plan (default is a dry run)")
    ap.add_argument("--dry-run", action="store_true", help="print the plan only (the default)")
    ap.add_argument("--only", type=lambda s: set(s.split(",")), help="comma-separated spec keys")
    ap.add_argument("--skip-icons", action="store_true", help="never upload icons")
    ap.add_argument("--force-icons", action="store_true", help="re-upload every icon")
    args = ap.parse_args()
    if args.apply and args.dry_run:
        raise SystemExit("--apply and --dry-run are exclusive")

    spec = load_json(SPEC, None)
    if not spec:
        raise SystemExit("missing spec.json: run python3 tools/monetization/gen_spec.py")
    universe = int(spec["universeId"])
    if universe in FORBIDDEN_UNIVERSES or universe != EXPECTED_UNIVERSE:
        raise SystemExit(f"refusing to touch universe {universe}")
    state = load_json(STATE, {"universeId": universe, "items": {}})
    if int(state.get("universeId", universe)) != universe:
        raise SystemExit("state.json belongs to another universe")

    live = {kind: list_all(kind, universe) for kind in KINDS}
    print(f"universe {universe}: {len(live['pass'])} game passes, {len(live['product'])} developer products exist")
    plan = plan_items(spec, state, live, args)
    print_plan(plan)
    if not args.apply:
        print("dry run: nothing changed (use --apply)")
        return

    failures = apply_plan(plan, universe)

    # verify against a fresh listing and record what is live
    live = {kind: list_all(kind, universe) for kind in KINDS}
    st_items = state.setdefault("items", {})
    ids = {}
    created = {s["item"]["key"]: s.get("createdId") for s in plan if s.get("createdId")}
    mismatches = []
    print(f"\n{'key':22} {'kind':8} {'id':>12} {'price':>6} {'sale':>5}  verified")
    for item in spec["items"]:
        kind = item["kind"]
        k = KINDS[kind]
        rec = st_items.get(item["key"], {})
        want_id = created.get(item["key"]) or rec.get("id")
        obj = next((o for o in live[kind] if want_id and str(o[k["id"]]) == str(want_id)), None)
        if obj is None:
            obj = next((o for o in live[kind] if norm(o.get("name")) == norm(item["name"])), None)
        if obj is None:
            ids[item["key"]] = 0
            print(f"{item['key']:22} {kind:8} {'-':>12}  missing")
            continue
        oid = obj[k["id"]]
        ids[item["key"]] = oid
        step = next((s for s in plan if s["item"]["key"] == item["key"]), None)
        icon_sha = rec.get("iconSha256")
        if step and step["upload"] and step.get("ok"):
            icon_sha = step["iconSha"]
        price, sale = price_of(obj), bool(obj.get("isForSale"))
        good = price == item["price"] and sale == item["onSale"] and obj.get("name") == item["name"]
        if not good:
            mismatches.append(item["key"])
        st_items[item["key"]] = {
            "kind": kind,
            "id": oid,
            "name": obj.get("name"),
            "price": price,
            "onSale": sale,
            "iconAssetId": obj.get(k["icon"]),
            "iconSha256": icon_sha,
        }
        print(f"{item['key']:22} {kind:8} {oid:>12} {str(price):>6} {str(sale):>5}  {'ok' if good else 'MISMATCH'}")

    state["universeId"] = universe
    state["items"] = {key: st_items[key] for key in sorted(st_items)}
    with open(STATE, "w", encoding="utf-8") as fh:
        json.dump(state, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    write_ids(spec, ids)
    print(f"\nwrote {os.path.relpath(IDS_LUAU, ROOT)} and {os.path.relpath(STATE, ROOT)}")
    if failures or mismatches:
        print(f"{len(failures)} failed calls, {len(mismatches)} mismatches: {[f[0] for f in failures] + mismatches}")
        sys.exit(1)


if __name__ == "__main__":
    main()
