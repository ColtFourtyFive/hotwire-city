# Sourcing 20+ realistic cars for Hotwire City

Evaluated 2026-10-27, while building `carpipe`. Every option below ends in the same step: run the file through `build_car.py`, which outputs a Roblox GLB plus a JSON sidecar.

## Verdict

**Use Sketchfab CC-BY models through the Download API as the main source.** Two creators matter most:

- **Daniel Zhabotinsky** has published about 55 game-ready cars under CC-BY. Each is 15–37k triangles, and every design is **fictional**, with names like "Fairheaven LT '80", "Canyon '75 Taxi" and "Shvan '92". Between them they cover sedans, wagons, cop cruisers, taxis, muscle cars, vans, an ambulance, pickups, a tow truck, a fire-department wagon and an armored van. That is close to a GTA traffic roster, already built as brand parodies.
- **comrade1280** offers two "Generic … pack" sets.

Our Sketchfab token is in `~/.config/hotwire/sketchfab_token`. We used it to download 5 models, and carpipe processed all 5 (see the renders in `docs/v2/proto/carpipe/`).

**Not recommended:**
- Creator Store cars loaded at runtime.
- AI image-to-3D for hero cars.

## 1. Sketchfab: CC-BY and CC0 models through the API (recommended)

**Token and flow (tested here):**

1. Get a token. Make a free Sketchfab account, go to **Settings → Password & API → API Token**, and copy the 32-character token. Store it in one of these two places:
   - the environment variable `SKETCHFAB_API_TOKEN`, or
   - the file `~/.config/hotwire/sketchfab_token` with `chmod 600`.

   Never commit the token and never print it. OAuth2 is only needed if *other* users log in through our tool, so we don't need it.
2. Search. This needs no authentication:

   ```
   GET https://api.sketchfab.com/v3/search?type=models&q=police%20car&downloadable=true&license=by&categories=cars-vehicles&max_face_count=60000
   ```

   `license=cc0` returned **no** car results in this category on 2026-10-27, so CC0 is effectively not an option here.
3. Fetch the licence and author with `GET /v3/models/{uid}`. Its `license.slug` must be `by` or `cc0`.
4. Download with `GET /v3/models/{uid}/download` and the header `Authorization: Token <token>`. The response is JSON with short-lived signed URLs for `glb`, `gltf` (zip) and `usdz`. Without a token this call returns **401**.

`sketchfab_fetch.py search|get` implements all four steps. It refuses NC, ND and SA licences, writes `SOURCE.json` (licence plus attribution string), and registers the car in `models_local.json` so that `build_car.py --model <id>` works straight away.

**Licence rules for a monetised Roblox experience:**

| Licence | Can we use it? | Why |
|---|---|---|
| CC-BY 4.0 | OK | Credit the author in an in-game credits screen and in the experience description. Carpipe keeps the attribution string in each car's sidecar `source` field. |
| CC0 | OK | No credit required. |
| NC (non-commercial) | Skip | Game passes and Robux make the experience commercial. |
| ND (no derivatives) | Skip | Decimating and re-baking produces a derivative. |
| SA (share-alike) | Skip | Derivatives would have to be shared under the same licence. |

**Trademarks are a separate issue from copyright.** A CC-BY Porsche or BMW model frees the mesh but not the badge or the trade dress. Prefer fictional designs, or strip badges (they end up in `Trim`) and rename the car to a parody brand.

**Shortlist of 32 CC-BY cars, all fictional designs**

Triangle counts are from the API. Each car needs about 1–5 minutes of carpipe time.

| GTA role | Model (Sketchfab uid) | tris |
|---|---|---|
| sedan | Fairheaven LT '80 (`e2678da920cc4be68dbc193727919ffb`), **tested** | 19.7k |
| sedan | Negotiator '80 (`892b2684fb37442299bfad9222cf331c`) | 19.7k |
| sedan | Illinois '90 (`d604871eee5b4181bb298163b0b675b7`) | 19.4k |
| sedan | Riverside '88 (`8509a7f82665442592627940b7a1cfab`) | 19.3k |
| compact | Kiri '86 (`5c17c582ef9549798f694b660feea42a`) | 20.3k |
| compact | Kiri '94 (`b92072c8cd9d4ee6b3c0be45de48223c`) | 14.6k |
| compact | Compact '07 (`25c6874d173a4f6ca63e150bbd505686`) | 15.1k |
| sedan | Sigil '07 (`22abe5284d4c4b55920b8462eb24a8c1`) | 17.0k |
| sedan | Ace '11 (`055ff8a21b8d4d279debca089e2fafcd`) | 18.4k |
| wagon | Fairheaven SW '84 (`aa0becb6e854422596cac6b21bf79787`) | 19.5k |
| wagon | Sialia SW '68 (`eea2291a90f04a4b860c9e74be14f2d6`) | 18.0k |
| police | Fairheaven LT '80 Cop Cruiser (`61766c1e6e1e4b2b803c174f33433a74`), downloaded | 19.5k |
| police | Illinois '90 Police cruiser (`dc81625478a744649b210c7f248b0b6a`) | 19.7k |
| police | Murphy '97 Cruiser (`31f0ac0f03ad42e3bbf236b3ecb2049e`) | 17.4k |
| police | Phoenix 455 '71 Interceptor (`fbd5b96599944932a71fc8c81291253c`) | 26.5k |
| taxi | Canyon '75 Taxi (`9e8f92a215784f3d8aaaaeab1bef54c4`), **tested** | 20.0k |
| taxi | Illinois '90 Taxi (`72d91f4bce814818b3cd1f2de60f8ef2`) | 19.9k |
| muscle | Phoenix 455 '71 (`955edc733c6d44fabc0ad7c246a15896`) | 25.9k |
| muscle | Duke '69 (`46fed79f600c4fc69e060991f9e3e4f9`) | 18.6k |
| muscle | Palomino Special '67 (`8419d645064e4b1699d970375e1c3cc7`) | 16.4k |
| sports | Asti Stradale '89 (`97b15b067111443ebe05840137b49c65`) | 20.9k |
| sports | Chapman '73 (`f30b644b59b54e809355009dce463d47`) | 12.8k |
| super | "Fictional supercar – V12 Goblin" by ollitei (`0a20e49ad5774d778567cb5c3f345786`), **tested** | 86.6k |
| SUV | Bokaroo '67 (`22015d1863d6455aa31cfd738b972c50`) | 28.3k |
| pickup | Doutrive '78 (`30700a84311c4bea9ef722f0773ce92a`) | 24.6k |
| pickup | Conquer '89 Pickup (`6c48c94be8974dc7a5932f697c0ba68f`) | 21.1k |
| van | Shvan '92 (`09d718c9cf72401b8534d265a06a803f`), **tested** | 23.0k |
| van | LCT 3000 '95 (`663a0953c038434a918cb85725c88ffa`) | 18.9k |
| ambulance | Shvan '92 Ambulance (`2856dd3c61f940909dced9a5c0379484`) | 25.9k |
| fire | Fairheaven SW '80 Fire Dept. (`0cd661aaab6949ba9d77dbb13ab146c5`) | 21.3k |
| tow truck | Lightbody '90 MD Tow Truck (`5cba208001c64e8ea164f89e4dde91e7`) | 26.2k |
| armored truck (heist event) | MD '84 Armored (`26e809cce40e4359a3199649f12ef295`) | 20.4k |

Two further sources have no single-car uid in the table:
- **Packs:** comrade1280 "Generic passenger car pack" (`20f9af9b8a404d5cb022ac6fe87f21f5`, 69k) and "Generic civil service vehicles pack" (`8ff2a13f30914932a70c7950cfa58465`, 93k). Both hold several cars in one file. Process one car at a time with a `"select": "<object-name regex>"` entry in the model config.
- **Bus:** "Generic Town Bus" by own.guest (`14fe03d792914d51b6c6250b393c44fd`, 55k).

**Pros:**
- Hundreds of realistic, game-ready CC-BY cars.
- Consistent glTF output that carpipe handles. All 5 downloads ran end to end without manual fixes.
- Fictional-brand sets exist, which fits the GTA parody tone.
- Free.

**Cons:**
- Needs a token, and the API is rate-limited, so download a few per minute.
- Quality and structure vary from model to model:
  - atlas-textured bodies, which use the tint-mask route;
  - clear-coat overlay shells (carpipe drops these);
  - missing interiors;
  - lights painted into the texture, so their positions are estimated.
- Each car still needs a visual QA pass: check the `*_roles.png` render.
- Attribution has to be maintained.
- Real-brand models need debadging.

## 2. Roblox Creator Store cars loaded at runtime

**How it works:**
- `InsertService:LoadAsset(id)` runs on the server. It has always been limited to assets the experience owner (user or group) owns, plus Roblox-owned ones. Check the current docs before relying on it for public free models.
- In practice, the working route is to insert the model in Studio, audit it, and publish our own copy under the group.

**Pros:**
- Already Roblox-native: MeshParts, SurfaceAppearance, often an A-Chassis rig.
- No conversion step.

**Cons. We don't recommend this for the core roster:**
- Provenance. Many "realistic" free cars are rips from GTA V, Forza or Assetto Corsa. That is copyright infringement, which risks DMCA takedowns and moderation of the whole experience.
- Real-brand logos.
- Backdoor scripts: `require(<id>)`, obfuscated loaders.
- Unknown and inconsistent scale, part counts and triangle budgets.
- No licence text.
- Runtime loading adds latency and makes us depend on someone else keeping the asset public.

**Use it for:**
- quick prototypes;
- audited, purchased packs from reputable creators that state their terms. Re-publish these under our group.

## 3. AI image-to-3D (Higgsfield `generate_3d`, Meshy, Tripo, Rodin)

**Pros:**
- Unlimited unique fictional designs, made in minutes. Ideal for parody brands.

**Cons. We don't recommend this for hero or traffic cars today:**
- v1 tried this, and those cars are what the kill list calls "blob-like AI meshes with smeared baked lighting".
- Current outputs still fuse the wheels to the body. Glass and interior come out as painted texture, and hard edges melt.

Carpipe can import these meshes, but:
- its wheel finder needs separate wheel geometry;
- the paint becomes the tint-mask route with baked lighting in it.

**Use it for:**
- distant or static props, such as wrecks and parked background cars;
- concept art that drives a parody-brand design.

This route costs credits per attempt.

## 4. Other free sources checked (all reachable from this machine)

| Source | Finding |
|---|---|
| Khronos glTF-Sample-Assets | **CarConcept** (CC-BY 4.0, 213k tris, PBR, clear-coat paint). This is the best-quality free test car we found and the stress test for decimation. |
| OpenGameArt | Mostly low-poly 2000s game cars. We used the Muscle Car (CC-BY 3.0), VW Corrado (CC0), UAZ-452 van (CC0) and Camaro (.blend, CC-BY 3.0). Usable for background traffic after rebranding. |
| Poly Haven | No cars. One car under a cover sheet, which works as a garage prop. |
| ambientCG | Materials only. |
| Kenney / Quaternius | CC0 but stylized. Wrong look. |
| Blender demo files | The BMW27 benchmark (`download.blender.org/demo/test/`) is high detail, but no licence text ships with it and it carries BMW marks. Robustness test only. |
| BlendSwap / Free3D / CGTrader free / TurboSquid free | Need a login. Licences are mixed, and "editorial only" or engine-locked terms are common. Not automated. |
| Unity / Unreal marketplace packs | EULAs usually restrict use to that engine. Not usable on Roblox. |
