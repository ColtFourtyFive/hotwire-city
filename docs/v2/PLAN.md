# Hotwire City v2: master build plan (lead)

**Authority.**
1. `docs/v2/research/00_LEAD_DIRECTION.md` and `original_brief.md` are binding.
2. Specs: world `docs/v2/world/WORLD_SPEC.md`, loop `docs/v2/design/LOOP_V2.md`, combat `research/gta_combat.md`, UI `research/gta_ui_language.md`, engine `research/roblox_tech.md`, realism `research/gta_realism_gap.md`, lighting `research/lighting_lab.md`, sky `research/sky_orientation.md`.
3. Asset sources: `research/cc0_assets.md`, `research/SOURCES_UNLOCKED.md`, `docs/v2/sourcing/*` and the Studio scout evidence in `docs/v2/evidence/`.

**North star.** Grounded GTA V realism on Roblox: a real-scale island city, realistic cars and NPCs, gunplay with no gore (rated Moderate, 13+), and GTA presentation. The user's loop sits inside it: steal → escape → deliver → garage income; the garage is a bank and the street is a casino; per-car progression; crimes, heists and crews. Every visual milestone is verified in the real engine.

## Architecture decisions (locked)

1. **Streaming.** `StreamingEnabled = true`. Vehicles and player plots use explicit `ModelStreamingMode`; Persistent only where gameplay truly needs it. Every client system must tolerate missing instances: no start-up `GetDescendants` scans of the world, and every `WaitForChild` has a timeout. The minimap reads replicated data and attributes, not Workspace scans.
2. **World build.** The world is generated server-side at boot from `Config/WorldLayout` data, by MapBuilder v2, in chunks with the spawn area first.
   - Terrain is runtime-generated in phase 1.
   - Phase 2 bakes it at deploy, with a Luau Execution task and `SavePlaceAsync` (needs Team Create off).
   - Ambient traffic is **kinematic**, not server-physics.
3. **Materials, sky and lighting live in the place file.**
   - MaterialVariants (PBR, OpenGL normals, Image asset IDs) go in `MaterialService` through `default.project.json`.
   - The HDRI Sky uses Image IDs and the verified face orientation.
   - Lighting uses `LightingStyle = Realistic` and `PrioritizeLightingQuality = true` in the file.
   - LightingService v2 only animates the time of day: Atmosphere Density ≤ 0.30, neutral haze, lit windows at night, and a 24-minute day.
4. **Meshes come from uploaded Models we own, loaded at runtime** through AssetLibrary: buildings (Blender buildkit) and cars (car pipeline from CC-BY sources).
   - Third-party Creator Store picks load by their original ID with scripts stripped.
   - Never rely on SurfaceAppearance in Rojo-built files; the publish API drops it.
5. **Cars.** v1's arcade raycast physics chassis is kept as the invisible rig. The cosmetic body is welded on with separate wheel meshes that spin and steer.
   - Paint uses the untextured body MeshPart Color, or SurfaceAppearance TintMask on uploaded models.
   - Orientation is normalised by seat direction.
   - Real brand badges are stripped, and parody brand names are shown.
6. **Security.** Server-authoritative everything, as in v1. Shots are validated per `gta_combat` §10. No new money source without an anti-exploit gate.
7. **Content.** No alcohol locations, no gore, no Robux-wager pink slips, and PolicyService gating for trading.
8. **Verification gates for every wave.**
   - `selene src` 0/0, `stylua --check`, Lune tests, `rojo build`.
   - `python3 tools/cloud_boot.py`: a real-engine headless boot with 0 errors.
   - Studio operator screenshot jobs, compared against the GTA references.

## Waves

| Wave | Packages (disjoint ownership; worktrees + integrator merge) | Status |
|---|---|---|
| 0 | Research, world plan, loop design, Blender kits, car pipeline, sourcing, minimap and GPS, VFX textures, Studio scouting | mostly done |
| **B** | **B1 Combat C0+C1** (gta_combat §13) · **B2 UI v2** (gta_ui_language §5, §9), then the integrator, a real-engine boot, and Studio HUD/combat screenshots | starting |
| A | **A1 World runtime** (MapBuilder v2 from WorldLayout, roads/markings/freeway/terrain/water, MapLayout shim, streaming-safe) · **A2 Look** (MaterialVariants, HDRI sky, LightingService v2, project settings, lit windows) · **A3 Building production** (buildkit variants → upload → Config/Assets v2 → parcel placement) · **A4 Vehicles v2** (car pipeline roster → upload → CarBuilder v2 rig, paint, wheels, lights, Creator Store mapping loader) | after the world, buildkit and car pipeline finish |
| C | **C1 Loop v2** (LOOP_V2 engineering packages: data migration, per-car progression, street casino, robberies, armored truck, heists, crews) · **C2 Life** (kinematic traffic on the RoadGraph, pedestrians with realistic outfits and reactions, police v2 vehicles: roadblocks, helicopter, SWAT) · **C3 Audio** (engines, guns, sirens, city ambience, radio) | after A |
| D | Integration, performance (instance and streaming audit on phones), polish, onboarding, marketing captures from the real game, monetization (Open Cloud passes and products), publish | last |

## Lead decisions on open UI questions

- Cash is always shown.
- Rebirth becomes **Prestige**.
- The HOME teleport becomes a phone **"Call a cab"** to your garage: it costs a small fee and is blocked while wanted.
- The brand accent is Ignition Orange `#FF8A3D`. GTA VI extras (heat badges, 3D minimap) come later.

## Lead decisions from the verified GTA research (2026-10-27)

- **No Pricedown in any form.** That includes pre-rendered PNGs, which are too close to GTA's trade dress. Big messages use Kanit Black (Roblox-owned) per `gta_ui_language` §4.
- **No GTA names**, for cars or anything else. Rename "Phoenix", "Cheetah" and "Burrito" and any other GTA-owned names before they reach the game. Use our own parody brands.
- **Third-party models load at runtime only through `AssetService:LoadAssetAsync`.** It needs "Allow Loading Third Party Assets", which is ON, and works for free assets only. `InsertService:LoadAsset` is used only for our own uploads.
- **Excluded assets:**
  - "Synty city" re-uploads on the Creator Store (licence risk);
  - the backdoor re-uploads flagged by scout job 0003 (`75934961104200`, `76401662964478`);
  - game rips (CoD, L4D, Delta Force, Hum3D);
  - the 55 Robux catalog vest.
- **NPC bodies:** only the realistic base bodies (bundles 988–995). No anime-style bodies (979–987). Replace hair 62234425, whose texture returns 404.
- **Deprecated APIs** are replaced by their `…Async` versions: `CreateHumanoidModelFromDescriptionAsync`, `ApplyDescriptionAsync`, `PlayEmoteAsync`.
- **Atmosphere.** Haze and Offset still need separating in lighting-lab round 2. Run it once the HDRI sky and the PBR MaterialVariants exist. Until then, keep Density ≤ 0.30 and Haze ≤ 1.2.
- **Launch audience.** New experiences are visible only to age-checked 16+ players by default. Reaching ages 13–15 needs an ID-verified creator with 2FA, a fee or Plus, and 250 engaged plays within 60 days. This is a user action before launch.
