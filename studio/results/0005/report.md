# Job 0005 report: Sky face orientation

- **Studio:** 0.744.0.7441077, Hotwire City place, Edit mode. The place was not saved.
- **Camera:** `screen_capture` at (0, 60, 0) with the look-at targets from the job.

## Problem: the image IDs in the job are Decal IDs

- All six IDs in the job (e.g. `110545387398867`) are **Decal** assets, not Image assets.
- Used as `Sky.Skybox*`, they fail with `AssetDelivery403IncorrectAssetType`, and `ContentProvider:PreloadAsync` reports `Failure`. The sky stays on the default texture; see `attempt1_decal_ids_look_negZ.png`.
- I resolved each Decal to its underlying Image with `game:GetObjects` and used those Image IDs instead. **Use these IDs from now on:**

| Face | Decal ID (from the job) | Image ID (use this) |
|---|---|---|
| SkyboxFt | 110545387398867 | **125021145685093** |
| SkyboxRt | 100921678463069 | **79998295024603** |
| SkyboxBk | 130148372369598 | **133950846661312** |
| SkyboxLf | 122707222733111 | **128567569050109** |
| SkyboxUp | 80504084352862 | **98950637562746** |
| SkyboxDn | 78838948585368 | **83560359428904** |

- **Pipeline note:** when you upload a skybox through Open Cloud, use the **Image** asset ID, not the Decal ID.

## Results

How the camera is oriented in each shot:
- **Horizontal shots:** screen-right is the camera's RightVector. For example, looking toward −Z, screen-right is +X.
- **`look_up`:** the target is (0, 160, −1), so screen-top points **+Z** and screen-right **+X**. This is the same view as standing facing −Z and tipping your head back.
- **`look_down`:** the target is (0, −40, −1), so screen-top points **−Z** and screen-right **+X**.

| Shot | Face visible | Text | Rotation on screen | Image top points to |
|---|---|---|---|---|
| `look_negZ` (−Z) | **FT** (label says "−Z") | normal, not mirrored | 0° | +Y |
| `look_posZ` (+Z) | **BK** ("+Z") | normal | 0° | +Y |
| `look_posX` (+X) | **LF** (label says "−X") | normal | 0° | +Y |
| `look_negX` (−X) | **RT** (label says "+X") | normal | 0° | +Y |
| `look_up` (+Y) | **UP** | normal, not mirrored | **90° clockwise** | **+X** |
| `look_down` (−Y) | **DN** | normal, not mirrored | **90° counter-clockwise** | **−X** |

## Conclusions

1. **Horizontal faces:**
   - Ft is at −Z and Bk at +Z. **Lf is at +X and Rt at −X.**
   - This is the opposite of the "−X/+X" labels baked into the test images, and of the edge hints inside them. FT's image shows "LF" at its left edge, but the face actually next to its right edge is LF.
   - None of the four is mirrored or rotated.
2. **Up face:**
   - It is not mirrored, but its image top points **+X**.
   - In the standard "facing Ft (−Z), look up" view, it looks rotated 90° clockwise.
   - So an HDRI-derived +Y face, authored with its top toward −Z (the Ft side), needs **rotating 90° clockwise before upload**.
3. **Down face:**
   - It is not mirrored, and its image top points **−X**.
   - Viewed facing Ft and looking down (screen-top −Z), it looks rotated 90° counter-clockwise.
   - A −Y face authored with its top toward −Z needs **rotating 90° counter-clockwise before upload**.
4. **Cubemap mapping:** for a standard cubemap (+X, −X, +Y, −Y, +Z, −Z), the Roblox mapping is:
   - **Ft = −Z**
   - **Bk = +Z**
   - **Lf = +X**
   - **Rt = −X**
   - **Up = +Y**, rotated as in point 2
   - **Dn = −Y**, rotated as in point 3
   - Check the rotation sense against the per-face orientation of your HDRI tool's export convention, and verify with one more test shot after conversion.

## Notes

- The Studio Lighting gizmo icon shows in the centre of `look_down`. It is part of Studio's UI, not the sky.
- **CLEANUP:** I ran the job's script and confirmed the result. `HCSkyTest` is removed, the original `Sky` and `Atmosphere` are back, Baseplate transparency is back to 0, and the Workspace is back to Terrain, Baseplate, SpawnLocation and Camera. The temporary `HCSkyDecals` folder I used for the Decal lookup was deleted.
