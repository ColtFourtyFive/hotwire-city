# Sketchfab picks: vehicles and weapons (2026-10-27)

**Sources.** Every candidate below is a **CC-BY 4.0** Sketchfab model. The license was re-checked through the API before each download; no CC0 model made the cut. Each model lives at `assets/source/sketchfab/<slug>/`, which holds:

- `model.glb`;
- `meta.json`, with the license, author, URL, face counts and a Blender analysis block;
- `thumb.jpg`, the Sketchfab thumbnail;
- `preview.png` and `preview_inset.png`, our studio renders.

Attribution for all 107 downloads is in `assets/ATTRIBUTION.md`. Credits only need to list the models that ship.

**Contact sheets.**
- Vehicles: `vehicles_sheet_1..4.png`.
- Weapons: `weapons_sheet.png`.
- Labels on each card:
  - Class, author and slug.
  - Triangles and license.
  - Size in metres. A `(xF)` suffix means the GLB uses non-metre units and F is the guessed factor.
  - File size.
  - `wheels:SEP` means at least 2 wheel-like separate meshes were found by name or geometry. `MERGED?` means none were found.
  - `logo-parts` means a mesh, material or image name contains logo, badge or decal.
- The main view is a 3/4 view and the inset shows the opposite 3/4. The front-detection heuristic is wrong on a few models (for example `box-truck-b0e878` and `red-fire-truck-with-ladder-5c8d87`), so the inset is there to show the real front.

**Audit.** `audit.json` (from `tools/sources/audit_models.py`) records three things per model:
- real brand names in the title, tags, nodes, materials or images;
- logo-like part names;
- rip-style node names (`detach_*`, `*_pivot_*`, `bonnet_dummy`, `TrafficBadge_Maxcar…lod0`). These are typical of assets extracted from other games, so treat that model's provenance as doubtful even though it is labelled CC-BY.

**Excluded on purpose:**
- **David_Holiday (about 100 uploads).** They use GTA V names: Declasse Granger, Vapid Dominator, Bravado Buffalo-LSPD, Gallivanter Baller, Albany Alpha. These are very likely Rockstar rips despite the CC-BY label, so nothing by this author was downloaded.
- Burned or wrecked models, toys, voxel and stylised models, and NC/ND/SA licenses. The tool refuses any license other than CC0 or CC-BY; this was verified against `by-nc`, `by-nd` and `by-sa` models.

## Strongest find: DanielZhabotinsky's "Low poly model" series (CC-BY, about 130 cars)

- **GTA-like by design.**
  - The names are fictional: Fairheaven, Illinois, Kiri, Shvan, Duke, Phoenix, Lightbody, LCT.
  - Each model is 13–27k tris.
  - All share one material layout: 8 materials and a 1024 px texture atlas set.
  - Glass is separate, and there is a simple interior.
  - **Each wheel is a separate mesh**: `*_WheelStock_FL/FR/RL/RR`.
  - Badges are separate meshes (`*_Body_Badges`, `*_Bumper_Front_Badges`, material `Carbadges_misc_U`). Delete those meshes, or repaint that atlas with our parody badges.
- **One import script fits the whole series.** It is the natural base for `tools/blender/carpipe`.
- The series covers 14 of our 20 classes, including the police, taxi, ambulance, armored and LCT box-truck variants.
- Real-world scale is already correct: about 4–6 m in metre units.

## Vehicles: pick and backup per class

All paths are relative to `assets/source/sketchfab/`. "DZ" means DanielZhabotinsky. "Wheels sep" means each wheel is its own mesh.

| Class | Pick | Backup | Notes |
|---|---|---|---|
| compact | `v-compact--ace-11-low-poly-model-055ff8` (DZ, 18.4k) | `v-compact--milano-95-low-poly-model-122a22` (DZ, 18.0k) | Wheels sep. Ace '11 is a modern 5-door shaped like a Chevy Sonic; the grille badge mesh must be deleted. Third option: `v-compact--1991-honda-civic-eg6-f81da3` (21.6k, wheels sep, Honda shape, cm units). |
| sedan | `v-sedan--kiri-10-low-poly-model-7fd6e1` (DZ, 13.0k) | `v-sedan--tozzo-98-low-poly-model-d43bb7` (DZ, 17.9k) | Wheels sep. A modern generic family sedan. Third option: `v-sedan--illinois-90-low-poly-model-d60487` (a civilian Crown Vic look). The Camry `3cf0bc` has merged wheels, a Toyota badge and mm units, so we skip it. |
| luxury_sedan | `v-luxury-sedan--mercedes-benz-s-class-w222-148c7b` (Ryan.Qin, 35.7k) | `v-luxury-sedan--trinity-03-low-poly-model-32ac06` (DZ, 19.6k) | The S-class looks the most realistic and its wheels are separate, but the star badge and grille must be removed and its units are dm. Trinity '03 has a CTS shape, separate wheels and a fictional name. Third option: `gourami-luxury-saloon-bf29ac`, a fictional brand at 108k with merged wheels; its showroom turntable and "GOURAMI" sign meshes need deleting. |
| muscle | `v-muscle--duke-69-low-poly-model-46fed7` (DZ, 18.6k) | `v-muscle--phoenix-455-71-low-poly-model-955edc` (DZ, 25.9k) | Wheels sep. Charger and Firebird shapes, both very GTA ("Dukes", "Phoenix"). For a modern muscle car, use `free-dodge-challenger-srt-38a1fd` (114k): its wheels are merged and it has a Dodge badge. |
| sports_coupe | `v-sports-coupe--jdm-sport-99-low-poly-model-6dd4ae` (DZ, 23.2k) | `v-sports-coupe--generic-coupe-azura-2e1a36` (mk2design, 36.2k) | Wheels sep. JDM Sport is an R34-shaped coupe with a fictional name. Azura is shaped like an Eclipse and has a Mitsubishi tag. Third option: `nissan-200sx-silvia-s14-f2a917`. |
| supercar | `v-supercar--fictional-supercar-v12-goblin-0a20e4` (ollitei, 86.6k) | `v-supercar--2017-mclaren-720s-f7bece` (s0h1o9b, 6.9k) | The Goblin is a fictional design with no badges and separate wheels. Its tiny export scale needs normalising, and its `car_shadow` plane must be deleted. The 720S looks great for 6.9k tris, but it has a badges mesh and McLaren styling, and it includes 3 animations. Retro options: `saba-v12-95` and `cheetah-84` (DZ). |
| suv | `v-suv--urban-10-low-poly-model-2866ef` (DZ, 16.5k) | `v-suv--2011-range-rover-evoque-free-vehic-f7632f` (free-vehicle-archive, 124k) | Urban '10 is a compact crossover with separate wheels. The Evoque is premium (a "Baller" type); strip its Land Rover lettering and logo texture. Third option: `mercedes-benz-g-class-w263-1a2a52` (12.5k, Mercedes star). The mk2design `lowpoly-generic-suv-edc994` has a BMW X6 kidney grille. |
| pickup | `v-pickup--lightbody-90-md-pickup-low-poly-mo-3b3ac5` (DZ, 27.1k) | `v-pickup--conquer-89-pickup-low-poly-model-6c48c9` (DZ, 21.1k) | Wheels sep. A full-size US pickup with a bull bar, plus a compact pickup. **Avoid** `ford-f-150-606bcc` and `2018-chevrolet-silverado…10c645`: they have rip-style `detach_*/pivot_*` nodes, real badges, and black headlight-beam planes sticking out of the front. |
| van | `v-van--shvan-92-low-poly-model-09d718` (DZ, 23.0k) | `v-van--2003-chevrolet-express-gmc-savana-ed2a0b` (ddiaz-design, 31.2k) | Shvan is a G-van shape, a GTA "Burrito". The Express is a modern cargo van with separate wheels, but it has a Chevy bowtie, `TrafficBadge_Maxcar…lod0` rip-style names that need a provenance check, and a broken scale. The Sprinter `f69de1` is untextured white with merged wheels. |
| police_cruiser | `v-police-cruiser--illinois-90-police-cruiser-low-pol-dc8162` (DZ, 19.7k) | `v-police-cruiser--2001-crown-victoria-police-interce-9f30d3` (haoliu95, 42.4k) | Illinois '90 is a clean black-and-white Crown Vic shape with a lightbar and separate wheels. The haoliu95 CVPI is more detailed and lightly weathered, but its 4 wheels are one mesh. Modern option: `trinity-03-cop-interceptor-6a5c6c`. Also available: `murphy-97-cruiser` (big "POLICE" on the hood). |
| police_suv | `v-police-suv--urban-10-cop-enforcer-low-poly-mod-745830` (DZ, 19.5k) | `v-police-suv--lowpoly-generic-suv-police-259fc1` (mk2design, 9.0k) | Wheels sep. The mk2design model has a BMW X6-like grille that needs reshaping. Its Explorer or Tahoe-style look is missing; options are to build it in carpipe or source it from the Creator Store (scout_0003 #3). |
| taxi | `v-taxi--illinois-90-taxi-2-low-poly-model-fa1a26` (DZ, 19.9k) | `v-taxi--2001-crown-victoria-taxi-game-prop-2429a8` (haoliu95, 33.9k) | Illinois is a yellow Crown Vic cab with separate wheels. The haoliu95 cab has merged wheels and a "Yellow Cab" livery to repaint. Classic option: `canyon-75-taxi` (a Checker shape). |
| bus | `v-bus--generic-town-bus-14fe03` (own.guest, 54.5k) | `v-bus--bus-c13716` (tnikita, 25.8k) | The Town Bus is an 80s US transit shape with separate wheels; its units are dm. The tnikita bus is modern with an interior, but it is untextured and its wheels are merged. `city-bus-rigged-36646f` is a Russian PAZ type, and `man-lion-s-city-f49105` carries the MAN brand and has a stray object. |
| ambulance | `v-ambulance--shvan-92-ambulance-low-poly-model-2856dd` (DZ, 25.9k) | `v-ambulance--ambulance-b78313` (mk2design, 4.1k) | Shvan is a US Type II box ambulance with separate wheels; it has mirrored "AMBULANCE" text and real "911" decals. The mk2design model is low poly with a Ford E-series cab and merged wheels. |
| fire_truck | `v-fire-truck--ladder-truck-b24cdf` (overseerover12, 45.9k) | `v-fire-truck--german-ladder-fire-truck-man-tga-t-403fbe` (cm_dp, 50.5k) | The Ladder Truck is a US aerial with a white cab, but its wheels are merged and its units are dm. The MAN TGA is the best quality and its wheels are separate, but it is European-styled and carries the MAN badge. US pumper option: `red-fire-truck-with-ladder-5c8d87` (one material, merged wheels). The class is weak. |
| armored_truck | `v-armored-truck--md-84-armored-low-poly-model-26e809` (DZ, 20.4k) | `v-armored-truck--swat-police-van-5b9076` (Zack_Hawley, 23.4k) | MD '84 is a perfect bank cash-in-transit truck with separate wheels. The SWAT van is dirty with "SECURITY/SWAT" graphics and merged wheels; it is a good fit for the 5★ SWAT van. Also available: `bope-caveir-o-armored-truck-e36169`, an APC with separate wheels; strip the real BOPE insignia. |
| box_truck | `v-box-truck--lct-3000-07-low-poly-model-3be03b` (DZ, 15.8k) | `v-box-truck--lct-3000-95-low-poly-model-663a09` (DZ, 18.9k) | Wheels sep. An Isuzu NPR-style box truck in the right GTA delivery-truck role. `box-truck-b0e878` has a snowflake reefer livery and merged wheels. |
| motorcycle | `v-motorcycle--mid-poly-street-motorcycle-6c576c` (tonycheuk, 15.1k) | `v-motorcycle--kawasaki-h2r-model-2c2e5e` (santunihu, 60.5k) | The tonycheuk bike is a clean, unbranded red sportbike with separate wheels. The H2R looks excellent, but its Kawasaki and Ninja decals and its odd units need fixing. Third option: `yamaha-r1-7b3343` (92.8k). Its decals are a separate `Main_Decals` material, so they are easy to strip. `suzuki-gsxr-750` has rip-style `detach_*` nodes, so avoid it. |
| lowrider | `v-lowrider--impala-1964-lowrider-c68508` (mrkuza, 19.3k) | `v-lowrider--impala-lowpoly-db303e` (bagatela.qc, 11.3k) | Both are '64 Impala convertibles with separate wheels. mrkuza's is green, textured and has 1 animation; check for a Chevy emblem. bagatela's is untextured, so it needs materials. `chevrolet-impala-1963…a0330e` holds two cars, one of them exploded, so we skip it. |
| limousine | `v-limousine--gmc-hummer-h2-limo-876586` (maregajavier, 2.3k) | `v-limousine--mercedes-w126-limousine-lowpoly-fo-4ed60d` (fishermans, 18.2k) | **The class is weak.** The H2 limo is baked-texture low poly with merged wheels and a Hummer grille. The W126 is an untextured 3D-print mesh with merged wheels. `chrysler-300c-limo-8f2f46` has missing textures and GTA-mod `bonnet_dummy/boot_dam` nodes, so its provenance is doubtful and we avoid it. **Recommendation:** stretch the luxury-sedan pick (S-class or Trinity '03) in carpipe instead. |

## Weapons: pick and backup per class

| Class | Pick | Backup | Notes |
|---|---|---|---|
| pistol | `w-pistol--9mm-pistol-43bc09` (TORI106, 4.7k) | `w-pistol--low-poly-g17-60efc5` (TastyTony, 2.4k) | The pick is textured and Glock-shaped with "MK2" slide text. The backup has flat colours and no textures. `g19-pistol…e3412d` is an exploded or disassembled view, so it is unusable as-is. |
| heavy_pistol | `w-heavy-pistol--desert-eagle-free-model-32838f` (javadbayat, 19.9k) | `w-heavy-pistol--revolver-357-magnum-360c62` (Artem.Goyko, 4.8k) | The Desert Eagle is textured chrome; delete the loose magazine and round, and check the slide engraving. The .357 has a great wood grip and could also serve as a separate "revolver". `357-python…3b81c9` is rigged, but it ships with loose rounds and a speedloader. |
| smg | `w-smg--low-poly-hk-mp5-80980f` (TastyTony, 5.3k) | `w-smg--mp5-submachinegun-2a9ce6` (michaelkarel, 7.8k) | The TastyTony MP5 is clean and game-ready with flat colours; delete its `Icosphere` helper. The michaelkarel MP5 is textured, but its scene includes a fluffy "part pile" mesh (`part pile_MP-5_0`, 62×6×62 units) and `Plane_ground_0`, which must be deleted; the gun itself is `Object_9`. Micro-SMG option: `low-poly-micro-uzi-833e1c`. |
| assault_rifle | `w-assault-rifle--akm-free-lowpoly-409c88` (dan741vlasov, 18.7k) | `w-assault-rifle--ak-47-assault-rifle-46a36e` (so_O, 19.3k) | Both are textured. The AKM has wood furniture and a sling; delete the sling for first-person use. The so_O AK is tactical with a suppressor. Flat option: `low-poly-akm-849b7c`. |
| carbine | `w-carbine--m4-carbine-b516a8` (sinnik, 15.4k) | `w-carbine--low-poly-m4a1-8cab1c` (TastyTony, 10.8k) | The sinnik carbine is textured with a holo sight. Also available: `low-poly-hk416`. |
| shotgun | `w-shotgun--remington-870-shotgun-6db0ad` (milinam2002, 6.2k) | `w-shotgun--remington-870-shotgun-05a6a0` (Urpo, 7.0k) | Both are textured pump guns. Flat options: `low-poly-mossberg-590` and `low-poly-remington-870` (sawn-off). |
| sniper | `w-sniper--sniper-cdefd8` (bumstrum, 13.1k) | `w-sniper--sniper-rifle-gameready-free-e520b2` (pashtetuser, 15.3k) | The pick is an AWM type in OD green with a scope and bipod. The backup is a modern chassis rifle. |
| minigun | `w-minigun--m134-handheld-minigun-8f008c` (boriseviav, 15.8k) | `w-minigun--low-poly-m134-minigun-eed0c9` (TastyTony, 13.0k) | Optional class. The pick is textured; the backup has flat colours and an ammo box. |
| melee | `w-melee--alluminum-carbon-fiber-bat-672baf` (MauriceBaxter, 7.7k) and `w-melee--combat-knife-48e00d` (San.Dro, 1.2k) | `w-melee--m9-bayonet-default-365930` (Firewarden, 2.4k) | The bat has "PRECISION" text, which is fine. The knife is a Ka-Bar style. `baseball-bat-432955` is grimy and stained red, so we skip it under the no-gore rule. |
| grenade | `w-grenade--m67-grenade-36a23c` (nickolasa.mcintosh, 4.4k) | `w-grenade--m67-fragmentation-grenade-05e2a2` (vextin, 1.6k) | Optional class. Both are textured M67s. |

**Gun names.** All the weapons use real model names (Glock, Remington, HK and so on). None of the picks shows a prominent maker logo in the renders, but give them parody names in-game. TastyTony has about 190 more consistent "Low-Poly" guns, all CC-BY. They are a uniform fallback set for any class but are untextured.

## Cleanup common to all picks (for carpipe and weaponpipe)

1. **Normalise scale per class.** Import units vary: m, dm, cm, mm and inch. `meta.json.analysis.dims_m` holds the raw extents after the preview's re-orientation, as width, length and height.
2. **Normalise orientation.** Forward axes vary. DZ models carry front/rear part names; the others need a manual check. The inset on each card shows the opposite side.
3. **Delete helper meshes:** shadow planes, ground planes, backdrops, turntables, loose magazines and rounds.
4. **Remove or replace badges and logos.** DZ models keep them as separate meshes, and the R1 keeps them as a separate material.
5. **Split merged wheels** for: CVPI, Crown Vic taxi, mk2design ambulance, Ladder Truck, SWAT van, both limos and both buses.
