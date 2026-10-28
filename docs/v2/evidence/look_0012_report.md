# Job 0012 report: night, late-night, dusk and dawn skies; golden hour (v35, v1 map)

**All 21 sky faces loaded in this session.** `ContentProvider:GetAssetFetchStatus` returned `Success` for every id in the job table. No sky id appears in this session's log.
- **But:** in the previous Play session on the same place (job 0017), the client log had `rbxassetid://88812082275800 failed due to: HTTP 502` three times. That id is the **night Up** face. It was transient and loaded fine here, but it's worth a retry or fallback.

## Setup and scope
- **Place:** v35+, opened from Roblox in the same open session as jobs 0016 and 0017. **No Rojo.** Never saved or published.
- **Edit PROBE:** schedule `nightLate@0.00 dawn@5.00 day@5.65 blue@18.35 night@19.50`, night Ft `rbxassetid://102872066736317`. Every face matches the job table, with shared Dn `98952593275525`.
- **Map is v1:**
  - Per the job text, I used **job 0011's cameras**: `downtown_street` (60,12,160)→(60,40,0) and `overview_low_sw` (−700,180,−700)→(0,20,0).
  - I derived the other two from them: `sky_up` from (60,12,160) straight up, top ≈ north; `aerial_west` from (−700,180,−700) facing −X.
  - On v1, `downtown_street` mostly frames a building front; only a corner of sky is visible.
  - As the lead asked, I judged **only the sky and the grade**.
- **Scope (lead, v35):**
  - **Done:** the six lock hours (step 3), the 17.6 low aerial at Level 21 and at Automatic, and the OLDGOLDEN A/B (3a).
  - **Not run:** the swaps (step 4), the dusk A/B (step 5) and the calibration (step 6). The lead re-queued 0012 for the wave A v2-world reopen, where the whole job runs.
- One Play session, about 90 s of build first. Client at Level 21 except the `_auto` shots, and set back to Automatic at the end. CLEAR was run before stopping.

## PROBE lines (Client)
```
17.6 L21:  Sky day      Ft 109667193500398  ClockTime 17.599 Exposure 0.178 Tint (0.988,0.975,0.956) Sat -0.008 Con 0.10 Yaw -125.60 Atmo D 0.134 O 0.38 H 0.53 G 0.71 C (0.837,0.785,0.722) Dc (0.552,0.527,0.526) Moon 0
17.6 Auto: same values, Yaw -139.44
19.0 L21:  Sky blue     Ft 79742849062319   ClockTime 18.200 Exposure 0.948 Tint (0.892,0.929,1) Sat -0.092 Con 0.12 Yaw 100.52  Atmo D 0.151 O 0.25 H 0.62 G 0.08 C (0.400,0.415,0.451) Dc (0.224,0.238,0.279) Moon 1.5
20.5 L21:  Sky night    Ft 102872066736317  ClockTime 18.200 Exposure 0.800 Tint (0.831,0.886,1) Sat -0.20 Con 0.12 Yaw 0.00      Atmo D 0.120 O 0.25 H 0.35 G 0.00 C (0.157,0.169,0.196) Dc (0.078,0.086,0.106) Moon 1.5
22.5 L21:  identical to 20.5
2.0  L21:  Sky nightLate Ft 93141238500720  ClockTime 5.800  Exposure 0.800 (rest identical to 20.5)
5.5  L21:  Sky dawn     Ft 129901905692620  ClockTime 5.847 Exposure 0.857 Tint (0.908,0.940,1) Sat -0.063 Con 0.12 Yaw -100.51 Atmo D 0.159 O 0.25 H 0.69 G 0.10 C (0.449,0.480,0.534) Dc (0.255,0.278,0.333) Moon 1.5
```
All of these are in `.probes.txt` as well.

## Night (20.5, 22.5, 2.0)
- **20.5 / 22.5 (`night`): close to the target.**
  - **Upper sky:** a deep blue-black navy with faint, subtle stars. **No reddish-brown.**
  - **Horizon:** a cool blue-grey band. A faint warm glow sits just above the horizon at the **left** of the `overview_low_sw` frame (the camera looks NE from the SW corner).
  - **Zenith (`sky_up`):** near-black navy with faint stars, darker than I'd call "deep blue". It reads as black-blue, not black, and not brown.
  - The two hours are identical (same PROBE and the same frames).
- **2.0 (`nightLate`): not deeper than 22.5.**
  - In `t0200_overview_low_sw` the sky is slightly **lighter** and a touch **purple** low down, with more visible stars.
  - The city is lit flatter, by the engine sun held in the east.
  - **The zenith (`t0200_sky_up`) has a dark teal-green cast** instead of navy.

## Dusk and dawn (19.0, 5.5)
- **19.0 (`blue`):**
  - **Away from the sun (`t1900_overview_low_sw`):** reads as blue hour. A deep blue upper sky over a lighter teal-blue horizon band, with the moon visible. Good.
  - **Sun side (`t1900_aerial_west`):** the order is wrong.
    - The warm band is a **muddy brown-amber** at mid-height.
    - **Below it, down to the sea line, is a flat mid/cyan-blue band**, and the white sun disc sits inside that blue band.
    - So the gradient runs blue → brown-amber → navy going up, instead of amber at the horizon fading to blue.
    - The amber reads brown, not gold.
  - **Zenith (`t1900_sky_up`):** near-black navy, much like night.
- **5.5 (`dawn`):** the same structure.
  - A flat cyan-blue horizon band holds the sun disc (left of the NE view), with a dusty rose-brown band above it, then slate-blue.
  - **The zenith (`t0530_sky_up`) and the upper sky in `downtown_street` have a dark green-teal cast.**

## Casts by region
| Hour | Zenith | Sun side | Opposite side |
|---|---|---|---|
| 19.0 | near-black navy | brown-amber band above a cyan-blue horizon band | teal-blue horizon band |
| 20.5 / 22.5 | near-black navy (OK) | n/a | cool blue-grey (OK) |
| 2.0 | **dark teal-green** | n/a | slight purple low |
| 5.5 | **dark green-teal** | rose-brown band above a cyan-blue horizon band | slate blue |

## Golden hour (17.6)
- **Level 21, new (`t1760_overview_low_sw`):**
  - The city reads clearly to the far edge.
  - Clouds are visible.
  - Beyond the city there's a flat **warm taupe** horizon band. It's lighter, but still reads as a band or wall rather than depth.
  - No sepia. The sun is out of frame, so I couldn't judge a glow round it.
  - Zenith (`t1760_sky_up`): slate blue-grey between engine clouds.
- **Level 21, old (`t1760_overview_low_sw_old`):** the horizon band is **neutral grey**, slightly hazier over the far towers. **New is warmer and a little clearer.**
- **Automatic, new (`t1760_overview_low_sw_auto`):**
  - The city only draws out to about the first two blocks; the rest is the bare dark baseplate.
  - The empty band reads **warm taupe**.
- **Automatic, old (`t1760_overview_low_sw_auto_old`):** the same draw distance; the band reads **grey**. New is warmer.

## Seams
- No visible seams or face edges in any `sky_up`, or at the face corners I could see.
- The engine clouds at 17.6 cover the day zenith.

## Compared with job 0018
I didn't directly compare, because this is the v1 map and different framings. The night sky is no longer the near-black red-brown of job 0011/0018: no red-brown appears anywhere.

## Console
- **Server:** `[AssetLibrary] Props/flower_bed unavailable; using procedural fallback` and `[ShopService] no part tagged GunStoreCounter; placing fallback FREEDOM ARMS counters (MapLayout)`.
- **Client:** 13× `[MinimapController] slow GPS route` (5.1–19.5 ms).
- **ContentId failures:** 63 unique.
  - 62× `Asset type does not match requested type`, mostly audio-looking ids such as `80317022777602` and `9112758500`.
  - 1× `4542793421 User is not authorized`.
  - **None are sky ids.**
- The full lists are in `console.txt`.

DONE
