# Asset sources unlocked (2026-10-27)

- **Sketchfab API**
  - The token is in `~/.config/hotwire/sketchfab_token`. Read it in code. **Never print, log or commit it.**
  - Download: `GET https://api.sketchfab.com/v3/models/{uid}/download` with the header `Authorization: Token <token>`. It returns signed glTF and GLB URLs.
  - Search: `GET https://api.sketchfab.com/v3/search?type=models&q=...&downloadable=true` with filters such as `license`, `max_face_count` and `sort_by=-likeCount`.
  - Licenses: use **CC0 or CC-BY** (`cc0`, `by`) only, because the game is monetized. Never use NC, ND or SA unless reviewed. Record every model's attribution in `assets/ATTRIBUTION.md`, and show it in an in-game Credits screen.
  - Strip real brand logos and badges; we use GTA-style parody brands.
- **Roblox asset delivery.** The Open Cloud key now has `legacy-asset:manage`.
  - Call `GET https://apis.roblox.com/asset-delivery-api/v1/assetId/{id}` with `x-api-key`. It returns `{location}`; download that URL.
  - The download is gzip-compressed. Model assets are `.rbxm`, which `@lune/roblox` `deserializeModel` can parse. Mesh assets use Roblox's mesh format (v2–v5).
  - Use this to inspect Creator Store models offline. To use a third-party model in the game, load the original asset ID at runtime; do not re-upload it as our own.
- **Roblox Open Cloud key: 46 scopes.** These include universe-places write (publish), luau-execution-session, universe and place config, universe.thumbnail write, game passes, developer products and datastores.
