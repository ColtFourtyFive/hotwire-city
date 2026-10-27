# Roblox Sky face orientation (verified in the engine)

Verified by Studio job 0005 on 2026-10-27; see `studio/results/0005` on `studio-results`.

- **Use Image asset IDs, not Decal IDs.** The Sky rejects Decal IDs with 403 IncorrectAssetType. Upload with `assetType "Image"`; `tools/rbxcloud.py upload-image` has been fixed to do this. The v1 uploads in `Config/Assets.Images` are Decal IDs and must be resolved or re-uploaded.
- **Horizontal faces** (seen from the centre of the world):

  | Face | Points toward |
  |---|---|
  | `SkyboxFt` | **−Z** |
  | `SkyboxBk` | **+Z** |
  | `SkyboxLf` | **+X** |
  | `SkyboxRt` | **−X** |

  None of these are mirrored or rotated: each image appears upright and readable when you face its direction. Note that Lf and Rt are the reverse of the naive "left = −X" guess.
- **`SkyboxUp`**: not mirrored. The top of the image points to **+X**, so it appears rotated 90° clockwise when you face Ft (−Z) and look up.
- **`SkyboxDn`**: not mirrored. The top of the image points to **−X**, so it appears rotated 90° counter-clockwise when you face Ft and look down.
- **Resolution:** plan for 1024² per face.
- **Resolved Image IDs of the test kit**, kept for future checks:

  | Face | Image ID |
  |---|---|
  | Ft | 125021145685093 |
  | Rt | 79998295024603 |
  | Bk | 133950846661312 |
  | Lf | 128567569050109 |
  | Up | 98950637562746 |
  | Dn | 83560359428904 |
