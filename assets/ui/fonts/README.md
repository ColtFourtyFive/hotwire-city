# UI fonts (offline art pipeline only)

These TTFs are used by `tools/ui/*.py` to render the custom UI art (wordmark, app icons, previews) and the layout
mockups in `docs/v2/early/ui/`. The game itself never ships them: in Roblox the same families are the built-in
Oswald / Montserrat / Sarpanch and the Roblox-owned Store families Kanit (`12187373592`) and Damion (`12187607722`)
(`src/client/UI/Theme.luau`).

All files come from Google Fonts and are licensed under the SIL Open Font License 1.1
(https://openfontlicense.org), which permits bundling and redistribution, and rendering outlines into artwork:

| File | Family | Designer |
|---|---|---|
| `Kanit-800.ttf`, `Kanit-900.ttf` | Kanit | Cadson Demak |
| `Oswald-400/500/600/700.ttf` | Oswald | Vernon Adams, Kalapi Gajjar, Cyreal |
| `Montserrat-400/500/600/900.ttf` | Montserrat | Julieta Ulanovsky et al. |
| `Damion-400.ttf` | Damion | Vernon Adams |
| `Sarpanch-900.ttf` | Sarpanch | Indian Type Foundry |

Pricedown is **not** included (its licence excludes games; see `gta_ui_language.md` §0).
