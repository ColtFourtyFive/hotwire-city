# 🚗💨 Hotwire City

**Steal cars. Outrun the cops. Stack cash.**

Hotwire City is a cartoon open-world car-heist game for Roblox. Every car you steal has to be **driven home** through a police chase. Parked cars in your garage print money every second. Rare cars, mutations, server-wide **Hot Drops**, and other players' garages full of loot keep the loop going.

- **Core loop:** hotwire a street car (or carjack traffic, or steal from the dealership) → escape the wanted level → drive it into your garage's DROP-OFF → it earns $/s → collect → upgrade → steal rarer cars.
- **Player-vs-player:** sneak into other garages and steal their cars. You then have to drive the car home while the owner chases you with a Bonk Bat, Zapper and Spike Strips. Fair-play rules apply:
  - Garages lock with a laser gate.
  - Newbies are protected.
  - Victims get a cooldown, an alarm, and a revenge bonus.
  - A dropped car is never deleted.
- **Collection:** 32 cars across 8 rarities, from Common up to Secret and Exclusive. They include meme cars: Hotdog Wagon, Rubber Ducky, Couch Cruiser and Toilet Turbo. There are 5 mutations (Gold, Diamond, Rainbow, Galaxy), and a Car Index that pays completion bonuses.
- **Retention:**
  - offline earnings
  - 7-day streak
  - daily contracts
  - playtime gifts
  - rebirths
  - codes
  - friend and group bonuses
  - referral rewards
- **Events:** Hot Drop (a mythic car spawns and the whole server races for it), Cash Rain, Rush Hour, 2x Cash, and Server Luck.
- **Mild-rated:** no blood, no death, no realistic weapons. Getting caught means **BUSTED → impound**.

See [`docs/SPEC.md`](docs/SPEC.md) for the full design and engineering contract, and [`docs/RESEARCH.md`](docs/RESEARCH.md) for the market and engine research behind the decisions.

---

## Quick start (play it in Studio)

The whole game is code; the city, garages and cars are generated at runtime. You need [Rojo](https://rojo.space) 7.6+.

```bash
# 1. Build the place file
rojo build -o HotwireCity.rbxlx

# 2. Open HotwireCity.rbxlx in Roblox Studio and press Play (or Test > Start Server + 2 Players)
```

For live-syncing while you edit: run `rojo serve`, then use the Rojo Studio plugin and click **Connect**.

In Studio every player is an admin. Open the chat or the dev console and use `/hc cash 1000000`, `/hc car hover_car Rainbow`, `/hc wanted 5`, `/hc hotdrop`, or `/hc event doublecash`.

## Publishing checklist

1. **File → Publish to Roblox** (new experience).
2. **Game Settings → Security:** enable **Studio Access to API Services** (DataStores).
3. **Game Settings → Places → Max Players: 8** (one garage per player).
4. **Monetization:** create the passes and products listed in `src/shared/Config/Monetization.luau` on the Creator Dashboard. Paste their IDs into that file and rebuild. Items with id `0` stay hidden.
5. **Group bonus (optional):** set `Economy.GROUP_ID` in `src/shared/Config/Economy.luau`.
6. **Maturity questionnaire:** answer for a *Mild* label (cartoon, non-lethal; no blood, gore, gambling, or realistic weapons).
7. **Icon and thumbnails:** use the files in `marketing/roblox_ready/`, which are AI-generated concept art. Before launch, swap at least one thumbnail for a real in-game capture so it matches the actual game.
8. **Launch timing:** GTA VI is expected on **Nov 19, 2026**. Search interest in "open-world car heist" peaks around then.

## Project layout

```
src/shared   -> ReplicatedStorage.Shared       Config/*, Util/*, Vehicle/* (CarBuilder, VehicleController), Net, Remotes, Types
src/server   -> ServerScriptService.Server      init.server.luau + Systems/* (one module per system)
src/client   -> StarterPlayerScripts.Client     init.client.luau + Controllers/* + UI/* (Kit, Theme)
tests/       -> Lune unit tests + harness (runs the real modules headlessly)
tools/       -> dump.luau + render.py (headless geometry previews)
docs/        -> SPEC.md, RESEARCH.md, previews/*.png
marketing/   -> icon + thumbnail concepts (Higgsfield)
```

Balancing lives in `src/shared/Config/*.luau`: car stats and income, rarity odds, economy prices, police tuning, events, and vehicle physics.

## Development tooling

| Command | What it does |
|---|---|
| `rojo build -o HotwireCity.rbxlx` | Builds the place |
| `selene src` | Lint (Roblox std generated from the API dump: `selene generate-roblox-std`) |
| `stylua src` | Format |
| `lune run tests/run.luau` | Runs the unit tests against the real source in a Roblox-like harness |
| `lune run tools/dump.luau car all out.json && python3 tools/render.py out.json cars.png` | Renders every car to a preview sheet |
| `lune run tools/dump.luau map out.json && python3 tools/render.py out.json map.png --views top,iso --size 1400` | Renders the city |
| `lune run tools/dump.luau plot 1 out.json && python3 tools/render.py out.json garage.png` | Renders a garage |

Toolchain versions are pinned in `rokit.toml`.
