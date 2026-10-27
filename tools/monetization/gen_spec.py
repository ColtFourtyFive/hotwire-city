#!/usr/bin/env python3
"""Builds tools/monetization/spec.json from docs/v2/design/LOOP_V2.md §8 (the source of truth).

Keys, names and Robux prices are parsed from the §8.2 (game passes) and §8.3 (developer products) tables, so a
price change in LOOP_V2 only needs `python3 tools/monetization/gen_spec.py` and a sync. Store descriptions are
written here (short and literal: what you get, the limits, no hype, never "free Robux"). Every pass also gets a
`gift_<key>` developer product at the same price (§8.2 "Gifting").

Usage:
  python3 tools/monetization/gen_spec.py           # write spec.json
  python3 tools/monetization/gen_spec.py --check   # exit 1 if spec.json is out of date
"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DOC = os.path.join(ROOT, "docs", "v2", "design", "LOOP_V2.md")
OUT = os.path.join(ROOT, "tools", "monetization", "spec.json")

UNIVERSE_ID = 10773288390  # Hotwire City (root place 106226892419530)

# Display names on Roblox. ASCII "x" instead of "×" so the name we match on round-trips through the API unchanged.
NAME_OVERRIDES = {
    "tint_gold": "Gold Weapon Tint",
    "tint_platinum": "Platinum Weapon Tint",
}

# Items that exist but stay off sale (LOOP_V2 Appendix A Config/Flags launch intent).
OFF_SALE = {
    "street_pass": "Seasons ship behind Flags.SEASON_ENABLED (false at launch, LOOP_V2 §6.5 / App. A)",
}

DESCRIPTIONS = {
    # game passes (§8.2)
    "cash2x": "Doubles the cash your parked cars earn in the garage, including offline earnings. "
    "Crime, street, bounty and race payouts are not changed.",
    "vip": "VIP crown tag, 12 VIP paint colours and a VIP plate frame. Offline earnings rate 60% instead of 30%, "
    "free Mechanic, and 15 extra seconds on your garage laser lock.",
    "slots": "Adds garage slots 11 and 12.",
    "vault": "Adds a third vault bay that keeps a parked car safe from theft. A second bay is free at Rep 25. "
    "Cars you drive are not covered.",
    "autocollect": "Moves your garage cash to your bank automatically every 60 seconds.",
    "neon": "Underglow and neon accents from Rep 1. Everyone unlocks them free at Rep 10.",
    "plates": "Custom plate text from Rep 1. Everyone unlocks it free at Rep 10. Plate text is filtered.",
    "horns": "10 car horns and 2 extra radio stations. Cosmetic.",
    "emotes": "8 street emotes. Cosmetic.",
    # developer products (§8.3)
    "cash_small": "Adds 10 minutes of your car income to your bank (at least $5,000).",
    "cash_big": "Adds 1 hour of your car income to your bank (at least $50,000).",
    "cash_huge": "Adds 4 hours of your car income to your bank (at least $250,000).",
    "starter_pack": "One per account: a Rare Stallion GT in an exclusive paint (bound to you), $10,000 to your bank, "
    "3 light armor and 48 P9 rounds.",
    "lockdown": "Locks your garage for 10 minutes. Stacks. Not available while a theft from your garage is in "
    "progress.",
    "lose_cops": "Clears a 1 to 4 star wanted level. Not available at 0 or 5 stars, while carrying event loot, "
    "or with a street bounty on you.",
    "impound_release": "Releases one impounded car right away. Without it the wait is 2 minutes.",
    "rush_repair": "Finishes one repair right away. Without it the repair takes 60 seconds.",
    "server_luck": "Doubles street and dealer luck for everyone in the server for 15 minutes. Time stacks. "
    "Shown odds update while it runs.",
    "make_it_rain": "Starts a Cash Rain for everyone in the server. Your name is announced.",
    "double_it": "Pays a bonus equal to the truck bag or heist share you just delivered, up to 5 minutes of your "
    "income, to your bank. Once per day. Not during cash events.",
    "tint_gold": "Gold tint for your weapons. Cosmetic only. Also sold for in-game cash.",
    "tint_platinum": "Platinum tint for your weapons. Cosmetic only. Also sold for in-game cash.",
    "diamond_dragster": "The Diamond Dragster hero car, bound to your account. Thieves can't keep it, and it can't "
    "be traded or raced for pink slips. One per account.",
    "street_pass": "Premium track for the current Street Pass season: cosmetics and a bound car at tier 50. "
    "No cash boosts, XP boosts or tier skips.",
}

GIFT_DESCRIPTION = "Gift the {name} pass to another player in your server. They get exactly what the pass gives."


def section(text, heading):
    start = text.index(heading)
    nxt = text.find("\n### ", start + len(heading))
    return text[start : nxt if nxt != -1 else len(text)]


def table_rows(block):
    rows = []
    for line in block.splitlines():
        if line.startswith("| `"):
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            rows.append(cells)
    return rows


def ascii_name(name):
    return name.replace("×", "x").replace("’", "'").strip()


def parse():
    text = open(DOC, encoding="utf-8").read()
    passes, products = [], []
    for cells in table_rows(section(text, "### 8.2 Game passes")):
        key = re.findall(r"`([a-z0-9_]+)`", cells[0])[0]
        passes.append({"key": key, "name": ascii_name(cells[1]), "price": int(cells[2].replace(",", ""))})
    for cells in table_rows(section(text, "### 8.3 Developer products")):
        keys = re.findall(r"`([a-z0-9_]+)`", cells[0])
        prices = [int(p.strip().replace(",", "")) for p in cells[2].split("/")]
        if len(keys) != len(prices):
            raise SystemExit(f"LOOP_V2 §8.3 row {cells[0]}: {len(keys)} keys but {len(prices)} prices")
        for key, price in zip(keys, prices):
            products.append({"key": key, "name": ascii_name(cells[1]), "price": price})
    return passes, products


def build():
    passes, products = parse()
    items = []

    def add(kind, key, name, price, description, gift_of=None):
        if key not in OFF_SALE and not description:
            raise SystemExit(f"no description for {key}")
        item = {
            "key": key,
            "kind": kind,
            "name": NAME_OVERRIDES.get(key, name),
            "description": description,
            "price": price,
            "onSale": key not in OFF_SALE,
            "icon": f"assets/monetization/{key}.png",
        }
        if key in OFF_SALE:
            item["offSaleReason"] = OFF_SALE[key]
        if gift_of:
            item["giftOf"] = gift_of
        items.append(item)

    for p in passes:
        add("pass", p["key"], p["name"], p["price"], DESCRIPTIONS.get(p["key"]))
    for p in products:
        add("product", p["key"], p["name"], p["price"], DESCRIPTIONS.get(p["key"]))
    for p in passes:
        name = NAME_OVERRIDES.get(p["key"], p["name"])
        add("product", "gift_" + p["key"], "Gift: " + name, p["price"], GIFT_DESCRIPTION.format(name=name), p["key"])

    keys = [i["key"] for i in items]
    if len(keys) != len(set(keys)):
        raise SystemExit("duplicate keys in spec")
    names = [(i["kind"], i["name"].lower()) for i in items]
    if len(names) != len(set(names)):
        raise SystemExit("duplicate names in spec (sync matches by name)")
    for i in items:
        if len(i["name"]) > 50:
            raise SystemExit(f"name too long: {i['name']}")
        if "free robux" in (i["name"] + " " + i["description"]).lower():
            raise SystemExit("never claim free Robux (LOOP_V2 §8.5)")
    extra = set(DESCRIPTIONS) - set(keys)
    if extra:
        raise SystemExit(f"descriptions for keys not in LOOP_V2 §8: {sorted(extra)}")

    return {
        "_generated": "by tools/monetization/gen_spec.py from docs/v2/design/LOOP_V2.md §8; do not edit by hand",
        "universeId": UNIVERSE_ID,
        "items": items,
    }


def main():
    spec = build()
    data = json.dumps(spec, indent=2, ensure_ascii=False) + "\n"
    if "--check" in sys.argv:
        current = open(OUT, encoding="utf-8").read() if os.path.exists(OUT) else ""
        if current != data:
            print("spec.json is out of date: run python3 tools/monetization/gen_spec.py")
            sys.exit(1)
        print("spec.json is up to date")
        return
    open(OUT, "w", encoding="utf-8").write(data)
    n_pass = sum(1 for i in spec["items"] if i["kind"] == "pass")
    print(f"wrote {os.path.relpath(OUT, ROOT)}: {n_pass} passes, {len(spec['items']) - n_pass} products")


if __name__ == "__main__":
    main()
