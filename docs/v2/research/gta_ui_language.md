# GTA presentation language → Roblox implementation spec

Status: research spec, 2026-10-27. Subordinate to `00_LEAD_DIRECTION.md`.
Scope: the HUD, menus, big messages, phone, map, loading, sound cues and camera. It describes what GTA V (and the GTA VI material published so far) does, then gives the exact Roblox recipe, the assets we must make, and the changes needed in our current UI code.

Evidence images are in `docs/v2/research/img_gta/`:
- `ref_gtawiki_*` are reference captures from gta.wiki (CC BY-NC-SA, for internal reference only, never shipped).
- `font_compare_*`, `roblox_builtin_font_weights.jpg` and `mock_v2_*` were rendered by this research.

---

## 0. Decisions in one screen

1. **Layout (GTA V).**
   - The minimap is a rectangle at bottom-left: **0.150 W × 0.189 H**, which is 192×136 on our 1280×720 design canvas.
   - Under it sits a split bar: health 50%, armour 25%, and a third 25% slot for nitro or stamina.
   - Wanted stars, cash and ammo go top-right. There are no panels behind them, only text with an outline.
   - Help text goes in a small black box at top-left.
   - Objective lines and subtitles go at bottom-centre, with colour-coded keywords.
   - The notification feed stacks above the minimap.
   - The vehicle, district and street name show in a script font at bottom-right.
   - The whole left icon-button column, the top-centre cash pill and the bottom-centre HOME button are deleted.
2. **Fonts. Pricedown is not usable as a font.** Its Typodermic licence lists "games" as needing a separate licence: EULA v260817 §4.3 forbids embedding, and §4.5 forbids reusable glyph sheets, so it cannot be used for live text or a digit atlas.
   - *(Corrected in verification.)* EULA §2.2 does allow **fixed, pre-rendered artwork** in distributed products. Static PNGs of fixed words ("wasted", "busted", "mission passed", the wordmark) appear to be permitted. That is a decision for the lead; see the Verification section.
   - Closest legal match, chosen by rendering side by side: **Kanit Black** (Roblox-owned Creator Store font `12187373592`, weight 900 confirmed). Used for big messages, cash and ammo.
   - **Oswald** (built-in) stands in for Chalet Comprime: titles, tabs and labels.
   - **Montserrat** (built-in) stands in for Chalet London: help text, subtitles, feed and menu rows.
   - **Damion** (Store `12187607722`) stands in for the SignPainter script: location and vehicle names.
   - FredokaOne is removed everywhere. Gotham is already removed by Roblox and silently maps to Montserrat.
3. **Palette.** Take the HUD colours from GTA V's own `hudcolor.dat` (table in §3). Semantic use:
   - white `#F0F0F0` for text;
   - black at 73% (`rgba(0,0,0,186)`) for panels;
   - red `#E03232` for enemies and wanted;
   - blue `#5DB6E5` for friendlies and armour;
   - yellow `#F0C850` for destinations and the objective GPS route;
   - green `#72CC72` for pickups and +cash;
   - purple `#A44CF2` for the player waypoint.
   - One brand accent, **Ignition Orange `#FF8A3D`**, is used sparingly. Pink and cyan are deleted.
4. **Big messages.** Wasted, busted and passed are a full-width translucent black band, **≈19.5% of screen height on average, centred at 48.8%**. The band is a slight keystone, ≈15.5% H at the left edge and ≈23% at the right; see the Verification section. The title is lowercase heavy type with no outline: **wasted** in crimson `#B3212F`, **busted** in blue `#5DB6E5`, **passed/delivered** in yellow `#F0C850`. On wasted and busted the screen goes grayscale (ColorCorrection Saturation −1), the camera drifts slowly, and the audio is muffled. No stamps, shakes, confetti or Back-easing pops.
5. **Menus.** All v1 modal "Kit.window" cards are replaced by three containers:
   - (a) a **pause menu** with tabs (MAP / JOBS / GARAGE / STATS / STORE / SETTINGS);
   - (b) GTA "interaction menu" **list menus** at shops and the garage;
   - (c) a **phone** with a 3×3 app grid.
   The retention mechanics from `original_brief.md` (daily, playtime gifts, offline earnings, codes, rebirth) stay, re-presented as phone texts and emails, feed posts and pause-menu tabs (§5.15).
6. **Minimap.** Pre-rendered top-down map tiles (ImageLabel) inside a **CanvasGroup**, which clips rotated content. Blips come from one sprite sheet. The GPS route is drawn from rotated thin Frames. Police vision cones are wedge sprites. The border flashes red and blue while police can see you.
7. **Top bar and CoreGui.** Keep the Roblox top bar (it cannot be removed safely). Disable the CoreGui PlayerList, Health, Backpack and EmotesMenu. Put HUD ScreenGuis in `ScreenInsets.CoreUISafeInsets` and full-screen overlays in `None`. Restyle and move the chat window to the left-middle (GTA Online's chat position) so top-left stays free for help text.
8. **Mobile.** The thumbstick owns bottom-left, so the minimap moves to **top-left, under the top bar**, with its bars beneath. Help text moves under the minimap. Location names show briefly at top-centre. The weapon wheel and phone open from on-screen buttons.

---

## 1. Sources

- GTA V HUD colours, defaults from `common:/data/ui/hudcolor.dat`: https://docs.fivem.net/docs/game-references/hud-colors/
- Rockstar text colour codes and their semantic use (`~r~` enemy, `~b~` friendly, `~y~` destination, `~g~` pickup): https://docs.fivem.net/docs/game-references/text-formatting/
- Minimap size and anchor in `frontend.xml` (posX −0.0045, posY 0.002, sizeX 0.150, sizeY 0.188888, align L/B): https://docs.fivem.net/docs/cookbook/2019/08/12/useful-snippet-getting-the-top-left-of-the-minimap-in-screen-coordinates/
- GTA V fonts. Menus: Chalet Comprime Cologne Sixty (titles) and Chalet London Nineteen Sixty (items and subtitles). Pricedown for the centre messages and money. SignPainter for the bottom-right location. https://gta.wiki/w/Fonts
- Wasted sequence ("fallen character in motion for one second, then grayscale and slower, *Wasted* centred; mission name under the red word"): https://www.grandtheftwiki.com/Death
- In-game wanted tutorial text (quoted in §2.4): https://gta.wiki/w/Wanted_Level_in_GTA_V
- GTA VI star states and heat indicators: https://gta.wiki/w/Wanted_Level_in_GTA_VI
- Weapon wheel: 8 category slots, slow motion in single player, centre shows the weapon name and a count: https://gtaforums.com/topic/532181-gta-v-weapons-information/
- HUD element list, including the vehicle name and class at lower right: https://gta.wiki/w/Heads-Up_Display
- Pricedown licence ("Needs another license: … apps, games …"): the `read-this.html` file in the dafont download of *Pricedown Bl* (Typodermic, EULA v260817).
- Roblox fonts:
  - Enum list: https://create.roblox.com/docs/reference/engine/enums/Font (Gotham and Arial are removed and map to Montserrat and Arimo).
  - Family table: https://create.roblox.com/docs/reference/engine/datatypes/Font
  - Creator Store font families (asset type 73, all 91 owned by "Roblox") were enumerated with `apis.roblox.com/toolbox-service/v1/marketplace/73`.
  - Face weights were read from `assetdelivery.roblox.com/v1/asset/?id=<id>`.
- Roblox UI APIs: [ScreenInsets](https://create.roblox.com/docs/reference/engine/enums/ScreenInsets), [GuiService.TopbarInset](https://create.roblox.com/docs/reference/engine/classes/GuiService), [CoreGuiType](https://create.roblox.com/docs/reference/engine/enums/CoreGuiType), [StarterGui TopbarEnabled caveats](https://create.roblox.com/docs/reference/engine/classes/StarterGui), [ChatWindowConfiguration](https://create.roblox.com/docs/reference/engine/classes/ChatWindowConfiguration) (has Horizontal/VerticalAlignment), [UIStroke](https://create.roblox.com/docs/reference/engine/classes/UIStroke) (BorderOffset, BorderStrokePosition, StrokeSizingMode), [CanvasGroup](https://create.roblox.com/docs/reference/engine/classes/CanvasGroup) (always clips; memory capped by QualityLevel), [EditableImage](https://create.roblox.com/docs/reference/engine/classes/EditableImage), [ColorCorrectionEffect](https://create.roblox.com/docs/reference/engine/classes/ColorCorrectionEffect) (Saturation −1 means full desaturation), [Rich text](https://create.roblox.com/docs/ui/rich-text) (`<mark>`, `<stroke>`, `<sc>`, `<uc>`), [CaptureService](https://create.roblox.com/docs/reference/engine/classes/CaptureService), [UserInputService:GetImageForKeyCode](https://create.roblox.com/docs/reference/engine/classes/UserInputService).
- The top bar grew from 36 px to 58 px, and the reserved space varies by device: https://devforum.roblox.com/t/studio-beta-for-experience-controls-available-now/2567355

Reference images:

| File | Shows |
|---|---|
| `ref_gtawiki_GTAV_new_screen.jpg` | Annotated GTA V HUD: interaction menu, stars, cash, ammo, feed card, minimap with bars, script location text, objective line |
| `ref_gtawiki_Wasted-GTAV-EnhancedVersion.jpg` | Wasted screen |
| `ref_gtawiki_Busted-GTAV.jpg` | Busted screen |
| `ref_gtawiki_Wasted-GTAVe-MissionFailed.png` | Mission failed screen |
| `ref_gtawiki_WeaponWheel-GTAV.jpg` | GTA V weapon wheel |
| `ref_gtawiki_HUD-GTAV.png` | GTA V weapon wheel, darker variant |
| `ref_gtawiki_WeaponWheel-GTAVI-AnExtendedLook*.jpg` | GTA VI weapon wheel and HUD |
| `ref_gtawiki_WantedLevel-GTAVI-*.jpg` | GTA VI star states and heat badges |
| `ref_gtawiki_PauseMenu-GTAVe.jpg` | Pause map |
| `ref_gtawiki_Phone-GTAV-*.jpg` | Phone |
| `ref_gtawiki_Radar-GTAVe*.png` | GTA V radar |
| `ref_gtawiki_Radar-GTAVI.png` | GTA VI radar: rounded, 3D, pink route |
| `ref_gtawiki_Notification-GTAV-*.png` | Feed text |
| `ref_gtawiki_Artwork-GTAVI-CoverArt-Landscape.jpg`, `ref_gtawiki_GTAVI-Trailer1-Announcement-Artwork.jpg` | GTA VI palette |

---

## 2. GTA presentation language (what the games do)

The sources are the citations above plus measurements taken from the reference captures. Anything marked *(obs.)* comes from gameplay observation or capture measurement, not from a citation.

### 2.1 Screen map (16:9)

```
┌───────────────────────────────────────────────────────────────┐
│ [help text box]                                   ★★★☆☆       │  top-left: help text, top-right: wanted
│  black 73%, white text,                           $15,150     │  cash (Pricedown, white, black outline)
│  key glyphs inline                                +$700       │  delta under it (green / red), then rolls in
│                                                   12  48      │  ammo: clip white, reserve grey
│                                                               │
│                                                               │
│                 (big messages: band at 49% H)                 │
│                                                               │
│ [feed card]                                                   │  feed stacks upward above the radar
│ [feed card]                                  Vehicle, Class   │  bottom-right: script font
│ ┌────────────┐                                District        │
│ │  RADAR     │      Objective / subtitle line   Street        │
│ └────────────┘     (bottom-centre, keywords coloured)         │
│ ▬▬▬▬▬▬ ▬▬▬ ▬▬▬                                                │  health 50% | armour 25% | ability 25%
└───────────────────────────────────────────────────────────────┘
```

The HUD is **sparse and contextual**. Cash, ammo and stars appear only when relevant or when they change. Nothing has rounded "card" chrome, and nothing bounces.

### 2.2 Minimap (radar)

- **Shape and size.**
  - A flat rectangle, with no rounded corners in V.
  - `frontend.xml` gives size **0.150 × 0.188888** of the screen, anchored left-bottom inside the safe zone. At 1080p that is ≈288×204 px.
  - The player arrow sits horizontally centred, about **59–60% down** *(obs., measured on the annotated capture)*.
  - A black "N" disc rides the edge in the north direction.
- **Rotation and zoom.** The map rotates with the camera heading. It zooms out with vehicle speed *(obs.)*. An "expanded radar" toggle doubles its size and also reveals cash.
- **Style.**
  - Dark grey land, light grey roads, darker water. The pause map samples at land ≈`#181818`–`#1E1E1E` and roads ≈`#909090` *(measured from `PauseMenu-GTAVe`)*.
  - Golf courses and parks are muted green.
  - Blips are white or single-colour glyphs with dark outlines. A blip shows a small up or down variant when its target is above or below the player *(obs.)*.
- **Route colours.**
  - The GPS line takes the colour of its target blip.
  - Player waypoint: `HUD_COLOUR_WAYPOINT #A44CF2` (purple, visible in `Radar-GTAVe-Waypoint`).
  - Objective: `HUD_COLOUR_OBJECTIVE_ROUTE` = yellow `#F0C850`.
  - GTA VI's radar (`Radar-GTAVI.png`) is a rounded rectangle with 3D buildings, a **pink** route and a distance readout ("1.86 mi").
- **Police.**
  - The radar **flashes red and blue while cops can see you**.
  - When they lose you, the **stars flash** and **vision cones** appear on the radar showing where they search. Stay out of the cones until the search is called off.
  - The tutorial wording is from gta.wiki, Wanted Level in GTA V ("The Radar flashes red and blue when the Cops can see you"; "When out of sight of the Cops, the Wanted Stars will flash and cones will appear on the Radar"). The tutorial does not give the cone colour; *blue* cones are an observation.

### 2.3 Health, armour and ability bars

- A thin bar sits under the radar, split into **50% / 25% / 25%**:
  - health green `HUD_COLOUR_RADAR_HEALTH #359A47`;
  - armour `HUD_COLOUR_RADAR_ARMOUR` = blue `#5DB6E5`;
  - special ability yellow `#F0C850` (in single player; the colour per character varies). See `GTAV_new_screen`, `Radar-GTAVe`.
- Each segment has an unfilled track: the same hue, darkened. Health turns `RADAR_DAMAGE #EB2427` and pulses when low *(obs.)*.
- GTA VI moves these to top-left as three bars with round dark icon badges. Measured colours: health pink `#F5ADC5`, stamina mint `#75E9D4`, a lavender `#A487FE` third bar (`WeaponWheel-GTAVI-AnExtendedLook-TopLeft`). **We follow the V layout** (lead direction: "minimap bottom-left with health and armor bars").

### 2.4 Wanted level

- **GTA V.**
  - Up to 5 stars, top-right, shown only while wanted (`~ws~` is literally a "wanted star" glyph in the text system).
  - Filled stars are white with a dark outline. Unfilled slots show as outlines.
  - While police are searching (they have lost sight), the stars **flash** between white and grey.
  - Losing the level makes them fade away.
- **GTA VI** adds states:
  - **solid white** = police have line of sight;
  - **flashing** = sight broken;
  - **red** = lost, but still inside the search radius;
  - **solid grey** = a description was given but police have not arrived;
  - **hollow** = crime reported with no description.
- **GTA VI heat indicators.** Round dark-red badges with white glyphs under the stars: CCTV, couple, appearance, outfit, weapon, **vehicle**. Each one is cleared by an action; for example, a respray removes the vehicle badge. See `WantedLevel-GTAVI-HUD.jpg`.
- **This maps directly onto our car-heist loop.** The badges become "Car identified" (cleared at the spray shop) and "Seen on camera".

### 2.5 Cash, ammo and weapon

- **Cash.**
  - Pricedown, white, thin black outline, right-aligned top-right under the stars (gta.wiki Fonts: "Top Right: Money – Pricedown").
  - A change first shows as a separate line beneath: green `+$700` or red `-$5000` (see `GTAV_new_screen`: red `-5000`). Then the total updates.
  - In V the cash readout **hides** when idle and comes back on change or with the expand-radar key *(obs.)*.
  - GTA VI shows cash plus bank with round icon badges, still in a Pricedown-like heavy face (`…-TopRight.jpg`).
- **Ammo.** Total and clip in Pricedown (`9987 12` in the capture, white then grey).
- **Weapon icon.** Shown briefly on weapon switch.

### 2.6 Help text (top-left)

- A black box at about 73% opacity (`HUD_COLOUR_INGAME_BG rgba(0,0,0,186)`). White Chalet London text, about 22% of screen width, top-left in the safe zone.
- It carries **inline input glyphs** (`~INPUT_CONTEXT~` becomes a key cap) and coloured keywords.
- It appears with a soft beep, lasts several seconds or until the condition is met, and shows one at a time *(obs.)*.

### 2.7 Objective text and subtitles (bottom-centre)

- One or two lines, white, Chalet London, drop shadow, **no box**. In the reference, "Lose the cops." sits at ≈96% H. Text height is ≈1.6% H.
- Keyword colours, from Rockstar's own label conventions:

| Code | Colour | Meaning |
|---|---|---|
| `~r~` | `#E03232` | enemy characters and vehicles |
| `~b~` | `#5DB6E5` | friendly characters and vehicles (also "get in the car") |
| `~y~` | `#F0C850` | destination names |
| `~g~` | `#72CC72` | pickups |
| `~c~`, `~t~` | `#8C8C8C` | off-screen speaker or foreign speech |
| `~s~` | — | reset |

- Dialogue subtitles use the same slot.

### 2.8 Notification feed

- Cards stack upward from just above the radar. They are the same width as the radar or a bit wider.
- Background is translucent black, with no rounded corners.
- **Contact variant:** a square portrait, the sender name (bold condensed), a subject line in grey, then the body text. **Plain variant:** text only. See `GTAV_new_screen` (Michael card) and `Notification-GTAV-MartinWarning`.
- About 5–7 s each. New posts arrive with a "text message" blip *(obs.)*.

### 2.9 Location and vehicle names (bottom-right)

- In the script font (SignPainter), right-aligned, stacked:
  - the **vehicle name + class** (gta.wiki HUD: "Albany Cavalcade, SUVs");
  - the **district**;
  - the **street**.
- Fades in on entering a car or a new area, holds about 4–5 s, then fades out *(obs.)*.

### 2.10 Big messages ("shards")

Measured from the captures (`Wasted-GTAV-EnhancedVersion`, `Busted-GTAV`, `Wasted-GTAVe-MissionFailed`):

| Property | Wasted | Busted | Mission failed | Mission passed |
|---|---|---|---|---|
| Screen grade | grayscale and high contrast, vignette, slow motion | grayscale, slow | grayscale (if death) | normal colour |
| Band | full width, but a slight **keystone**: ≈15.5% of H at the left edge widening to ≈23% at the right (17.8% at x≈30% W; mean ≈**19.5%**), centre **48.8% H** (re-measured in verification on all three captures). Black ≈ **42–52% opacity** | same | same, slightly wider text | same (darker) |
| Title | lowercase Pricedown, **crimson**, measured `#8C1428`–`#B84850` in captures (HUD red `#E03232` is canonical) | lowercase, **blue**, measured ≈`#5890B0` (= `HUD_COLOUR_BLUE #5DB6E5`) | lowercase red | lowercase **yellow/gold** |
| Title size | text block ≈ **23% of W**, glyph height ≈ **9% of H** | same | ≈ 35% of W | — |
| Subtitle | mission name under the red word (Death wiki) | — | reason, e.g. "Michael died." in white Chalet ≈ 2% H | mission name, medal, objective checklist, cash |
| Camera | ~1 s live fall, then a slow tilted drift | camera holds on the arrest (hands up / kneel) | — | — |

- Timing *(obs.)*: the band and text fade in over ≈0.3–0.5 s, hold ≈3–5 s, then fade to black and respawn (hospital for wasted, police station for busted).
- Mission passed adds a short music sting.

### 2.11 Weapon wheel

- **GTA V.**
  - Hold to open. **Slow motion in single player** (removed by mods; none in Online).
  - 8 category slots clockwise from the top (see `WeaponWheel-GTAV.jpg`): handguns (top), SMG, rifle, sniper, melee/unarmed (bottom), shotgun, heavy, thrown.
  - A translucent ring with separators. Each slot shows a grey weapon line-art icon and `ammo / clip`.
  - The **selected slot fills white**, with an accent arc on its outer edge (the character colour).
  - The centre shows the weapon name and `< 1 / 5 >` for cycling within a category.
- **GTA VI** (official "An Extended Look", `WeaponWheel-GTAVI-AnExtendedLook.jpg`):
  - a **heavy gaussian blur** and darkening of the world;
  - **8 square cards** on a ring, dark translucent, with "+" for empty slots;
  - the selected card is light, with a white border and a pink glow strip;
  - a WEAPONS | ITEMS tab pair (selected: white slanted chip with black text);
  - the centre shows "UNARMED / SIDEARM" in a condensed font;
  - consumable cards with counts at bottom-left.
- **The VI card layout is easier to build in Roblox** (no curved segment art). Recommended.

### 2.12 Phone

- Bottom-right, slides up from below. It is a parody handset with a status row (signal, day, time, battery) and an app title bar tinted in the character colour.
- **3×3 glossy app grid**: Email, Texts, Contacts, Quick Job, Settings, Snapmatic camera, Internet …
- The selection is a coloured tile or frame. A soft-key bar at the bottom has a green "+" and a red back arrow (`Phone-GTAV-*.jpg`).
- The camera app has selfie mode and filters, and supports photo sharing.

### 2.13 Pause menu and map

From `PauseMenu-GTAVe.jpg` *(measurements)*:
- The world is blurred and tinted in the character colour.
- The title "Grand Theft Auto V" sits at 16% W, 13% H in a condensed face.
- Top-right: character name, `DAY HH:MM`, and cash in condensed type next to a portrait.
- A tab bar at 18.7% H: MAP, BRIEF, STATS, SETTINGS, GAME, ONLINE. Each tab is ≈3.6% H tall on black translucent. The **selected tab is white with black text** and a coloured top rule.
- The content area spans 16%–84% of width. The map uses near-black land and grey roads, with black-and-white icon blips. A legend appears on the right when browsing.
- Bottom-right: instructional buttons, each a label plus a white key cap ("Select ⏎", "Back Esc").

### 2.14 Interaction menu (list menus)

The "NativeUI" style used for the interaction menu, shops and garages (`GTAV_new_screen`, top-left):
- a header banner (art or a colour band with script title);
- a black subheader row with `TITLE … 1/4`;
- rows of white text on translucent grey-black, with the **selected row inverted to white bg / black text**;
- `< value >` selectors and right-aligned prices;
- a description box underneath.

### 2.15 Loading screens

- Full-bleed **painted illustrations** in the box-art style: heavy ink outlines, painterly cel shading, saturated sunset palette. The GTA VI key art is a grid of panels with thick dark-violet gutters (`Artwork-GTAVI-CoverArt-Landscape.jpg`).
- Slow pan and zoom with crossfades, a small spinner and label bottom-right, and tips. There is **no chunky progress bar** *(obs.)*.

### 2.16 Sound cues (GTA reference → our need)

All observed:

| Event | GTA character | We need |
|---|---|---|
| Wasted | low boom plus reverse whoosh, world audio muffled | deep impact plus reverse whoosh, low-pass on world SoundGroup |
| Busted | similar hit, radio chatter | hit plus police radio burst |
| Mission or job passed | short musical sting | 2–3 s sting (non-cartoon) |
| Help text | soft "bip" | short UI beep |
| Feed or text message | phone chime | 2-note chime |
| Phone open/close, app nav | soft slide and clicks | slide plus tick |
| Weapon wheel | whoosh in, muffled world, tick per slot | same |
| Cash change | quiet register tick | quiet tick (never a coin shower) |
| Wanted up | sirens and dispatcher radio, no UI jingle | radio burst |
| Wanted cleared | stars fade; dispatcher "suspect lost" | radio "lost" line plus soft tone |
| Pause menu | frontend hum and nav clicks | frontend click set |

### 2.17 Camera language

*(obs.; no official numbers exist, see the camera mod notes on gta5-mods)*

- **On foot.**
  - A third-person follow cam about 3–4 m behind, pivot at the upper chest, slight right-shoulder offset.
  - Collision-aware, with smooth recentering. Three distances.
- **Aiming.**
  - The camera moves tight over the right shoulder, the FOV narrows, and a small white dot reticle turns red on hostiles.
  - Shoulder swap is available.
- **Vehicle chase cam.**
  - Behind and above the car. The yaw follows the car's heading with spring lag, so you see the car's flank in turns.
  - Looks slightly ahead, never rolls with the car, and recentres after free-look.
  - The FOV widens with speed. Near, mid and far distances plus hood and first-person; look-behind.
  - Mods confirm speed-dependent distance behaviour (Custom Camera V Plus).
- **Cinematic cam (hold in vehicle).**
  - Cuts between external tracking and fixed shots with letterbox.
  - Slow motion in single player.
- **Death cam.** A short live follow, then a slow detached drift and tilt (see §2.10).

### 2.18 GTA VI trailer look

The look, from the official key art and trailer stills on gta.wiki:
- warm, saturated "Miami sunset" grading: dusk violet → rose → peach → amber;
- teal water;
- deep, contrasty shadows;
- strong bloom on neon and specular sun;
- humid haze at the horizon;
- night scenes in magenta and cyan neon with wet reflections.

The announcement art samples, top to bottom: `#6F65A1` → `#A47DA4` → `#CD85A6` → `#EA9699` → `#FDAC89` → `#FEB374`. The palm silhouettes are `#663C64`.

In the HUD, VI moves to softer pastels (pink, mint, lavender) and keeps Pricedown-like numerals, condensed caps and dark translucent cards.

**How we use it:**
- The VI gradient informs **world grading and key art only**.
- Our HUD stays V-restrained, because the kill list bans pastel-pink UI.

---

## 3. Palette (Theme.Colors v2)

Alpha is converted to Roblox `BackgroundTransparency` as `1 − a/255`.

| Token | Hex | Transparency | Use | Source |
|---|---|---|---|---|
| `Text` | `#F0F0F0` | 0 | all HUD text | HUD_COLOUR_WHITE (1) |
| `TextPure` | `#FFFFFF` | 0 | selected-row bg, key caps | PURE_WHITE (0) |
| `TextDim` | `#9B9B9B` | 0 | ammo reserve, secondary text | GREY (3) |
| `TextMuted` | `#8C8C8C` | 0 | menu standard, off-screen speaker | MENU_GREY (67) |
| `TextDisabled` | `#4D4D4D` | 0 | locked rows | GREYDARK (5) |
| `Outline` | `#000000` | 0–0.5 | text outline and shadow | BLACK (2) |
| `Panel` | `#000000` | **0.27** | help box, feed, rows, timer bars | INGAME_BG (140) `rgba(0,0,0,186)` |
| `PanelLight` | `#000000` | 0.70 | subtle backers | PANEL_LIGHT (152) `rgba(0,0,0,77)` |
| `PauseTint` | `#000000` | 0.16 | full map backdrop | PAUSEMAP_TINT (157) `rgba(0,0,0,215)` |
| `MenuHighlight` | `#1E1E1E` | 0 | list header row | MENU_HIGHLIGHT (69) |
| `MenuDark` | `#3C3C3C` | 0 | separators, empty bar tracks | MENU_GREY_DARK (68) |
| `Red` | `#E03232` | 0 | enemies, wanted, −cash, fail | RED (6) |
| `RedDark` | `#701919` | 0 | red tracks, heat badge bg | REDDARK (8) |
| `Damage` | `#EB2427` | 0 | low-health pulse | RADAR_DAMAGE (27) |
| `Blue` | `#5DB6E5` | 0 | friendlies, own car, armour, busted | BLUE (9) = RADAR_ARMOUR, FRIENDLY |
| `BlueDark` | `#2F5C73` | 0 | armour track | BLUEDARK (11) |
| `Yellow` | `#F0C850` | 0 | destinations, objective route, passed | YELLOW (12) = LOCATION, OBJECTIVE_ROUTE |
| `YellowDark` | `#7E6B29` | 0 | ability track | YELLOWDARK (14) |
| `Green` | `#72CC72` | 0 | pickups, +cash | GREEN (18) = PICKUP |
| `Health` | `#359A47` | 0 | health segment | RADAR_HEALTH (25) |
| `HealthTrack` | `#1B4D24` | 0 | health track (derived ×0.5) | — |
| `Waypoint` | `#A44CF2` | 0 | player waypoint and route | WAYPOINT (142) |
| `WaypointLight` / `WaypointDark` | `#D2A6F9` / `#522679` | 0 | hover, route outline | (150) / (151) |
| `Orange` | `#FF8555` | 0 | team or warn | ORANGE (15) |
| `Purple` | `#8466E2` | 0 | team or epic rarity | PURPLE (21) |
| `Gold` / `Silver` / `Bronze` / `Platinum` | `#D6B563` / `#9699A1` / `#B48261` / `#A6DDBE` | 0 | medals, VIP tag, legendary rarity | (109) (108) (107) (110) |
| `Freemode` / `FreemodeDark` | `#2D6EB9` / `#16375C` | 0 | multiplayer accents (crew, other players) | (116) (123) |
| `BlipDefault` | `#9FC9A6` | 0 | generic POI blips | SIMPLEBLIP_DEFAULT (60) |
| `WastedRed` | `#B3212F` | 0 | big-message wasted (measured crimson) | capture measurement |
| **`Accent`** | **`#FF8A3D`** | 0 | **our "character colour"**: selected tab rule, weapon-card strip, phone header, focus | brand (new) |
| `AccentDark` | `#7A3A12` | 0 | accent track | brand (new) |

**Map tile palette** (for the tile renderer):

| Element | Hex |
|---|---|
| land | `#1C1C1E` |
| block or building footprint | `#26272A` |
| street | `#8C8C8C` |
| arterial | `#9C9C9C` |
| freeway | `#B0B0B0` |
| water | `#1F3445` |
| park or golf | `#2F4A33` |
| beach | `#6B6250` |

Land and roads are measured from the pause map. The other values are derived and need a Studio check.

**Rarity** (keeps the `original_brief.md` tiers in GTA hues; shown as a small coloured label or underline, **never** as glowing frames):

| Tier | Colour | Token |
|---|---|---|
| Common | `#9B9B9B` | |
| Uncommon | `#72CC72` | |
| Rare | `#5DB6E5` | |
| Epic | `#8466E2` | |
| Legendary | `#D6B563` | |
| Mythic | `#E03232` | |
| Secret | `#F0F0F0` | Platinum `#A6DDBE` underline |

**Brand gradient** (loading, key art and logo only, never HUD fills): `#3A2E6E` → `#A45C8E` → `#F2956E` → `#FFC27A`. This is our own, inspired by the VI art samples in §2.18.

**Deleted v1 colours:**
- Primary hot pink `255,52,140`;
- Secondary cyan `0,214,255`;
- navy panels `18,20,38` / `28,31,58` / `42,46,84`;
- Cash neon `70,235,110`;
- the STAR_EMPTY navy.

---

## 4. Typography (Theme.Fonts v2)

All fonts were verified to exist in 2026:
- **Built-in** families are listed in the Font datatype docs.
- **Store** families are Roblox-owned assets of type 73. Their weights were read from the family JSON via assetdelivery.

Side-by-side renders are in `img_gta/font_compare_bigmessage.jpg`, `font_compare_digits.jpg`, `font_compare_body.jpg`, `font_compare_display_caps.jpg` and `roblox_builtin_font_weights.jpg`.

| Role | GTA V font | Roblox choice | Constructor | Weight | Size @1280×720 canvas | Case and treatment |
|---|---|---|---|---|---|---|
| Big messages (wasted, busted, passed, failed) | Pricedown | **Kanit** (Store `12187373592`, weights 100–900 + italics) | `Font.fromId(12187373592, Enum.FontWeight.Heavy)` | 900 | ≈ 0.128 H, so **92** (TextScaled with max) | **lowercase**, no stroke, sits on band |
| Cash, ammo, timers, speed digits | Pricedown | **Kanit** | same | 900 | cash **30**, delta **24**, ammo **26**, timer **24** | UIStroke Contextual, black, **2 px** |
| Menu titles, tabs, list headers, labels, phone header | Chalet Comprime Cologne | **Oswald** (built-in, ExtraLight–Bold) | `Font.new("rbxasset://fonts/families/Oswald.json", Enum.FontWeight.SemiBold)` | 600 (Medium 500 for labels) | title 34, tab 16, header 15, label 13 | **UPPERCASE** for tabs, headers and timer labels |
| Help text, subtitles, objectives, feed body, menu rows, phone body | Chalet London 1960 | **Montserrat** (built-in, Thin–Black + italics; Roblox's Gotham replacement) | `Font.new("rbxasset://fonts/families/Montserrat.json", Enum.FontWeight.Medium)` | 500 (Regular 400 for long text) | help 16, objective/subtitle 18, feed 13, rows 15 | Sentence case. Subtitles get UIStroke 1 px black at 0.5 transparency (drop-shadow stand-in) |
| Vehicle, district and street names; credits; signatures | SignPainter House Script | **Damion** (Store `12187607722`, 400) | `Font.fromId(12187607722)` | 400 | 26 | Title Case, UIStroke 1 px at 0.6 |
| Display fallback (store font not loaded or blocked) | — | **Sarpanch** (built-in, Regular–Black) | `Font.new("rbxasset://fonts/families/Sarpanch.json", Enum.FontWeight.Heavy)` | 900 | — | uppercase looks closest to Pricedown caps |
| Mono (debug, phone clock alternative) | — | RobotoMono | built-in | 500 | — | — |

**Candidates rejected:**
- Bangers: comic italic.
- LuckiestGuy, FredokaOne, Creepster, PermanentMarker, Cartoon: kid or novelty fonts.
- Michroma, Zekton: sci-fi.
- Rubik Black: too rounded and friendly.
- Sarpanch for lowercase: too wide.
- Antonio, Teko: fine condensed faces, but redundant with Oswald.
- Inter (Store `12187365364`): good, but Montserrat matches Chalet's width better and is built-in.
- Yellowtail (Store `12187373881`): leans further than SignPainter.

**Rules:**
- **Preload the store fonts in the loading screen** (hidden TextLabels with each `FontFace` and `ContentProvider:PreloadAsync`), so there is no fallback flash.
- Use `TextService:GetTextBoundsAsync` (it takes `FontFace`) instead of `GetTextSize(…, Enum.Font.FredokaOne)`.
- **No text stroke** on body text, **no gradients on text**, **no emoji anywhere**. Icons are images.
- For inline key caps in help text, use RichText `<mark color="#F0F0F0" transparency="0"><font color="#000000"> E </font></mark>`. `<mark>` is supported and is the cheapest GTA key-cap look.

---

## 5. Roblox implementation spec, element by element

### 5.0 Global frame

- **Design canvas.** Keep `Kit.screen`'s 1280×720 UIScale, which is `min(vpX/1280, vpY/720)`. Every GTA fraction below is converted to that canvas. Anchor all elements to corners.
- **Insets.**
  - HUD ScreenGuis: `ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets`. This guarantees no overlap with the 58 px top bar and device notches.
  - Full-screen layers (big message, blur tint, letterbox, fade, loading): `ScreenInsets = None` plus `IgnoreGuiInset = true`.
- **Safe margin.** `SAFE = 20` design px, about 1.6% W and 2.8% H. GTA's default is about 1–5%.
- **ScreenGuis and DisplayOrder.**

| ScreenGui | DisplayOrder |
|---|---|
| `HC_HUD` (minimap, bars, stars, cash, ammo, help, objective, location, timers) | 10 |
| `HC_Feed` | 11 |
| `HC_Phone` | 25 |
| `HC_Wheel` | 35 |
| `HC_Pause` | 45 |
| `HC_Shard` | 50 |
| `HC_Fade` | 60 |
| Loading screen | 1000 (exists) |

- **Motion.**
  - Only fades and short slides: `TweenInfo.new(0.2–0.35, Enum.EasingStyle.Quad or Sine, Out)`.
  - **No Back or Elastic easing, no wiggle, no shake on UI, no scale-pop above 1.15.**
  - Stars may use 1.25→1.0 over 0.15 s when gained.
- **Performance.**
  - At most one CanvasGroup (the minimap). Docs: extra texture memory; it renders blank when over the cap.
  - Pool blips and feed cards. The minimap updates at 30 Hz and blips at 10 Hz.
  - No `Instance.new` per frame.

### 5.1 Minimap (`HUD/Minimap`)

- **Geometry.** Bottom-left at `(SAFE, H − SAFE − 14 − 136)`, size **192×136**, which is 0.15 W × 0.189 H at 16:9. On other aspects use width = 0.2667 H.
- **Hierarchy.**
  ```
  Minimap (Frame, no bg)
  ├─ Clip (CanvasGroup 192×136, BackgroundColor #1C1C1E)
  │   └─ Pivot (Frame 0×0 at (0.5, 0.60))          ← rotation = −cameraYaw (deg)
  │        └─ World (Frame sized mapStuds*pxPerStud, positioned so the player's world XZ sits at Pivot)
  │             ├─ Tiles (ImageLabel grid, 1024² tiles, ScaleType Stretch)
  │             ├─ Route (Folder of 4 px Frames, AnchorPoint .5,.5, Rotation = segment angle)
  │             ├─ Cones (ImageLabels, wedge sprite, ImageColor3 Blue, ImageTransparency 0.55)
  │             └─ Blips (pooled ImageLabels, sprite sheet; counter-rotated so icons stay upright)
  ├─ PlayerArrow (ImageLabel 14×14 at (0.5, 0.60), rotation = characterYaw − cameraYaw)
  ├─ North (ImageLabel 18×18 black disc "N", placed on the clip edge at the north bearing)
  ├─ Flash (Frame 196×140 behind Clip, UIStroke 2 px) ← red/blue alternating 4 Hz while police can see you
  └─ Bars (Frame 192×6, y = +4 below)
  ```
  *(Corrected in verification.)* Since the 2026 rollout, `ClipsDescendants` clips rotated descendants (`StarterGui.ClipsDescendantsSupportsRotation`, default Enabled; the property is removed on 2026-11-03). Only a *rotated or rounded clipping parent* still needs a CanvasGroup. For V's square, unrotated radar, a plain `Frame` with `ClipsDescendants = true` is enough. It avoids CanvasGroup's extra texture memory and its blank-texture failure on low-end devices. Keep the CanvasGroup only if the radar stays rounded (GTA VI style). Note that CanvasGroup flattening also requires `ZIndexBehavior.Sibling`, which `Kit.screen` already sets.
- **Zoom.** `pxPerStud = lerp(0.9, 0.35, clamp(speed/120, 0, 1))` (tuning), smoothed. Interiors and the garage use a fixed close zoom.
- **Edge clamping.** Objective, waypoint and home blips clamp to the clip rectangle edge when out of range (GTA behaviour). Other blips are culled.
- **Height variant.** If `|Δy| > 8 studs`, swap to the `_up` or `_down` sprite.
- **Expanded radar.** Toggle on `Z` or D-pad down: 2× size, for 6 s or while held. It also reveals cash.
- **Tiles.** Render the v2 city top-down **from map data**, not screenshots. Use the road graph plus building footprints, the §3 palette, and anti-aliasing, with a Python/PIL or Blender orthographic pass. Export 1024×1024 PNG tiles; the texture docs allow up to 4096, but 1024 tiles stream and scale better. Upload, and record the IDs in `Config/Assets`. The same tiles feed the pause map.
- **GPS.**
  - Run A* on the road-node graph, server or shared. Recompute on a waypoint or objective change, when off-route by more than 25 studs, or every 2 s.
  - Draw at most about 60 segments. Colour = target blip colour: Yellow for an objective, Waypoint purple for the player pin, Red for "your car is being stolen".
- **Police cones.** While `Wanted > 0` and not seen: per cop within 400 studs, a 60° wedge sprite rotated to the cop's look vector, alpha 0.45.
- **Red/blue flash.** While `WantedSeen == true`, alternate the stroke colour Red ↔ Blue every 0.25 s. It is off when unseen. Search mode is shown by the cones plus flashing stars.

### 5.2 Health, armour and ability bars

- **Geometry.** Three Frames inside `Bars`, widths `0.5 / 0.25 / 0.25` minus 2 px gaps, height 6, no corners.
- **Each segment.** A track Frame (same hue, darkened: HealthTrack, BlueDark, YellowDark) plus a fill Frame sized by fraction. Tween the size over 0.2 s.
- **Health.** `Health #359A47`. Below 25% the fill becomes `Damage #EB2427` and pulses its BackgroundTransparency 0↔0.4 at 1.5 Hz.
- **Armour.** `Blue #5DB6E5` (new v2 armour stat from the combat work).
- **Third slot.** **Nitro** while driving and **sprint stamina** on foot, in `Yellow #F0C850`. This replaces DrivingUI's separate nitro bar.

### 5.3 Wanted stars (top-right)

- **Geometry.** 5 ImageLabels, **22×22**, pitch 25, right-aligned at `(W − SAFE, SAFE + 4)`.
- **Sprites:** `star_fill` (white glyph with a 2 px dark outline baked in) and `star_hollow` (outline only).
- **States** (driven by the `Wanted` and `WantedSeen` attributes):

| State | Visual |
|---|---|
| 0 stars | whole row hidden (fade 0.4 s) |
| wanted + seen | filled = `star_fill` ImageColor3 `#F0F0F0`; unfilled = `star_hollow` at ImageTransparency 0.3 |
| wanted + unseen (search) | filled stars alternate `#F0F0F0` ↔ `#9B9B9B` every **0.35 s** |
| *(optional, VI)* lost but inside search radius | filled stars `Red #E03232` |
| *(optional, VI)* reported, police not yet arrived | filled stars solid grey `#9B9B9B` |

- **Gain.** The new star goes UIScale 1.25→1 over 0.15 s with a white flash, plus a dispatcher radio sound.
- **Clear.** Stars blink 3× and fade, plus a feed post "Wanted level cleared".
- **Heat badges** *(GTA VI pattern, recommended for our loop).* A row of 18×18 round badges under the stars: bg `RedDark #701919`, white glyph.
  - `CAR` = "vehicle identified", cleared by the spray shop or by switching cars;
  - `CAM` = "seen on CCTV";
  - `FACE` = "appearance known", cleared by an outfit change.
- **Arrest progress.** Replaces "🚔 GETTING BUSTED!": a 120×4 bar under the stars in `Blue`, with an Oswald 12 label "BEING ARRESTED" above it, visible only while `BustProgress > 0`.

### 5.4 Cash, delta and ammo (top-right, under the stars)

- **Cash.**
  - TextLabel, Kanit Heavy **30**, `Text`, right-aligned, UIStroke Contextual black 2 px. Format `$15,150` with commas, not K/M on the HUD; K/M stays in menus.
  - Position `(W − SAFE, 32)`.
  - **Visibility.** Shown 8 s after any change, while the expanded radar is held, and while the pause menu, phone or a shop is open. Setting "Always show cash" defaults to **ON** (retention needs it; this is a deliberate deviation from GTA, flagged for the lead).
- **Delta.** A second TextLabel below, Kanit 24: `+$700` in `Green` or `-$5,000` in `Red`. Hold 1.0 s, then fade while the main number counts up over 0.5 s (`Kit.tweenNumber` stays). Multiple gains within 1 s merge.
- **Ammo.** `12  48`, clip in `Text` and reserve in `TextDim`, Kanit 26, under the cash. Only while a gun is equipped.
- **Weapon icon.** On switch, the weapon silhouette (96×40) appears under the ammo for 2 s.

### 5.5 Help text (top-left)

- **Geometry.** Frame `Panel` (black, transparency 0.27), no corner or stroke. Position `(SAFE, SAFE)` inside CoreUISafeInsets, so it sits under the top bar. Width **300**, AutomaticSize Y, padding 10/12.
- **Text.** TextLabel Montserrat Medium 16, `Text`, `RichText=true`, `TextWrapped`, LineHeight 1.1.
- **Inline keys.** `Kit.key("E")` returns the `<mark>` key-cap string. On gamepad use `UserInputService:GetStringForKeyCode` for the label, or `GetImageForKeyCode` for an image row variant. On touch, write the button name ("tap HOTWIRE").
- **Behaviour.** One at a time, with a FIFO queue and de-duplication. Fade in 0.2 s plus a short beep. Lasts until `clear(id)` or `duration` (default 8 s). Fade out 0.3 s.

### 5.6 Objective line and subtitles (bottom-centre)

- **Geometry.** TextLabel, AnchorPoint (0.5, 1), position `(0.5, H − 34)`. Max width 0.6 W, 1–2 lines.
- **Text.** Montserrat Medium **18**, `Text`, UIStroke 1 px black at 0.5. RichText colours from the §2.7 table.
- **API.** `Objective.set("Take the car to your <y>garage</y>.")`, which maps tags to `<font color>`. Hold 7 s, fade 0.3 s, and re-show on a key press or on a new objective. Dialogue subtitles share the slot. The latest one wins; the objective returns after dialogue.

### 5.7 Feed (above the minimap)

- **Container.** Anchored bottom-left at `(SAFE, minimapTop − 6)`, width **220**, with UIListLayout Vertical, VerticalAlignment Bottom, padding 4.
- **Card.** `Panel` bg, no corner.
  - **Contact card:** portrait 40×40 ImageLabel (a pre-rendered headshot or a ViewportFrame), name Oswald SemiBold 15 `Text`, subject Montserrat 12 `TextDim`, body Montserrat 13 `Text` (wrapped, at most 3 lines).
  - **Plain card:** body only.
  - **Merge.** Repeats merge with a grey `(x3)` suffix.
- **Motion.** Enter: position x −12→0 plus a fade over 0.2 s, plus a chime. Life 6 s, exit fade 0.3 s. At most 4 visible; the oldest leaves first.
- **Routing.** Everything that was a toast, kill-feed line, "announce" or offline modal in v1 routes here, unless it qualifies for a shard (§5.9).

### 5.8 Location and vehicle names (bottom-right)

- Three right-aligned TextLabels, Damion 26 `Text`, UIStroke 1 px at 0.6, stacked from `(W − SAFE, H − SAFE − 96)`:
  - `Vehicle, Class` (on entering a car);
  - `District` (on a zone change);
  - `Street` (on a road change, throttled).
- Fade in 0.3 s, hold 4.5 s, fade 0.6 s.
- **GTA Online timer bars** (for the delivery timer, §9) stack **above** this block.

### 5.9 Big message shard (`HC_Shard`)

- **Band.** Frame full width, AnchorPoint (0.5, 0.5), position (0.5, 0.488), Size Y `0.195` scale, black. For the exact GTA keystone, use instead a full-width ImageLabel with a trapezoid alpha sprite, 0.155 H on the left and 0.23 H on the right.
  - BackgroundTransparency **≈0.5** for wasted, busted and failed (re-measured at 0.48–0.58).
  - **0.45** for passed and delivered.
- **Title.** TextLabel lowercase, Kanit Heavy, `TextScaled` with UITextSizeConstraint MaxTextSize 110. Size (0.5, 0.62 of band). No stroke.
- **Subtitle.** Montserrat Medium 18 `Text`, centred under the title, inside the band.
- **Rows** (passed only). A VerticalList under the band. Each row has an Oswald label left (`TextDim`, uppercase) and a Kanit value right (`Text`). Rows reveal 0.15 s apart with a tick sound, then a TOTAL row in `Yellow`.
- **Animation.**
  - Band Size Y 0→target over 0.25 s Quad Out.
  - Title TextTransparency 1→0 plus UIScale 1.12→1.0 over 0.35 s Quad Out.
  - Hold.
  - Out: everything fades over 0.45 s, or a `HC_Fade` black fade for death and arrest.
- **Variants:**

| Variant | Title | Colour | Grade | Subtitle and extras |
|---|---|---|---|---|
| wasted | `wasted` | `WastedRed #B3212F` | grayscale | "Hospital bill  −$X" |
| busted | `busted` | `Blue #5DB6E5` | grayscale | "Bail −$X · <Car> impounded" |
| delivered / job complete | `delivered` / `job complete` | `Yellow` | none | car name, rows: payout, condition, heat bonus, total |
| failed | `failed` | `Red #E03232` | grayscale if death, else none | reason |
| rare reveal (brief's "slot-machine") | `legendary` etc. | rarity colour | none | "1 in 12,000" in Montserrat. Paired with a 3 s **cinematic orbit** of the car (§5.17), not confetti |

- **Death and arrest sequence** (client; `HC_Shard` plus effects parented to **`workspace.CurrentCamera`**, so they are local-only):

  | Time | Wasted | Busted |
  |---|---|---|
  | t=0 | death; camera keeps following the ragdoll | hands-up / kneel anim |
  | t=1.0 | `ColorCorrectionEffect` "HC_DeathGrade": Saturation 0→**−1**, Contrast 0→**0.3**, Brightness 0→−0.05 over 0.6 s. `BlurEffect` Size 0→3. Vignette ImageLabel fades in. Camera goes Scriptable: slow dolly up and back (≈2 studs/s), 6° dutch tilt, FOV −10 over 5 s. World SoundGroup gets an EqualizerSoundEffect (HighGain −25, MidGain −10). SFX: deep impact plus reverse whoosh | camera locks on a 3/4 shot of player and officer. Same grade and audio |
  | t=1.2 | shard in | shard in |
  | t≈5.5 | `HC_Fade` black over 0.6 s; server respawns | same |
  | after respawn | fade in 0.6 s; remove the grade; feed "Treated at <Hospital>. Bill −$X" | feed "Released from <Station>. Bail −$X", plus "Vehicle impounded" if relevant |

### 5.10 Weapon wheel (`HC_Wheel`)

GTA VI card layout.
- **Open.** Hold `Tab` (PC), `ButtonL1` (pad), or tap the weapon icon (touch, toggle).
- **Blocking.** Use `ContextActionService:BindActionAtPriority` to block camera and fire while open. The world keeps running (multiplayer). GTA V's single-player slow motion is not possible or fair here.
- **Backdrop.**
  - `BlurEffect` on the camera, Size 0→**16** over 0.15 s.
  - ColorCorrection Saturation −0.3, Brightness −0.08.
  - World SoundGroup muffled as in §5.9 (lighter: HighGain −12).
- **Cards.** 8 Frames of **128×84** on a circle of radius **190** around the screen centre, at 45° steps, starting at the top.
  - Bg `#141414` at 0.35, plus UIStroke 1 px `#F0F0F0` at 0.85.
  - Icon ImageLabel (weapon silhouette, `Text`) and ammo `12 / 48` Kanit 16.
  - Empty slot: a "+" in `TextDim`.
- **Selected card.**
  - Bg `#F0F0F0` at 0.1, icon ImageColor3 black.
  - UIStroke 2 px white, plus a 3 px **Accent** strip on its top edge.
  - Swap over 0.08 s.
- **Selection.** Mouse delta or right-stick angle `atan2`, with a dead zone of 40 px. On touch, tap a card.
- **Centre.** Weapon name Oswald SemiBold 26 uppercase, category Oswald 15 `TextDim`, `<  1 / 3  >` cycling with `Q`/`E` or the mouse wheel.
- **Release.** Equips via our server-validated `EquipWeapon` remote. The Backpack CoreGui stays disabled.
- **Slot map (clockwise from the top):**

| Slot | Contents |
|---|---|
| Top | Pistols |
| Top-right | SMGs |
| Right | Rifles |
| Bottom-right | Shotguns |
| Bottom | Unarmed / melee (fists, bat, knife) |
| Bottom-left | Tools (taser, spike strip) |
| Left | reserved (thrown, if ever added) |
| Top-left | reserved (special / heist gear) |

### 5.11 Phone (`HC_Phone`)

- **Shell.** 9-slice ImageLabel (our own parody handset art), AnchorPoint (1, 1), position `(W − 36, H + 0)`, size **176×330**. It slides up to `H − 16` over 0.25 s Quint Out, and down on close.
- **Open.** D-pad up (pad) or the phone button (touch). On PC, GTA's `↑` is a problem: Roblox's default PlayerModule binds `↑` to move forward, which is why the corrected spec drops it. Use a free key, for example `B`, and confirm it in Studio.
- **Screen** (inner Frame, CanvasGroup **not** needed):
  - status row Oswald 12 (signal, `ddd HH:MM` from `Lighting.ClockTime`, battery);
  - title bar `Accent` bg, Oswald SemiBold 16, black text;
  - **3×3 UIGridLayout** of app tiles 48×48 with Oswald 10 captions;
  - selection = an `Accent` rounded square (the one place a 6 px UICorner is allowed);
  - soft-key bar: green "select" glyph, red "back" glyph.
- **Apps** (replacing the v1 left menu column, each its own screen inside the phone):

| App | Contents |
|---|---|
| Contacts | services: Mechanic (deliver an owned car to you), Lawyer (lose stars for $, a Robux product slot), Fence (job hints), Crew |
| Messages | job texts, theft alerts, daily rewards |
| Jobs | contracts, chop-shop order board, daily objectives |
| Garage | owned cars, values, set GPS home |
| Map | quick GPS to POIs |
| Internet | the Store: "Legendary Motorsport"-style parody site → Robux products |
| Camera | photo mode → `CaptureService:CaptureScreenshot` + share |
| Settings | |
| Codes | |

- **Badges.** Unread counts are small `Red` circles with Kanit digits on app tiles and on a mini phone icon by the minimap. This replaces the v1 red "!" badges.
- **Sounds.** Slide, tick, select, back. Incoming text: chime plus vibrate.

### 5.12 Pause menu and full map (`HC_Pause`)

- **Open.** `P` or `M` (Map tab directly). `Esc` belongs to Roblox and cannot be taken.
- **Backdrop.**
  - Camera `BlurEffect` Size 24.
  - Full-screen Frame `#000000` at 0.25 plus an `Accent`-tinted UIGradient at 0.85 transparency (GTA's character tint).
  - The HUD is hidden.
- **Header.**
  - "HOTWIRE CITY" in Oswald SemiBold 34 `Text` at (16% W, 13% H).
  - Top-right: player name, day and time, cash in Oswald Medium 15, plus an avatar headshot via `Players:GetUserThumbnailAsync`.
- **Tabs.**
  - A row at 18.7% H, each tab 0.11 W × 26, bg black at 0.3, Oswald Medium 15 uppercase `Text`.
  - The **selected tab** has a `TextPure` bg, black text and a 3 px `Accent` top rule.
  - Tabs: **MAP · JOBS · GARAGE · STATS · STORE · SETTINGS**.
  - `Q`/`E` or the bumpers switch tabs.
- **Content.** 16%–84% W, 22%–82% H.
- **MAP tab.** The same tiles at large scale, with drag to pan and wheel or pinch to zoom.
  - Right-click or tap places the **purple waypoint**, which syncs to the minimap route.
  - A legend list on the right: Oswald 13 rows with blip icons.
- **Footer.** Instructional buttons bottom-right, each a key cap plus a Montserrat 14 label: `Select ⏎ · Back Esc/Backspace · Waypoint RMB · Zoom Wheel`.

### 5.13 Interaction list menu (shops, garage, dealership, spray, gear)

- **Container.** Top-left at `(SAFE, SAFE)`, width **300**.
- **Header.** 300×64 ImageLabel (shop art, or `Accent` band plus Damion 34 title).
- **Subheader.** `MenuHighlight` 300×24: Oswald 13 uppercase left, `3/12` right.
- **Rows.** 300×28 each: bg black at 0.35, Montserrat Medium 14 `Text` label left, value or price right (Kanit 15).
  - Selected row: bg `TextPure`, text black.
  - Locked row: `TextDisabled` plus a lock icon.
  - `< value >` selectors for colours and options.
- **Description box** under the list: `Panel`, Montserrat 13, at most 3 lines.
- **Input.** Arrows, W/S and the mouse wheel move; Enter selects; Backspace goes back. On touch, rows are 36 px tall.
- **Preview.** Uses the existing ViewportFrame or the world camera; the garage and dealership cameras keep `MenuController.cameraCFrame`.

### 5.14 Loading screen (`src/first/LoadingScreen.client.luau`)

- **Art.** Full-bleed ImageLabel (ScaleType Crop) cycling **6–8 illustrated panels**:
  - our own characters, cars and city;
  - painterly ink-outline style;
  - brand-gradient skies.
  - Commission or produce them through the art pipeline. Do not trace GTA art. No Higgsfield spend from this task.
- **Motion.** Ken Burns: UIScale 1.0→1.06 plus a position drift of 1.5% over 9 s. Crossfade 0.8 s.
- **Bottom-left.** The Hotwire City wordmark (an image asset), plus a tip line: "TIP" Oswald 14 `Accent`, then Montserrat 15 `Text`.
- **Bottom-right.** A spinner ring image at 1 rev/s, plus "LOADING" Oswald 13.
- **Progress.** At most a thin 2 px bar along the very bottom, or none.
- **Preload.** Preload the Kanit and Damion fonts and the HUD sprite sheets here.

### 5.15 Retention mechanics in GTA language

These come from `original_brief.md`.

| Brief item | v1 presentation | v2 presentation |
|---|---|---|
| Floating "+$" numbers | world BillboardGui pops | HUD cash delta (§5.4). In-world, at most a small Montserrat "+$X" at the garage collect pad |
| Currency pill with "+" | top-centre glossy pill | top-right Kanit cash. The "+" lives in Phone → Internet and Pause → STORE |
| Left vertical button stack | 7 emoji tiles plus CODES/SETTINGS | Phone apps plus Pause tabs |
| Red "!" badges | pulsing circles | red unread counts on phone apps and the mini phone icon |
| Playtime gift ladder | GIFTS menu tiles | text from "Bonus" contact plus feed: "Playtime bonus ready: +$X (Phone › Messages)". Claim in the Messages thread |
| 7-day calendar / daily | DAILY window | Pause › JOBS › Daily Objectives (GTA Online pattern) plus a morning text |
| Offline earnings | modal with god rays, COLLECT, coin burst | on join: email "Garage income while you were away: $X", feed card, cash delta. Optional 2× via the email button |
| Rebirth | REBIRTH window | Pause › STATS › **Reputation / Prestige** (needs a product rename; flag for the lead) |
| Codes | CODES window | Phone › Settings › Codes |
| Server announcements / rare drops | center banner with shine | feed card plus phone text. Only legendary and up get a shard plus cinematic |
| Rarity colours | glowing frames | §3 rarity hues as small labels and underlines |
| Touch targets 8–10% H | — | kept for all touch buttons (§7) |

### 5.16 Sound mapping

| Event | Roblox candidate assets |
|---|---|
| wasted | `9120704346` + `9125404320` |
| busted | `9125404320` + radio (none yet; see below) |
| delivered / passed | `1840078221` (8 s; trim with `PlaybackRegion`) |
| help beep | `139804904213958` (a 1 s click) |
| feed / text | — |
| photo | `9113678227` |
| dispatcher | none yet (`9112851363` is not a police dispatcher; see below) |

- The candidates were found on the Creator Store via `toolbox-service/v1/marketplace/3`. Four are licensed ProSoundEffects or APM audio; `139804904213958` and `538449705` are free public user uploads. **Audition all of them in Studio.** Re-checked in verification:
  - `9120704346` is *"Whoosh Deep Booming Blast Reversed At Tail 1"* (ProSoundEffects, 3 s).
  - `9125404320` is *"Boom Impact Deep Distant Thumping Hits"* (ProSoundEffects, 3 s).
  - `9112851363` is *"Radio Light Chatter 1"* (ProSoundEffects). It is a **56 s loop of landing-craft interior radio with engine whine**, a poor match for a police dispatcher; keep looking.
  - `1840078221` is *"Building Success (sting)"* (APMOfficial, 8 s).
  - `139804904213958` is *"ui_menu_click_03"* (Vicktor2012, a user upload, 1 s).
  - `9113678227` is *"Camera Shutter 1"* (ProSoundEffects, 1 s).
- No feed or text chime was found yet. Phone vibrate candidate: `538449705` (miamipaid, 2 s). `120446204561335` was **removed**: it is a 3 min 53 s pop song ("Phone Vibrates" by Stevie Horn, DistrokidOfficial), not a sound effect.
- Put the world SFX in a `World` SoundGroup and the UI in a `UI` SoundGroup, so the muffle effects never touch UI sounds.

### 5.17 Camera spec

These are tuning starting points for a new `CameraController`. It runs at `RenderPriority.Camera + 1` and uses raycast collision with an exclude list (character, current car, glass).

| Mode | Distance | Height | Shoulder | FOV (vertical) | Lag / spring | Notes |
|---|---|---|---|---|---|---|
| On foot | 11–13 studs (3 distances: 9 / 12 / 16) | pivot at HRP +2.4 | +1.2 studs right | **60** | position spring ω≈12; yaw from the mouse, no lag | Roblox default 70 is too wide and "kid-game" |
| Aim | 6 | +2.2 | +2.4 right (swap with `V`) | **45** | ω≈20 | white 4 px dot reticle, turns `Red` over a hostile |
| Vehicle chase | **2.4 × car length** (≈ 22–28 studs) | **0.35 × distance** | 0 | **62 → 76** with speed (keep VehicleClient's FOV kick but rebase) | yaw follows heading with a critically damped spring ω≈3.5 (flank visible in turns); look target 0.6 × car length ahead × speed factor | no roll. Auto-recentre 1.5 s after free-look. `V` cycles near/mid/far/hood. `C` looks behind |
| Cinematic (hold a free key in the car, or the button on touch; **not `R`**, which `VehicleClient.luau` L1117 binds to radio-previous) | shot list: low side track, high chase, roadside fixed pan, front 3/4 reverse track; cut every 3–5 s | — | — | 40–55 | — | letterbox: two black Frames at 11% H, HUD hidden |
| Death / busted | slow detach drift | — | 6° dutch | −10 over 5 s | — | see §5.9 |
| Rare reveal | 3 s orbit at 18 studs, FOV 45 | — | — | 45 | — | with shard |

---

## 6. Custom image assets we must make

All of them are white on transparent (tinted with `ImageColor3`) unless a colour is noted.

| Asset | Count | Size | How to make |
|---|---|---|---|
| **Blip sprite sheet** | ~40 | 32×32 cells on a 512×512 sheet | Vector (SVG→PNG) with a 2 px dark outline baked in |
| **Height variants** | auto | up/down arrow overlays (2 cells) | — |
| **Player arrow** | 1 | 32×32 | white arrow with a black outline |
| **North disc** | 1 | 32×32 | black disc with a white "N" |
| **Wedge (police cone)** | 1 | 256×256 | 60° wedge with radial alpha falloff |
| **Stars** | 2 | `star_fill`, `star_hollow`, 64×64 | Vector |
| **Heat badges** | 4 | 48×48 | car, camera, face, outfit |
| **Weapon silhouettes** | ~14 | 256×96, plus 96×40 HUD versions | fists, bat, knife, pistol, heavy pistol, SMG, micro-SMG, assault rifle, carbine, pump shotgun, sawed-off, taser, spike strip, jerrycan. Blender orthographic side render of our weapon models with flat white and a Freestyle outline, or vector-traced. **Must be our own models**, not GTA icons |
| **Phone shell** | 1 (+2 colourways) | 9-slice 256×480 | our own parody handset, no Apple or iFruit likeness |
| **Phone app icons** | 9–12 | 96×96, flat glossy squares, colour allowed | Contacts, Messages, Jobs, Garage, Map, Internet, Camera, Settings, Codes, Crew |
| **Key caps and glyphs** | ~30 | 48×48 | keyboard letters plus Tab, Shift, Space, Enter, Esc, LMB/RMB/Wheel, gamepad via `GetImageForKeyCode` where possible, touch "tap" glyph |
| **Minimap and pause-map tiles** | per map (e.g. 16–36) | 1024×1024 | rendered from map data (§5.1) |
| **Vignette** | 1 | 512×512 | radial black alpha (death grade, cinematic) |
| **Spinner ring** | 1 | 128×128 | loading and pause saves |
| **Contact portraits** | 6–10 | 128×128 | Mechanic, Lawyer, Fence, Bonus, Garage Security, Crew. Rendered headshots of our NPCs |
| **Interaction-menu header banners** | 6 | 600×128 | Garage, Dealership, Gear, Spray, Chop, Store. Painterly, brand gradient |
| **Loading illustrations** | 6–8 | 1920×1080 (uploads may be up to 8000², but 4K rendering is announced only for MeshPart, SurfaceAppearance, Texture, Decal and MaterialVariant, **not UI ImageLabels**; check in Studio whether a 1920-wide ImageLabel shows at full resolution, otherwise split it into 1024 tiles) | painted key art panels; also used for the thumbnail and icon |
| **Wordmark** | 1 | 1024×256 | "HOTWIRE CITY" custom lettering; may be heavy lowercase in the Pricedown spirit, but **drawn ourselves or from Kanit/Sarpanch outlines** (OFL permits outlines) |

The **blip set** covers:
- player, other player, crew;
- cop on foot, cop car, helicopter, SWAT van;
- target car (stealable), own car, stolen own car;
- garage/home, dealership, spray shop, chop shop, gear/gun store, clothing, hospital, police station, mechanic;
- objective dot, waypoint pin, armored truck, hot drop, event, ATM/bank;
- generic dot, square, triangle;
- 2 height arrows.

---

## 7. Mobile adaptations

Roblox's touch controls take two areas: the **DynamicThumbstick** (bottom-left zone) and **Jump** (bottom-right). The original brief says to build for both (44% play on both PC and mobile, 12% on mobile only).

| Element | Desktop | Touch |
|---|---|---|
| Minimap and bars | bottom-left 192×136 | **top-left under the top bar**, 168×118, bars under it (GTA mobile ports put the radar top-left to clear the stick) |
| Help text | top-left | **below the minimap**, width 260, Montserrat 16 (×TouchMinScale floor 0.72, so ≥ 11.5 real px; prefer 18 on phones) |
| Feed | above the minimap | **below the help text**, at most 2 cards, never takes touches (`Active=false`) |
| Stars, cash, ammo | top-right | top-right (unchanged). The weapon icon becomes a **tappable button** that opens the wheel |
| Objective line | bottom-centre | **top-centre** under the top bar (the bottom-centre is between the thumbs) |
| Location names | bottom-right | **top-centre**, single line `District · Street`, 3 s |
| Weapon wheel | hold Tab | tap the weapon button to toggle; tap a card; the backdrop tap closes it |
| Phone | ↑ | phone button in the right-hand cluster (≥ 8% H) |
| Action buttons | keys | right cluster: Enter/Hotwire, Aim, Fire, Nitro, Horn, Phone, Map. Flat black `Panel` circles with white glyphs, ≥ 8–10% H (brief), 0.35 bg, white glyph, no emoji |
| Pause menu | P/M | map button. Tabs become a horizontal scroller. List rows are 36 px |
| Interaction menus | top-left list | **bottom sheet**, full width, 40% H, rows 40 px |
| Big messages | same | same (band at 49% H) |
| Cinematic cam | hold R | toggle button while driving |

---

## 8. The Roblox top bar and CoreGui

- **Keep the top bar.**
  - `SetCore("TopbarEnabled", false)` hides chat, inventory and the player list, and blocks clicks in that region. The GUI origin offset still remains.
  - The Roblox menu button must stay reachable.
  - Since the 2023 redesign the reserved height is **58 px** and varies by device. Track `GuiService.TopbarInset` (Rect, dynamic) with `GetPropertyChangedSignal`.
- **Disable these CoreGuis** at client start: `PlayerList` (our stars and cash own the top-right; a player list moves to Pause › STATS or a held-`Tab`-in-menu list), `Health` (our bars), `Backpack` (weapon wheel), `EmotesMenu`, `SelfView`.
  - Leave `Captures` on, but check it does not collide with the right-hand touch cluster; disable it if it does. Our Camera app uses CaptureService.
  - Leave `Chat` on.
- **Chat** (`TextChatService.ChatWindowConfiguration`):
  - `FontFace` = Montserrat Medium, `TextSize` 15;
  - `BackgroundColor3` black, `BackgroundTransparency` 0.45;
  - `TextStrokeTransparency` 0.6;
  - **`HorizontalAlignment = Left`, `VerticalAlignment = Center`**: the GTA Online chat position, which frees the top-left for help text. Verify on mobile, where the chat is often collapsed.
  - Also ChatInputBarConfiguration font.
- **ScreenInsets.** HUD guis use `CoreUISafeInsets`; overlays use `None`. Optionally place stars inside the top-bar row via `TopbarSafeInsets`, the GTA-tight top alignment. A devforum regression report exists for that mode in Studio, so it is phase 2.

---

## 9. Current UI audit: exactly what must change

Line numbers are as of today.

The tests (`tests/spec/hud.spec.luau`, `menus.spec.luau`, `leftovers.spec.luau`, `clientcore.spec.luau`, `ap4.spec.luau`) exercise only **pure helpers**, for example:
- `HUD.clampStars`, `starStates`, `theftView`, `theftMode`;
- `Tut.transition`, `STEPS`, `cardBottomAbove`;
- `Menu.resolveName`, `rewardInfo`;
- `Notif.kindStyle`, `formatCashDelta`, `bannerHold`, `pickStolenCar`, `toastAnchor`;
- `Kit.screen`.

*(Added in verification.)* The tests also call:
- **helpers tied to elements this spec deletes:** `HUD.touchMenuGrid`, `HUD.gridFit`, `HUD.homeState`, `HUD.MENU`, `HUD.MENU_TOP_ROW`, `HUD.menuNameCandidates`;
- **other HUD helpers:** `HUD.vipChatPrefix`, `cashTrend`, `rebirthReady`, `playtimeClaimable`, `gearAffordable`, `countGarage`, `countDiscovered`, `resetAllowed`;
- **Tutorial helpers:** `Tut.shouldRun`, `hintFor`, `keyFor`, `pickNearest`, `loadingScreenUp`;
- **Notification helpers:** `Notif.alertSubtitle`, `trimOldest`, `carLabel`;
- **the `Menu.open`/`close`/`toggle`/`Opened`/`Closed` API**;
- **all `MinimapController` / `MapScreenController` pure helpers** (`tests/spec/minimap.spec.luau`).

These must survive, even as dead code, or the tests need a separate, approved change.

**Keep those functions and signatures** (or move them to `src/shared/Util` with re-exports) and replace the view layers.

### `src/client/UI/Theme.luau` (53 lines): rewrite

| Lines | Today | Change |
|---|---|---|
| L2–3 | header "bold cartoon-heist look (deep navy panels, hot pink + cyan accents, chunky rounded type)" | GTA restrained language |
| L7–23 | `Colors` (navy `18,20,38`; Primary pink `255,52,140`; Secondary cyan `0,214,255`; neon Cash `70,235,110`; …) | §3 tokens. Keep alias names during migration (`Primary`→`Accent`, `Cash`→`Green`, `Police`→`Blue`, `Danger`→`Red`, `Gold`→`Gold`) so the other ~10 consumers compile |
| L25–29 | `Fonts` FredokaOne, GothamBold, GothamBlack | `Display`/`Numeric` = Kanit Heavy (fromId), `Condensed` = Oswald SemiBold, `CondensedMedium`, `Body` = Montserrat Medium, `BodyRegular`, `Script` = Damion, `DisplayFallback` = Sarpanch Heavy |
| L31–33 | `Corner` 14, `CornerSmall` 8, `StrokeThickness` 3 | `Corner = UDim.new(0,0)`, `CornerSmall = UDim.new(0,2)` (key caps only), `StrokeThickness = 0`, new `TextStroke = 2` |
| L36 | `TweenPop` (Back easing) | delete. Add `TweenFade` (0.3 Sine Out) and `TweenSlide` (0.25 Quint Out) |
| L45–53 | `Layers` | add `Feed 11`, `Phone 25`, `Wheel 35`, `Pause 45`, `Shard 50`, `Fade 60` |

### `src/client/UI/Kit.luau` (414 lines)

| Lines | Function | Change |
|---|---|---|
| L113–142 | `Kit.screen` | add `opts.insets` (default `CoreUISafeInsets`, `None` for overlays). Keep the signature and UIScale logic (tested) |
| L145–163 | `Kit.label` | default font → `Theme.Fonts.Body`. **Remove the automatic Contextual stroke** (`size/14`) that outlines every label. Add `Kit.numeric(text, size)` with the 2 px stroke |
| L166–180 | `Kit.panel` | rounded 14, 3 px stroke and white→grey gradient → flat `Panel` (black at 0.27), no corner, no stroke, no gradient |
| L183–197 | `Kit.juice` | hover 1.06, press 0.92, Back pop → **delete**. Replace with `Kit.rowHover` (bg/text invert) plus a click sound |
| L200–227 | `Kit.button` | chunky 180×52, double stroke, gradient → replace with `Kit.menuRow`, `Kit.tab`, `Kit.keycap`, `Kit.instructionButton` |
| L230–258 | `Kit.iconButton` | emoji icon tile → **delete after migration**. It is used by the HUD menu column (`HUDController` L634) **and** by the touch driving buttons (`VehicleClient.luau` L356), so first rebuild those as §7 flat circles |
| L261–292 | `Kit.progressBar` | pill with stroke and gradient → flat track plus fill, no corner, height param |
| L296–357 | `Kit.window` | pink header, red X modal → **delete after migration**. Menus become Pause tabs, list menus and phone apps |
| L359–380 | `Kit.open` / `Kit.close` | scale 0.7→1 Back → fade plus 8 px slide, 0.2 s |
| L383–405 | `Kit.tweenNumber` | keep |
| L408–412 | `Kit.pop` | delete. Stars get their own 1.25→1 tween |
| new | — | `Kit.key(name)` (`<mark>` key-cap rich text), `Kit.blip(name)` (sprite-sheet ImageLabel), `Kit.shard(kind, title, subtitle, rows)` |

### `src/client/Controllers/HUDController.luau` (2395 lines when written; 2432 after an edit at 16:04 UTC, so line references after about L600 are now 2–37 lines too low, e.g. `showBusted` is at L1802): rebuild the view

| Lines | Today | Change |
|---|---|---|
| L4–26 | header describes the cash pill, emoji, top-centre stars, left menu column, HOME, comic BUSTED | rewrite to the §2.1 layout |
| L100–106 | `TOP_CENTER_HALF`, `STATUS_TOP=80`: stars top-centre "because the PC player list covers the top-right" | disable the PlayerList CoreGui. Stars move **top-right** |
| L112–116 | PURPLE, REBIRTH, STAR_EMPTY navy | delete |
| L121–159 | `MENU` (🛒 STORE, 🔧 GEAR, 📖 INDEX, 🎁 DAILY, 🎯 JOBS, ⏰ GIFTS, ♻️ REBIRTH) and `MENU_TOP_ROW` (🎟️ CODES, ⚙️ SETTINGS) | **remove the HUD menu column.** Map ids to phone apps and pause tabs. Keep the `MENU` table for `menuNameCandidates`/tests or move it to MenuController. `getMenuButton(id)` returns the phone app tile, for Tutorial pointing |
| L606–678 | `makeBadge` (pulsing red "!") | unread-count badge on the phone icon and apps |
| L680–710 | `wiggle`, `shake` | delete |
| L718–870 | `buildCash`: top-centre glossy pill, 💵 badge, gloss strip, flash, "+$X/s" tab, ⚡ multiplier chip, 👑 VIP crown | top-right Kanit cash plus delta (§5.4). Income rate, multiplier and VIP move to Pause › STATS. Garage income arrives as feed posts |
| L874–968 | `buildWanted`: navy panel, 🚨 siren, FredokaOne "★" text glyphs in gold `#FFCD32`, escape progress bar, "🚔 GETTING BUSTED!" bar | star ImageLabels (§5.3), no panel. The escape bar is **removed** (search mode = flashing stars plus minimap cones). Bust bar → thin "BEING ARRESTED" bar |
| L970–1011 | `buildMenus` grid and top row | delete |
| L1013–1067 | `buildTheft`: "🚨 DELIVER IT HOME!" panel, pink bar, bottom-centre | **GTA Online timer bar** bottom-right above the location block: `Panel` 220×28, label "DELIVERY" Oswald 14 left, `1:42` Kanit 20 right, turns `Red` when ≤ 20 s. "GET BACK IN" variant label `Red`. Plus the objective line "Take the car to your <y>garage</y>." |
| L1069–1081 | `buildToggle` (👁️ button) | streamer mode toggle → Settings plus keybind. No floating button |
| L1103–1124 | `chatBottom` (column starts under the default chat) | obsolete (chat moved left-middle). Help text owns top-left |
| L1142–1268 | `bottomReserve`, `layout` | rewrite for the new anchors. `getBottomClearance` returns the bottom-right timer and location stack. `getFeedAnchor` returns above the minimap. `getTopStackBottom` returns the bottom of the top-right block |
| L1531–1601 | HOME button (🏠, "🚨 HOME", "Lose the cops first!") | **remove the button.** GoHome → Phone › Garage › "Set GPS home" (purple route). Any fast-travel becomes a product decision (GTA has none; a taxi contact is the GTA-native option) |
| L1765–2015 | `showBusted`: cream "stamp" plate, red 9 px stroke, −8° rotation, "BUSTED!" FredokaOne 118, 🚨 emoji, red/blue edge flashes, white flash, shake, "🚗 IMPOUNDED", "🚔 Released at Police HQ" | `Kit.shard("busted", …)` plus the §5.9 sequence. Same remote and `lostCash` / `carLabel` data |
| L110, L2180–2203 | VIP chat tag `[👑 VIP]` gold `#FFCD32` (`VIP_CHAT_TAG`, `installVipChatTag`) | `[VIP]` in `Gold #D6B563`, no emoji |
| new | — | Minimap, Bars, HelpText, Objective, Location, Ammo, Wheel modules. Split HUDController into `HUD/*.luau` submodules (it is already 2.4k lines) |

### `src/client/Controllers/MenuController.luau` (3688 lines, 122 emoji)

- **One `Menus` ScreenGui with dimmed backdrop and Kit.window modals (L3278)** → three hosts: **PauseMenu** tabs (MAP, JOBS = Contracts + Daily, GARAGE = Index/collection, STATS = rebirth, VIP, multiplier, income, STORE, SETTINGS + Codes), **ListMenu** (GearShop at the store counter, Dealership, Spray, Garage actions) and **Phone apps**. The routing API (`open`/`close`/`toggle`/`has`/`resolveName`, the `OpenUI` remote) **stays** and points at the new hosts.
- **Buttons.** `Kit.button("🎁 CLAIM!")`, `"🎲 SWAP"` (L2518), `"♻️ REBIRTH"` (L2973), `"BUY"`, `"$0"` → list rows with right-aligned price, or instruction buttons "Claim ⏎".
- **`iconTile`, `chip`, `setPulse`, `floatText`, `shake` (L1069–1198)** → delete or replace with row states. No pulsing.
- **Index cards (L1814–2087).** Keep the ViewportFrames, restyle to flat black cards with an Oswald car name, a Montserrat class line and rarity as a small coloured label. The detail view becomes the GARAGE tab right pane.
- **Daily tiles and gift tiles (L2259–2816).** Become JOBS › Daily Objectives rows and Messages-thread claims.
- **Pure helpers** (`dailyTileStates`, `playtimeTiles`, `contractRows`, `upgradeRows`, `toolRows`, `storeItems`, `storeBlock`, `rebirthView`, `windowScale`, …) are kept, because the tests use them.

### `src/client/Controllers/TutorialController.luau` (1447 lines)

| Lines | Today | Change |
|---|---|---|
| L70–111 | `STEPS` with emoji icons and shouty titles ("STEAL A CAR!", "BETTER CARS AT THE DEALERSHIP!") and colours Primary/Secondary | keep the step ids, `transition()` and the tested helpers. Each step gets `objective` (rich, coloured keyword) plus `help` (key-cap text). Example: objective "Steal a <b>car</b>." with help "Hold E to hotwire a parked car. If anyone sees you, the police are called." |
| L672–885 | `buildCard`: 500×110 card bottom-centre, 92 px icon circle, Fredoka 30 title, step dots, 64 px "E / HOLD" keycap, SKIP pill | **delete.** Use HUD `HelpText.show` plus `Objective.set`. SKIP moves to Settings ("Skip tutorial"), or Backspace on help text |
| L508–556 | fallback "⬇️" arrow billboard | GTA-style **chevron marker** (BillboardGui, our blue or yellow chevron sprite) over the target car, plus a minimap blip and GPS |
| L623–670 | `highlightCar` pulsing outline Highlight | replace with the chevron plus a `Blue` blip ("~b~car" semantics). An optional subtle Highlight at 0.85 is acceptable for accessibility |
| L969–1020 | `confetti` | delete. Step completion = a short tick plus the next objective. The finish is a `job complete` shard with rows ("First delivery $X") |
| — | — | `setHudFocus` stays (hides the phone/pause hints during steps 1–3) |

### `src/client/Controllers/NotificationController.luau` (1978 lines)

| Lines | Today | Change |
|---|---|---|
| L62–70 | toast anchors right side 36% H, widths 320/330 | feed above the minimap (§5.7). Keep `toastAnchor` (tested) but re-parameterise |
| L476–630 | `toast()`: kind colour plus emoji icon, timer bar, ×N merge, click to dismiss | feed card. Kind only changes keyword colour or adds a small blip icon. Keep the merge as "(x3)". No timer bar |
| L437 | `TextService:GetTextSize(..., Enum.Font.FredokaOne, ...)` | `GetTextBoundsAsync` with Montserrat `FontFace` |
| L638–883 | `announce()`: huge centre banner, scale-pop plus wiggle, glossy title, shine sweep, neon ribbon | rare and important events → `Kit.shard` (passed or rarity variant). Everything else → feed |
| L922–1000 | `feed()` kill-feed beside the menu column | same feed stack |
| L1003–1175 | `cashPopup` world BillboardGui "+$1.2K" pops and HUD popups | remove world pops (optionally keep a tiny Montserrat "+$X" at the collect pad only). HUD path → cash delta |
| L1177–1265 | `coinBurst` | delete |
| L1270–1455 | `offlineEarnings` modal ("💤 WHILE YOU WERE AWAY", god rays, count-up, COLLECT) | email/text plus feed plus cash delta. Keep `holdCash`/`releaseCash` if a Claim action stays in Messages |
| L1557–1890 | `carStolenAlert`: 4-frame red vignette pulse, alarm loop, "🚨 THIEF IS STEALING YOUR CAR!" banner | feed card from contact "Garage Security", phone ring, flashing `Red` blip on the car, **red GPS route**, help text "Your car is being stolen. Hold ↑ for the phone, or chase the thief." No full-screen vignette |

### `src/client/Controllers/MinimapController.luau` (1464 lines) and `MapScreenController.luau` (1118 lines): restyle, do not rebuild *(added in verification)*

§5.1 treats the minimap as new, but most of it already exists and is tested (`tests/spec/minimap.spec.luau`):
- a camera-rotating radar over the `tools/minimap/build.py` tiles (`assets/minimap/`, 2×2 tiles of 1024²);
- a pooled blip atlas with rim clamping;
- speed zoom;
- RoadGraph A* GPS with reroute;
- a red/blue wanted bezel and a search circle;
- touch placement at top-left;
- the fullscreen map on `M`.

The v2 work is a **restyle**:
- the circular CanvasGroup becomes the V rectangle: a plain Frame with `ClipsDescendants`, see §5.1;
- the §3 palette and V blips;
- the 50/25/25 bars under the radar;
- police cones in place of the search circle.

Keep its public API and its pure helpers.

### Also affected (outside the named files, same rules)

- **`src/first/LoadingScreen.client.luau`.** FredokaOne/Gotham, navy/pink/cyan palette (L41–49), wordmark text → §5.14.
- **`VehicleClient.luau` DrivingUI (L375–640).**
  - The speedometer panel, "NITRO!", "DRIFT!" banners and "📻 RADIO" pill go.
  - GTA has no speedometer. Make an optional minimal Kanit "84 mph" readout a setting.
  - Nitro moves to the third minimap bar segment.
  - The radio becomes GTA-style **station name at top-centre** (Oswald 18 plus a Montserrat 14 track name, 3 s).
  - The camera becomes the §5.17 chase cam.
- **`CombatClient.luau`.** Emoji tool visuals (🏏 BONK, ⚡ ZAP, 📌 SPIKES) and the cartoon stun stars over heads → weapon silhouettes, dot reticle, no cartoon stars. Touch fire/aim buttons follow §7.
- **`WaypointController.luau`.**
  - World guide Beam, sparkle beam, 140-stud light pillar, emoji pin billboard and edge arrows → minimap GPS plus edge-clamped blips.
  - In-world: a **GTA corona marker** at destinations: a translucent cylinder (Neon-free SurfaceAppearance or a `Cylinder` part at 0.6 transparency, coloured `Yellow`/`Blue`), plus chevrons.
- **`EventsClient`, `GarageClient`, `DealershipClient`** (22, 17 and 5 emoji). Rebuild on the new Kit (feed, timer bars, list menus).
- **World text in server code** still sets FredokaOne:
  - `MapBuilder.luau:90`
  - `PlotService.luau:129-130`
  - `EventService.luau:352,366`
  - `LeaderboardService.luau:67-68`
  - `DealershipService.luau:377`
  - `PoliceService.luau:1722`
  - `shared/Vehicle/CarBuilder.luau:469`
  
  These move to Oswald/Montserrat or to texture-based signs.

---

## 10. Studio verification checklist (for the operator)

1. Check that `Font.fromId(12187373592, Enum.FontWeight.Heavy)` (Kanit) and `Font.fromId(12187607722)` (Damion) render in a published place with no fallback flash, after preloading.
2. Check that a CanvasGroup minimap with a rotated child clips correctly on a low-end phone (QualityLevel 1). Watch for a blank texture.
3. Read `GuiService.TopbarInset` on PC, iPhone and Android. Confirm the top-right is free once PlayerList is disabled. Check whether `Captures` overlaps the touch cluster.
4. Check that `ChatWindowConfiguration.VerticalAlignment = Center` / `HorizontalAlignment = Left` works on PC and mobile.
5. Tune the death grade (Saturation −1, Contrast 0.3) together with the world team's `HotwireColor` ColorCorrection. Both stack, so the camera-parented effect wins only locally.
6. Audition the §5.16 sound IDs.
7. Take side-by-side screenshots of the `mock_v2_hud_layout.jpg` layout in-engine against `ref_gtawiki_GTAV_new_screen.jpg`.

## 11. Open decisions for the lead

1. **Always-on cash.** GTA hides it; this spec defaults to on, for retention.
2. **Rebirth.** Rename it "Reputation" or "Prestige", and decide whether it stays in v2.
3. **HOME teleport.** Remove it, or replace it with a taxi or mechanic contact.
4. **Brand accent.** `#FF8A3D` "Ignition Orange" is proposed. A teal alternative would read Miami without pink.
5. **GTA VI extras for phase 2.** Heat badges, red/grey/hollow star states, and a rounded or 3D minimap.
