--!strict
-- UI art + UI sounds (gta_ui_language §5.16, §6). The GENERATED block is written by `python3 -I tools/ui/build.py`
-- (renders tools/ui/art.py + scenes.py into assets/ui/, uploads changed PNGs as Image assets, records the ids in
-- assets/ui/manifest.json). Read it through Kit.image / Kit.resolveImage: "<key>" for a whole image, "<sheet>.<cell>"
-- for a sprite-sheet cell (e.g. "hud.star_fill", "apps.contacts", "portraits.cab"). An id of "" means not uploaded:
-- every consumer falls back to plain frames / text.
--
-- Sheets:
--   hud        64 px white glyphs (tint with ImageColor3): star_fill, star_hollow, arrow (radar player), north,
--              chevron, dot, ring, square; touch / phone glyphs phone, map, nitro, drift, horn, exit, camera, cab,
--              lock, cash, check, back, signal, battery, plus, minus; heat-badge glyphs car, cctv, face, shirt;
--              wrench, person, bubble, pin; spinner (128 px).
--   apps       96 px phone app icons: contacts, messages, jobs, daily, gifts, codes, camera, settings, map, prestige,
--              store, garage, cab.
--   portraits  128 px contact headshots: mechanic, lawyer, fence, bonus, security, crew, cab, dispatch.
--   banners    600 x 128 interaction-menu header art: garage, dealership, gear, spray, chop, store (the title is set
--              in Damion at runtime). Unused while ListMenu.BANNER_ART is off (the sheet is one generic skyline).
-- Images: wedge (police vision cone, apex at the centre), vignette, shard_band (keystone big-message band),
-- phone_shell (9-slice), wordmark, loading_1..6 (1920x1080 key art: tools/ui/keyart.py, Blender renders of the
-- carpipe cars).

local UIAssets = {}

-- BEGIN GENERATED (tools/ui/build.py)
-- Whole images (Kit.image("<key>")); "" until uploaded.
UIAssets.Images = {
	wedge = "rbxassetid://131406024440823",
	vignette = "rbxassetid://116565374657906",
	shard_band = "rbxassetid://129026920716318",
	phone_shell = "rbxassetid://100859923569033",
	wordmark = "rbxassetid://105746694254300",
	loading_1 = "rbxassetid://76057201104160",
	loading_2 = "rbxassetid://90347903015746",
	loading_3 = "rbxassetid://124336509648512",
	loading_4 = "rbxassetid://124106427198608",
	loading_5 = "rbxassetid://139161880276868",
	loading_6 = "rbxassetid://137928702582117",
}
-- Sprite sheets (Kit.image("<sheet>.<cell>")): cell = { x, y, w, h } in sheet pixels.
UIAssets.Sheets = {
	hud = {
		image = "rbxassetid://135962349023536",
		cells = {
			arrow = { 128, 0, 64, 64 },
			back = { 192, 128, 64, 64 },
			battery = { 320, 128, 64, 64 },
			bubble = { 384, 192, 64, 64 },
			cab = { 448, 64, 64, 64 },
			camera = { 384, 64, 64, 64 },
			car = { 0, 192, 64, 64 },
			cash = { 64, 128, 64, 64 },
			cctv = { 64, 192, 64, 64 },
			check = { 128, 128, 64, 64 },
			chevron = { 256, 0, 64, 64 },
			dot = { 320, 0, 64, 64 },
			drift = { 192, 64, 64, 64 },
			exit = { 320, 64, 64, 64 },
			face = { 128, 192, 64, 64 },
			horn = { 256, 64, 64, 64 },
			lock = { 0, 128, 64, 64 },
			map = { 64, 64, 64, 64 },
			minus = { 448, 128, 64, 64 },
			nitro = { 128, 64, 64, 64 },
			north = { 192, 0, 64, 64 },
			person = { 320, 192, 64, 64 },
			phone = { 0, 64, 64, 64 },
			pin = { 448, 192, 64, 64 },
			plus = { 384, 128, 64, 64 },
			ring = { 384, 0, 64, 64 },
			shirt = { 192, 192, 64, 64 },
			signal = { 256, 128, 64, 64 },
			spinner = { 0, 256, 128, 128 },
			square = { 448, 0, 64, 64 },
			star_fill = { 0, 0, 64, 64 },
			star_hollow = { 64, 0, 64, 64 },
			wrench = { 256, 192, 64, 64 },
		},
	},
	apps = {
		image = "rbxassetid://131139912413186",
		cells = {
			cab = { 0, 288, 96, 96 },
			camera = { 192, 96, 96, 96 },
			codes = { 96, 96, 96, 96 },
			contacts = { 0, 0, 96, 96 },
			daily = { 288, 0, 96, 96 },
			garage = { 288, 192, 96, 96 },
			gifts = { 0, 96, 96, 96 },
			jobs = { 192, 0, 96, 96 },
			map = { 0, 192, 96, 96 },
			messages = { 96, 0, 96, 96 },
			prestige = { 96, 192, 96, 96 },
			settings = { 288, 96, 96, 96 },
			store = { 192, 192, 96, 96 },
		},
	},
	portraits = {
		image = "rbxassetid://87448343745307",
		cells = {
			bonus = { 384, 0, 128, 128 },
			cab = { 256, 128, 128, 128 },
			crew = { 128, 128, 128, 128 },
			dispatch = { 384, 128, 128, 128 },
			fence = { 256, 0, 128, 128 },
			lawyer = { 128, 0, 128, 128 },
			mechanic = { 0, 0, 128, 128 },
			security = { 0, 128, 128, 128 },
		},
	},
	banners = {
		image = "rbxassetid://107070489184648",
		cells = {
			chop = { 0, 512, 600, 128 },
			dealership = { 0, 128, 600, 128 },
			garage = { 0, 0, 600, 128 },
			gear = { 0, 256, 600, 128 },
			spray = { 0, 384, 600, 128 },
			store = { 0, 640, 600, 128 },
		},
	},
}
-- Phone shell 9-slice (drawn at 2x: SliceScale 0.5) and its transparent screen window (shell px).
UIAssets.PHONE_SLICE = Rect.new(60, 120, 452, 840)
UIAssets.PHONE_SCREEN = { 18, 48, 494, 896 }
-- END GENERATED

-- UI sounds (§5.16). Licensed library audio found on the Creator Store; audition in Studio (checklist item 6).
UIAssets.Sounds = {
	wasted = { id = "rbxassetid://9125404320", volume = 0.8 }, -- "Boom Impact Deep Distant Thumping Hits"
	wastedWhoosh = { id = "rbxassetid://9120704346", volume = 0.6 }, -- "Whoosh Deep Booming Blast Reversed"
	busted = { id = "rbxassetid://9125404320", volume = 0.7 },
	passed = { id = "rbxassetid://1840078221", volume = 0.5, length = 3 }, -- "Building Success (sting)", trimmed
	help = { id = "rbxassetid://139804904213958", volume = 0.35 }, -- "ui_menu_click_03"
	photo = { id = "rbxassetid://9113678227", volume = 0.6 }, -- "Camera Shutter 1"
	vibrate = { id = "rbxassetid://538449705", volume = 0.5 },
} :: { [string]: { id: string, volume: number, length: number? } }

-- The loading-screen panel keys, in show order.
UIAssets.LOADING = { "loading_1", "loading_2", "loading_3", "loading_4", "loading_5", "loading_6" }

return UIAssets
