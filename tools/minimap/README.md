# Minimap art pipeline

The radar (`MinimapController`) and the fullscreen map (`MapScreenController`) draw one stylized top-down image of
the city, cut into tiles and uploaded to Roblox, and a blip icon atlas. Both come from the real layout code, so
they always match the game.

## One command

```bash
python3 -I tools/minimap/build.py             # export -> render -> icons -> upload changed images -> Config
python3 -I tools/minimap/build.py --no-upload # render only; keeps the ids already in Config/Minimap.luau
python3 -I tools/minimap/build.py --force     # re-upload everything
python3 -I tools/minimap/build.py --ss 2      # quicker draft render (default supersampling is 3)
python3 -I tools/minimap/build.py --geometry build/minimap/geometry.json   # restyle only: reuse the last export
```

`--geometry` skips the export and re-renders an existing `geometry.json`. Use it to change the map's look without
picking up a city layout that is still being changed elsewhere.

Run it whenever the city changes, for example after editing `Config/Map`, `MapLayout` or `MapBuilder`. A full
build renders in about 30 s, plus the uploads.

## What `build.py` does

1. **Export.** `lune run tools/minimap/export.luau build/minimap/geometry.json` builds the map headlessly with
   `MapBuilder.build` and the test harness, and writes:
   - every road edge from `RoadGraph`, with width and class;
   - every map part as an XZ footprint, with name, material and color, plus each `Lot`'s zone, POI and plot;
   - building footprints from the asset slots, which are the same boxes the kit meshes are fitted into;
   - the 8 garage footprints;
   - the terrain fills;
   - the POI centers.
2. **Render.** `render_map.py` draws a GTA-V-style dark map at 3x supersampling, then downsamples it with LANCZOS:
   - deep navy land, with lots and roofs tinted per district (violet Downtown, blue Midtown, plum Market Row,
     green suburbs, teal beachfront, warm grey docks), so districts read at a glance;
   - roads over a darker asphalt casing, ranked by width and brightness: the ring highway is a glowing white
     carriageway with an amber median, avenues (line 0 and the Midtown boundary) are bright with a thin centre line,
     and plain streets are dim and narrow;
   - building footprints lit by height, with a rim light, a roof inset and a crisp south-east shadow;
   - green parks with tree canopies, and pools;
   - a soft, rounded beach with wet sand, foam and a shallow-water glow, over a gradient ocean with depth contours.

   No text is baked in: district names are UI labels (`Config/Minimap.DISTRICTS`).

   Output goes to `assets/minimap/`: `tile_<row>_<col>.png` (2x2 tiles of 1024 px, where row 0 is north), plus
   `map_full.png` and `map_preview.png`.
3. **Icons.** `icons.py` writes `assets/minimap/blips.png`, a 512 px atlas. It holds:
   - 24 GTA-style glyphs, each white with a dark outline, which the game tints with `ImageColor3`;
   - the radar vignette, glow, ring, player arrow and disc.
4. **Upload.** Every PNG whose sha256 changed is uploaded through Open Cloud (`tools/rbxcloud.py`, with the key in
   `~/.config/hotwire/roblox_api_key`, which is never printed). Images are uploaded as asset type **Image**: a
   `Decal` id does not display in an `ImageLabel`. Ids, hashes and moderation state go into
   `assets/minimap/manifest.json`.
5. **Config.** The `GENERATED` block of `src/shared/Config/Minimap.luau` is rewritten with the tile ids, the world
   square they cover (`WORLD_MIN`, `WORLD_SIZE`, which is -1024..1024 studs at 1 px per stud by default), the atlas
   id and the icon cells. The test `tests/spec/minimap.spec.luau` checks that this block matches the manifest.

## Previews

```bash
python3 -I tools/minimap/preview_ui.py docs/v2/early/minimap
```

This approximates the radar and the fullscreen map in PIL. It uses the same art, layout numbers and real
`RoadGraph` routes (`tools/minimap/sample_route.luau`) to produce:

- radar close-ups;
- the desktop HUD, and the phone HUD on 844x390 (on foot and driving) and 667x375 (the compact radar) with the
  event feed and the thumbstick zone;
- the fullscreen map on desktop and on 844x390 / 640x360 phones, with the legend open.

## Road network / GPS

`src/shared/Util/RoadGraph.luau` builds the graph from `MapLayout.roadSegments()` when the layout provides it,
and otherwise from the `Config/Map` grid.

For a bigger or different network, such as curves, highways, one-way streets, T-junctions or bridges on another
`level`, add `MapLayout.roadSegments()` that returns `{ a, b, width, class?, oneWay?, lanes?, level? }` segments. Then
re-run `build.py`. Segments are split automatically wherever they cross or touch.
