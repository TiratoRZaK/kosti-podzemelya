class_name Palette
extends RefCounted

## Палитра и типографика. Перенесена из веб-прототипа: тёмно-фиолетовое
## подземелье, золото для своих очков, кровь для чужих, кость для кубов игрока.
##
## Оформление меняем только по явной просьбе: большой редизайн уже один раз
## забраковали, и вернулись именно к этим цветам. Что понравилось и осталось —
## готический титул Ruslan Display с золотым градиентом.

const BG            := Color("0e0a14")
const BG_TOP        := Color("1b1229")
const PANEL         := Color("1c1428")
const PANEL_2       := Color("241a33")
const CELL          := Color("1a1226")   # темнее панели: клетка читается как гнездо
const CELL_EDGE     := Color("56407f")   # 2.0:1 к фону: пустое поле видно, но не спорит с кубами

const BONE          := Color("ead9b6")
const BONE_HI       := Color("fff5da")
const BONE_EDGE     := Color("b09a6e")
const BONE_DEEP     := Color("7d6b47")
const BONE_INK      := Color("2b2114")

const BLOOD         := Color("7e2030")
const BLOOD_HI      := Color("b04355")
const BLOOD_EDGE    := Color("4d1220")
const BLOOD_DEEP    := Color("330c17")
const BLOOD_INK     := Color("f3d3c4")

const GOLD          := Color("d9a13c")
const GOLD_LIGHT    := Color("f0c469")
const GOLD_DEEP     := Color("8a611e")
const CYAN          := Color("62c3c9")
const DANGER        := Color("e14b4b")
const NEG           := Color("ff8a7e")
const TEXT          := Color("e8e0d0")
const MUTED         := Color("a99cc0")   # 6.95:1: подписи в 9-10 px раньше тонули

const FONT_TITLE := "res://assets/fonts/RuslanDisplay-Regular.ttf"
const FONT_UI    := "res://assets/fonts/Manrope-Bold.ttf"

## Дуракуб: у каждой масти своё лицо куба — цвета те же, что в веб-прототипе.
## Порядок совпадает с Durak.SUITS: ♠ ♥ ♦ ♣.
const SUIT_FACE := [
	{"bg": Color("443c59"), "edge": Color("241d33"), "ink": Color("e9e2f4")},
	{"bg": Color("962f3f"), "edge": Color("4d1220"), "ink": Color("ffe3da")},
	{"bg": Color("cf973f"), "edge": Color("7a5116"), "ink": Color("3a2606")},
	{"bg": Color("447a4e"), "edge": Color("1c3d24"), "ink": Color("e2f4de")},
]

## Лицо куба по сиденью: кость, кровь, мох, лазурь. Втроём и вчетвером двух
## цветов не хватает — игрок должен различать, чей куб стоит на клетке.
const SEAT_FACES := [
	{"top": Color("fff5da"), "mid": Color("ead9b6"), "bottom": Color("cdb789"),
	 "edge": Color("b09a6e"), "deep": Color("7d6b47"), "ink": Color("2b2114")},
	{"top": Color("b04355"), "mid": Color("93283a"), "bottom": Color("7e2030"),
	 "edge": Color("4d1220"), "deep": Color("330c17"), "ink": Color("f3d3c4")},
	{"top": Color("6fae74"), "mid": Color("4c8a54"), "bottom": Color("3a6b41"),
	 "edge": Color("1f3d24"), "deep": Color("142a18"), "ink": Color("e6f4e2")},
	{"top": Color("6aa8c8"), "mid": Color("47829f"), "bottom": Color("35657d"),
	 "edge": Color("1d3a48"), "deep": Color("122630"), "ink": Color("e2f0f7")},
]

static func face_of(seat_index: int) -> Dictionary:
	return SEAT_FACES[clampi(seat_index, 0, SEAT_FACES.size() - 1)]

## Цвет ИМЕНИ игрока — не тот же, что цвет его куба.
##
## Красить подпись в `face["mid"]` казалось логичным, но грань куба выбрана под
## объём, а не под чтение мелкого текста: кровавый `#93283a` даёт к панели 2.21:1,
## мох и лазурь — 4.2–4.3:1 при норме 4.5. Имя соперника становилось нечитаемым
## ровно тогда, когда на него смотрят. Здесь те же цвета, поднятые до 5.6–12.8:1.
const SEAT_NAME_COLORS := [
	Color("ead9b6"),   # кость
	Color("d9707f"),   # кровь
	Color("7fc48a"),   # мох
	Color("7cc0e0"),   # лазурь
]

static func name_of(seat_index: int) -> Color:
	return SEAT_NAME_COLORS[clampi(seat_index, 0, SEAT_NAME_COLORS.size() - 1)]

## Лицо куба: у игрока костяное, у соперника кровавое.
static func face(seat_is_player: bool) -> Dictionary:
	if seat_is_player:
		return {
			"top": BONE_HI, "mid": BONE, "bottom": Color("cdb789"),
			"edge": BONE_EDGE, "deep": BONE_DEEP, "ink": BONE_INK,
		}
	return {
		"top": BLOOD_HI, "mid": Color("93283a"), "bottom": BLOOD,
		"edge": BLOOD_EDGE, "deep": BLOOD_DEEP, "ink": BLOOD_INK,
	}
