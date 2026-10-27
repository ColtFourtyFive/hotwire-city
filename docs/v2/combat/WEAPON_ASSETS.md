# Weapon assets: current state and what remains

This covers combat v2, packages C0 and C1. The design is in `docs/v2/research/gta_combat.md`: §12 covers assets and §13 the plan.

## What ships now

- **Guns, melee and gadgets.** These are part-built placeholders from `src/shared/Combat/WeaponModels.luau`.
  - Proportions follow the real-world basis, with GTA's in-hand upscale of about 1.2×.
  - Each one is assembled from dark Metal, SmoothPlastic, Wood, Fabric and Glass parts.
  - There is no Neon anywhere and no cartoon colours.
  - Every metal or polymer part carries a `Tint` attribute, so weapon tints recolour it.
  - Each model has an invisible `Handle`, plus a `Muzzle` attachment where tracers and flashes start.
- **Wheel, HUD and shop icons.** These do not use PNG silhouettes. `src/client/UI/WeaponPreview.luau` renders the same builders in ViewportFrames, either as flat white silhouettes or as a lit turntable in the shop. When the mesh hook below gets real ids, these previews still show the part-built model until `WeaponPreview.build` is pointed at the mesh as well. That swap is noted in the file.
- **Animations.** `src/shared/Config/Animations.luau` uses Roblox-owned placeholders: blaster and autoblaster idle, shoot and reload, plus Weapons Kit rifle aim. The custom keys have empty ids and are skipped at runtime. Those keys are `melee_swing`, `hands_up`, `kneel_cuffed`, `cower`, `flinch` and `surrender`.

## The mesh hook (`Config/Weapons`, `asset.mesh`)

```lua
mesh = { source = "owned" | "store", id = 0, length = <studs>, rotation = CFrame, offset = Vector3 }
```

When `id > 0`, `WeaponService` does the following at boot:
1. Loads the model (`InsertService:LoadAsset` for owned assets, `AssetService:LoadAssetAsync` for store assets).
2. Strips scripts, sounds, prompts and humanoids.
3. Scales the longest axis to `length`.
4. Pivots the model to `Handle * offset * rotation`. Its barrel must face −Z and its top +Y.
5. Welds it to the Handle and hides the placeholder parts.

If the asset fails to load, the placeholder stays. The grip, muzzle point and all balance values are unaffected.

## Pipeline for the final meshes (not done in this package)

Only final assets are uploaded. Nothing was uploaded for C0/C1, because orientation, offsets and logo removal need a visual check in Blender and Studio.

1. **Pick a source.**
   - The preferred source is CC-BY 4.0 Objaverse GLBs listed in `docs/v2/research/cc0_assets.md`, under `model_gun_objaverse`:
     - USP → Kessler P9;
     - Mini Uzi → Micro SMG;
     - MP5 → Tactical SMG;
     - Remington 870 → Pump;
     - AK-47 → Comrade;
     - AR-15 → Carbine;
     - bolt sniper → Marksman;
     - bat pack → Slugger Bat.
   - The Creator Store set from `gta_combat.md` §12.1 (Regole_CKC) has provenance risk, so treat it as placeholder only.
2. **Clean up in Blender** (task #8 pipeline):
   - remove manufacturer logos and markings, because UI and meshes must be parody only;
   - decimate to 15k triangles or fewer;
   - orient the barrel to −Z and the top to +Y;
   - put the origin at the grip;
   - apply scale, then export GLB.
3. **Upload** with `python3 tools/upload_hero.py <key> <file.glb> "<Name>" <yawDeg> <lengthStuds>`. This uses the owner account and records the result in a manifest.
4. **Set** `asset.mesh` on the weapon: `source = "owned"`, `id`, `length`, `rotation` (identity if step 2 was done) and `offset` (the grip-to-centre offset).
5. **Verify in Studio.**
   - Equip the weapon in third person, aim, and check the muzzle flash sits at the barrel tip.
   - If it does not, adjust `asset.muzzle`.
6. **Credit the authors.** CC-BY needs attribution: add the author, title and link of every mesh used to `docs/v2/research/SOURCES_UNLOCKED.md`. Also add them to an in-game credits screen; none exists yet, so it is a Settings item to build.

## Still open (art and audio)

- **Gun meshes.** These are the uploads described above, plus the vest accessory from §12.2. Make our own plate-carrier mesh instead of the 55 R$ UGC item.
- **Custom animation set.** About 22 clips, authored in Studio under the experience owner (§12.3):
  - upper-body aim, fire and reload per class;
  - pump rack;
  - bat swings and punches;
  - equip and holster;
  - hands-up, kneel-cuffed, cower and flinch.
- **Weapon silhouette sprites** (optional now): 96×40 white line art. The ViewportFrame silhouettes already cover the wheel and HUD.
- **Bullet-hole decals.** None exist. Impacts are dust and spark puffs only, with no blood ever.
- **Heartbeat loop** for the low-health effect. No asset has been picked.
- **Audio audition.** Every gun, tail, whiz and WASTED/BUSTED id in `Config/Sounds` must be auditioned in Studio. The research verdicts are not ear-checked.
