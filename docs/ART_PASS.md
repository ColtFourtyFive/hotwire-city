# Art pass — making Hotwire City beautiful

The v1 systems ship with procedural geometry so the game always works. The art pass layers real art on top:

## Asset sources (in priority order)

1. **Hero meshes we own.** These are Higgsfield concept renders turned into Meshy image→3D GLBs and uploaded through Open Cloud. They live in `assets/hero/manifest.json` and are loaded with `InsertService:LoadAsset`, which always works for the owner's experience. Each one is a textured MeshPart (about 9K triangles, 2K texture).
2. **Curated free Creator Store assets.** These are listed in `assets/curation/*.json` and loaded at runtime with `AssetService:LoadAssetAsync`. This needs Game Settings → Security → **Allow Loading Third Party Assets**. Loaded models are sandboxed, and AssetLibrary also strips every script.
3. **Images we own.** These are Higgsfield-generated billboard ads, store signs, posters and decals, uploaded as Decal assets. At runtime they are resolved to image content with `InsertService:LoadAsset(decalId)`, which returns a Decal whose Texture holds the image URL.
4. **Avatar catalog items** (shirts, pants, accessories) are used for NPC `HumanoidDescription`s through `Players:CreateHumanoidModelFromDescription`.
5. **Procedural fallback.** If any of the above fails, the current geometry stays in place.

## Runtime architecture

- **`Server/Systems/AssetLibrary`** loads `Config/Assets` and normalizes each asset:
  - The root sits at the bottom center.
  - The front faces -Z.
  - The asset is scaled to fit.
  - Everything is anchored, with no scripts.
  - The result is published to `ReplicatedStorage.AssetLibrary.<Category>.<key>`.
  - API: `get`, `clone(cat, key, groundCFrame, parent)`, `Ready` and `AllReady` signals, `waitAll(timeout)`.
- **CarBuilder:** if `ReplicatedStorage.AssetLibrary.Hero[carId]` exists (or `Hero.police_unit` for police), it:
  - clones the shell, fits it to the car's Length, and aligns its bottom to the ground plane;
  - welds the shell to the Chassis and hides the procedural body and wheel visuals;
  - sets the model attribute `HeroMesh=true`.

  Mutations on hero shells clear `TextureID`/SurfaceAppearance and apply the mutation color and material. Rainbow cycles the color client-side.
- **MapBuilder:** procedural trees, props and building lots are tagged `AssetSlot`, with attributes `Category` (`Props`/`Buildings`), `Role`, and `Fit` size. **`Server/Systems/MapDresser`** waits for AssetLibrary, then replaces each slot with a clone of the role's asset. Variants are chosen deterministically by position. The placeholder is destroyed only after the clone is placed.
- **NPCs.** A new **`Server/Systems/NPCService`** builds R15 humanoid templates from `Config/Assets.Outfits`, with traffic drivers, police officers, pedestrians and shopkeepers. Those templates are used by:
  - TrafficService drivers;
  - PoliceService officers, who bail out at a bust;
  - ambient pedestrians walking the sidewalk graph (about 12, client-friendly);
  - shopkeepers at the Gear Shop and Dealership.

## Visual targets

- Distinct districts with their own palettes: neon **Downtown**, pastel **Beachfront**, **Docks/Industrial** with containers and cranes, leafy **Suburbs**, and the **Stunt Park**.
- Terrain: grass in the parks, sand at the beach, water with waves, and `Clouds`.
- Lighting: a golden-hour default, a neon night, `Atmosphere` haze, bloom, and a sun-rays budget.
- Billboards and signs carry parody ads, never real brands.
