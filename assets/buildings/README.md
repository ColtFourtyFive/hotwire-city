# assets/buildings: the v2 building set

| Path | What | Written by |
|---|---|---|
| `glb/<key>.glb` | Production building, light GLB (geometry + UVs, one mesh per material role = one MeshPart) | `tools/blender/buildkit/produce.py` |
| `glb/<key>.json` | Per-variant export metadata (parts, roles, triangles, kit materials) | `produce.py` |
| `catalog.json` | Every variant: family, archetype, kit parameters, lot footprint, height, body box, parts, spawns | `produce.py` |
| `textures/fb_*.png` | Window-bay Textures for the procedural massing fallback | `tools/blender/buildkit/fallback_textures.py` |
| `manifest.json` | Roblox asset ids (Models + Images, owner user 11686693147), sha1, moderation state | `tools/blender/buildkit/upload.py` |

`src/shared/Config/Buildings.luau` is generated from `catalog.json` + `manifest.json` (`gen_config.py`), and
`BuildingService` places the Models on the world's parcels. Model space after import: origin = lot bottom-centre at
grade, front −Z, studs. The atlases (`windows_day`, `signs`, `brands`, `awnings`) are uploaded from
`tools/blender/buildkit/out/textures/`. Evidence and decisions: `docs/v2/early/buildings/README.md`.
