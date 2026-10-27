# Job 0011 report: look sweep on version 31 (PAUSED, partial, no DONE)

> **Paused at the lead's request:** the owner account is moderated, and Open Cloud returns 403 "User is moderated".
> All sweeps A–D were already captured when the pause arrived. Play is stopped and the place is back in Edit.
> **Nothing was saved or published.** No moderation or ban notice appeared in Studio, and nothing was acknowledged.
> The account issue affects the **PBR verdict** (and possibly sky textures), so step 4 should be redone once the account is cleared.

## Setup
- **Studio:** one window. The owner reopened the place from Roblox and wasn't sure of the version number. The content confirms **v31**:
  - `ReplicatedStorage.Shared.Util.MaterialOverrides` is present.
  - `Look` contains density 0.16.
  - In Edit, `LightingStyle` reads `Realistic` and `PrioritizeLightingQuality` reads `true`.
- **Rojo:** not connected. I stopped `rojo serve` before the reopen.
- **MCP reset:** the first Play start dropped the MCP connection, and Studio came back in Edit under a new id. I re-checked v31, then started **one** solo Play and waited 45 s.
- **DataService:** `profile is locked by another server`, then `stole a live-looking lock after retries`. This is the lock left by the abandoned first start. Only one Play session was running.

## PROBE
| Where | Result |
|---|---|
| Edit | `overrides 16/16 active (HCOverridesActive=nil) not active: [] \| variants 22 \| LightingStyle Realistic \| PrioritizeLightingQuality true \| Density 0.16 \| Exposure 0 \| Moon 0` |
| Server | `overrides 16/16 active (HCOverridesActive=16) not active: [] \| variants 22 \| LightingStyle Realistic \| PrioritizeLightingQuality true \| Density 0.16 \| Exposure 0 \| Moon 0` |
| Client | the same as Server (`HCOverridesActive=16`) |

- In Studio Edit, the overrides now read 16/16 as loaded from the file. That is fixed since 0009, which read the stock names.
- Console:
  - `[MaterialOverrides] server: 16 active (0 set, 16 already)`
  - `[MaterialOverrides] client: 16 active (0 set, 16 already)`

## Rendering-quality finding (affects every overview judgement)
- With the client graphics quality on **Automatic**, `overview_high` (y = 900) rendered as **a flat grey frame: no ground, sea or city**, at every fog density, even at 0.01 (`diag_*_autoquality.png`).
- Setting `settings().Rendering.QualityLevel = Level21` on the client rendered the whole city (`diag_high_d001_q21.png`).
- **So the "grey wall" from jobs 0001 and 0009 was at least partly the draw distance at Automatic/low quality, not fog.** Automatic chose a low level here because Studio was unfocused, but real low-end players will see the same thing.
- **All sweep shots below are at Level 21.** I set the setting back to Automatic afterwards.
- **Recommendation:** treat overview readability on low quality as a draw-distance and LOD question, separate from Atmosphere tuning.

## Step 4: PBR check (cannot be judged)
- `pbr_check.png` (Level 21): Asphalt is dark grey, Brick is plain brown, Concrete is pale and speckled, Pavement is plain grey.
- **No HC_ maps show:** no aggregate, no brick bond, no sidewalk joints. They are tinted stock materials.
- **The cause is the account, not the overrides.** The Server log shows:
  - `Unable to load MaterialService.HC_Asphalt - ColorMap 'rbxassetid://112223103107268' (Error: HTTP 403 (Forbidden))`
  - the same for its NormalMap and RoughnessMap, and for HC_Sidewalk;
  - then `Unable to generate 'MaterialService.HC_Asphalt' due to some of the textures being unavailable`.
- The overrides are wired correctly (16/16); the textures just can't download while the account returns 403.
- **Redo step 4 once the account is cleared.**
- I cleaned up the slabs with `PBRCHECK_CLEAN`.

## A: noon fog density (lock 13, Level 21)
| Density | overview_high (≈1,300 studs to downtown) | overview_low_sw (≈1,000 studs) |
|---|---|---|
| 0.12 | Crisp. The whole island and sea are readable, with almost no aerial perspective. | Crisp. Downtown is sharp; the far-side shoreline at 1,500–2,500 studs is clear, with a slight haze band at the horizon. |
| **0.16** | Very similar to 0.12, a touch softer at the far edge. | Downtown is readable, with a gentle haze on the far towers and the far-side beach. **Best balance.** |
| 0.20 | The far island edge and sea are slightly washed. | Still readable; a little more milky on the far side. |
| 0.27 | The far third of the island and the sea go grey-blue and soft. Still not a wall. | Downtown is readable; the far side and horizon are hazy. |

- **Pick: 0.16**, the new default. It keeps both cameras readable with gentle depth.
- At Level 21 even 0.27 doesn't make the 0009 wall, which confirms the wall was mostly draw distance at low quality.

## B: night (lock 22.5; engine clock held at 18.20)
- Defaults read: Exposure 0.80, Brightness 1.20, tint (212, 226, 255), Moon 1.5, OutdoorAmbient (60, 70, 92).
- **`n_default`:** a huge improvement on 0009 (which was black).
  - The city reads clearly: building silhouettes, streets, lit lamps.
  - The dealership street shows its neon and the cars.
  - It still reads as night.
- **`n_exp04`:** darker. Silhouettes are readable but the suburbs go murky. It's moodier but loses gameplay readability.
- **`n_exp12`:** brighter. Lamp pools are strong, green lawns are visible, and it reads as dusk/early night. A touch too bright.
- **`n_tintold` (228, 236, 255) vs `n_tintblue` (196, 216, 255):** small differences. tintblue makes buildings slightly cooler and bluer, and tintold slightly warmer.
- **The sky is still reddish-brown in all of them.** The night HDRI clouds are maroon. Even the stronger blue tint doesn't neutralise it; the grade can't pull the sky to navy without making the whole scene blue.
  - Fixing this needs the sky itself: a different night skybox, or a cooler/desaturated version of the textures.
  - Note that the night sky textures also 403'd during this session. What renders may be a cached copy, but the colour matches 0009.
- **Pick:** Exposure **+0.8** (the default) and tint **(212, 226, 255)** (the default). Or go to (196, 216, 255) if you want a more obviously cool night.

## C: golden hour (lock 17.6)
- Defaults read: Exposure 0.12, Brightness 2.78, tint (252, 249, 244), saturation −0.01, Moon 0, density 0.18.
- **`g_default`:** **warm-but-neutral, not sepia.**
  - Sky clouds are a soft white-grey; buildings are neutral grey with a faint warm cast.
  - It reads as late afternoon. Honestly, it doesn't read very "golden": the warmth is subtle.
- **`g_sepia` (0009's grade):** visibly brownish-yellow over the whole image; the dirty/smoggy look 0009 reported. The new default is clearly better.
- **Moon:** at 17.6 the moon is **5.9° below** the horizon (`GetMoonDirection().Y = −0.103`).
  - In `g_moon6` (size 6) a pale disc **does** show on the horizon at the far left of `overview_low_sw` (next to the HUD).
  - In `g_default` (MoonAngularSize 0) **it's gone.** ✅
- **`g_d012`:** slightly crisper far side than the 0.18 default. Both are fine.
- **Pick: keep 0.18 for golden.** The slightly heavier haze helps the late-day mood; 0.12 looks like noon.

## D: blue hour (lock 18.8; engine clock held at 18.20)
- Read: Exposure 0.60, Brightness 1.39, tint (231, 239, 255), Moon 1.5 at **+2.9°** elevation, density 0.16, night sky set active.
- **Brightness:** between golden and night, and never darker than `n_default`.
  - Overview: city lights are on and silhouettes are readable.
  - Downtown: neon plus a readable building mass.
- **The small moon is visible:** a crisp white disc low in the sky at the left of `overview_low_sw`. Size 1.5 looks right. ✅
- **But it reads as night, not blue hour.** The sky is the same reddish-brown night HDRI, with no blue gradient. To read as blue hour it needs a bluer sky (sky swap or tint) at this stage.

## Errors (`console.txt`)
- **No script errors from game code.**
- **Account-level 403s, which match the moderation the lead reported:**
  - From 21:41 on, ~400 `HTTP 403 (Forbidden)` asset loads across 126 ids: HC_ material maps, the day HDRI `109667193500398`, the night and blue sky textures, sounds (`80317022777602` ×155), vehicles and props.
  - It includes old catalog ids (10475580, 18987684, 376189070), so it isn't per-asset permissions.
  - Every 2 min: `[DataService] save failed for 11686693147 (attempt n/3): HTTP 403`.
  - `DataStoreService: AccessForbidden … GetSortedAsync LB_totalEarned_v1 / LB_steals_v1`, and SetAsync 403.
  - **The player save did not persist in this session.** This is a symptom of the account issue, not a bug.
- **Pre-existing and harmless:** 19 "Asset type does not match" v1 ids, `81504106` not found, `4542793421` not authorised, `[AssetLibrary] Props/flower_bed unavailable`.
- **Mine, not the game's:** `Insufficient permissions to set SavedQualityLevel` (Client) and `HTTP requests are not enabled` (my log-export attempt).

## Files
- **Sweeps:** `A_*`, `B_*`, `C_*`, `D_*` (Level 21).
  - `B_n_tintold_overview_low_sw_banner.png` is the first try, covered by a "Cash Rain" banner; I re-shot it.
- **PBR:** `pbr_check.png` (Level 21) plus `pbr_check_*_autoquality.png`.
  - The first framing per the job (camera at the printed position) showed only 2 slabs, so I re-framed further back.
- **Diagnostics:** `diag_*` (overview_high grey at Automatic quality, then fixed at Level 21).

## Still to do when the account is cleared
1. Redo step 4 (PBR slabs) so the HC_ maps can load. Then write DONE.
