extends Control

## Экран игры: меню режимов, матч, ширма при передаче устройства, исходы.
##
## Интерфейс собирается кодом — структуру видно целиком, а править .tscn вслепую
## неудобно. Логика лежит в MatchState/Rules/Bot и про интерфейс не знает: здесь
## только показ и ввод.
##
## Снимки для проверки: `--shot=путь.png` рисует кадр и выходит, дополнительно
## `--shot-move` делает ход со съедением и комбо, `--shot-veil` показывает ширму,
## `--shot-menu` оставляет меню. Godot-окно мне не видно, а PNG я читать умею.

const CELL_GAP := 9
const HAND_PX := 74
const BOT_DELAY := 0.7
const BG_TEXTURE := "res://assets/bg/dungeon_bg.png"

var state: Dictionary
var rng := RandomNumberGenerator.new()
var second_is_human := false     # выбор в меню: посадить человека вместо бота
var selected := -1
var busy := false

# узлы
var foe_name: Label
var foe_score: Label
var foe_hearts: Label
var foe_hand_row: HBoxContainer
var turn_info: Label
var turn_who: Label
var board_grid: GridContainer
var sel_info: Label
var hist_strip: HBoxContainer
var card_box: VBoxContainer
var hist_sel := -1        # какая карточка раскрыта; -1 — последний ход
var mode_tag: Label
var toast_label: Label
var banner_label: Label
var rules_layer: Control
var foe_deck: Label
var hint: Dictionary = {}   # подсказка: какой куб и куда даст комбо
var hand_row: HBoxContainer
var my_name: Label
var my_score: Label
var my_hearts: Label
var my_deck: Label
var menu_layer: Control
var veil_layer: Control
var veil_title: Label
var over_layer: Control

var _banner_tween: Tween
var _shot_path := ""
var _shot_mode := ""

func _ready() -> void:
	_parse_args()
	rng.seed = 20260731
	_build_ui()
	_show_menu()
	if _shot_path != "":
		await _shot_scenario()

func _parse_args() -> void:
	for a in OS.get_cmdline_args() + OS.get_cmdline_user_args():
		if a.begins_with("--shot="):
			_shot_path = a.substr(7)
		elif a == "--shot-move":
			_shot_mode = "move"
		elif a == "--shot-veil":
			_shot_mode = "veil"
		elif a == "--shot-menu":
			_shot_mode = "menu"
		elif a == "--shot-rules":
			_shot_mode = "rules"
		elif a == "--shot-round":
			_shot_mode = "round"
		elif a == "--shot-win":
			_shot_mode = "win"
		elif a == "--shot-hotseat-round":
			_shot_mode = "hotseat_round"

# ------------------------------------------------------------------ вид

## Чьими глазами смотрим. Вид привязан к тому, кому ОТКРЫТ экран, а не к тому,
## чей ход: при пасе соперника ход уходит к нему без ширмы, и при привязке к
## turn экран молча показал бы сидящему чужую руку.
func viewer() -> String:
	if state.is_empty():
		return "p"
	if MatchState.shared_device(state):
		var shown := String(state["shown_to"])
		return shown if shown != "" else String(state["turn"])
	return "p"

func input_allowed() -> bool:
	if state.is_empty() or busy or veil_layer.visible or menu_layer.visible:
		return false
	var t := String(state["turn"])
	return MatchState.seat_is_human(state, t) and MatchState.seat_local(state, t) \
		and (not MatchState.shared_device(state) or String(state["shown_to"]) == t)

# --------------------------------------------------------------- построение

func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.color = Palette.BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	# Каменная кладка как фактура. Сгенерированная картинка сама по себе слишком
	# светлая и однородная — белый текст на ней читается хуже, чем на заливке.
	# Поэтому она идёт приглушённой, а сверху ложатся световое пятно и виньетка:
	# фактура видна, но интерфейс остаётся главным.
	if ResourceLoader.exists(BG_TEXTURE):
		var wall := TextureRect.new()
		wall.texture = load(BG_TEXTURE)
		wall.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		wall.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		wall.modulate = Color(0.66, 0.6, 0.82, 0.85)
		add_child(wall)
		var shade := ColorRect.new()
		shade.color = Color(0.05, 0.03, 0.09, 0.42)
		shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		add_child(shade)
	var glow := TextureRect.new()
	glow.texture = _radial_glow()
	glow.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	glow.stretch_mode = TextureRect.STRETCH_SCALE
	glow.modulate = Color(1, 1, 1, 0.55)
	add_child(glow)
	var vign := TextureRect.new()
	vign.texture = _vignette()
	vign.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vign.stretch_mode = TextureRect.STRETCH_SCALE
	add_child(vign)

	var pad := MarginContainer.new()
	pad.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, 14)
	add_child(pad)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	pad.add_child(root)

	root.add_child(_title_block())
	root.add_child(_foe_zone())
	toast_label = _label("", 12, Palette.GOLD_LIGHT)
	toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toast_label.custom_minimum_size.y = 18
	root.add_child(toast_label)
	root.add_child(_turn_bar())
	board_grid = GridContainer.new()
	board_grid.columns = 3
	board_grid.add_theme_constant_override("h_separation", CELL_GAP)
	board_grid.add_theme_constant_override("v_separation", CELL_GAP)
	root.add_child(board_grid)
	sel_info = _label("", 12, Palette.MUTED)
	sel_info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sel_info.custom_minimum_size.y = 32
	sel_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(sel_info)
	# лента ходов: таблетки с номером и итогом, тап раскрывает нужную карточку
	hist_strip = HBoxContainer.new()
	hist_strip.add_theme_constant_override("separation", 6)
	hist_strip.custom_minimum_size.y = 26
	var strip_scroll := ScrollContainer.new()
	strip_scroll.custom_minimum_size.y = 30
	strip_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	strip_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	strip_scroll.add_child(hist_strip)
	root.add_child(strip_scroll)
	# место под карточку хода держим всегда, иначе доска и рука прыгают
	card_box = VBoxContainer.new()
	card_box.custom_minimum_size.y = 92
	card_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(card_box)
	root.add_child(_my_zone())

	menu_layer = _build_menu()
	add_child(menu_layer)
	veil_layer = _build_veil()
	add_child(veil_layer)
	over_layer = _build_overlay()
	add_child(over_layer)
	rules_layer = _build_rules()
	add_child(rules_layer)
	# баннер поверх всего: «РАУНД 2», «500!». Подложка обязательна — без неё
	# цифры кубов читаются сквозь текст
	banner_label = _label("", 20, Palette.GOLD_LIGHT, Palette.FONT_TITLE)
	banner_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var bpanel := PanelContainer.new()
	var bsb := StyleBoxFlat.new()
	bsb.bg_color = Color(0.03, 0.02, 0.05, 0.88)
	bsb.set_corner_radius_all(12)
	bsb.border_color = Color(0.85, 0.63, 0.24, 0.5)
	bsb.set_border_width_all(1)
	bsb.content_margin_left = 18
	bsb.content_margin_right = 18
	bsb.content_margin_top = 10
	bsb.content_margin_bottom = 10
	bpanel.add_theme_stylebox_override("panel", bsb)
	bpanel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	bpanel.z_index = 119
	bpanel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bpanel.name = "BannerPanel"
	# размером label управляет PanelContainer: свои anchors ломали расчёт и панель
	# показывалась пустой рамкой
	bpanel.add_child(banner_label)
	add_child(bpanel)
	bpanel.modulate.a = 0.0

func _title_block() -> Control:
	var box := VBoxContainer.new()
	var t := _label("КОСТИ ПОДЗЕМЕЛЬЯ", 25, Palette.GOLD, Palette.FONT_TITLE)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(t)
	mode_tag = _label("", 10, Palette.MUTED)
	mode_tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(mode_tag)
	return box

func _foe_zone() -> Control:
	var panel := _panel()
	var v := VBoxContainer.new()
	panel.add_child(v)
	var row := HBoxContainer.new()
	v.add_child(row)
	foe_name = _label("", 10, Palette.MUTED)
	row.add_child(foe_name)
	row.add_child(_grow())
	foe_hearts = _label("", 15, Palette.DANGER)
	row.add_child(foe_hearts)
	row.add_child(_grow())
	foe_score = _label("0", 20, Palette.GOLD_LIGHT, Palette.FONT_UI)
	row.add_child(foe_score)
	var row2 := HBoxContainer.new()
	v.add_child(row2)
	foe_hand_row = HBoxContainer.new()
	foe_hand_row.add_theme_constant_override("separation", 6)
	row2.add_child(foe_hand_row)
	row2.add_child(_grow())
	foe_deck = _label("", 10, Palette.MUTED)
	row2.add_child(foe_deck)
	return panel

func _turn_bar() -> Control:
	var row := HBoxContainer.new()
	turn_info = _label("", 10, Palette.MUTED)
	row.add_child(turn_info)
	row.add_child(_grow())
	turn_who = _label("", 10, Palette.GOLD_LIGHT)
	row.add_child(turn_who)
	return row

func _my_zone() -> Control:
	var panel := _panel()
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	panel.add_child(v)
	var row := HBoxContainer.new()
	v.add_child(row)
	my_name = _label("", 10, Palette.MUTED)
	row.add_child(my_name)
	row.add_child(_grow())
	my_hearts = _label("", 15, Palette.DANGER)
	row.add_child(my_hearts)
	row.add_child(_grow())
	my_score = _label("0", 20, Palette.GOLD_LIGHT, Palette.FONT_UI)
	row.add_child(my_score)
	hand_row = HBoxContainer.new()
	hand_row.add_theme_constant_override("separation", 10)
	hand_row.alignment = BoxContainer.ALIGNMENT_CENTER
	hand_row.custom_minimum_size.y = HAND_PX
	v.add_child(hand_row)
	var bottom := HBoxContainer.new()
	v.add_child(bottom)
	my_deck = _label("", 10, Palette.MUTED)
	bottom.add_child(my_deck)
	bottom.add_child(_grow())
	var rules_btn := _button("Правила", true)
	rules_btn.pressed.connect(func(): rules_layer.visible = true)
	bottom.add_child(rules_btn)
	var menu_btn := _button("Меню", true)
	menu_btn.pressed.connect(_show_menu)
	bottom.add_child(menu_btn)
	return panel

# ------------------------------------------------------------------ слои

func _full_dim(alpha: float = 0.92) -> Control:
	var layer := Control.new()
	layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.visible = false
	var dim := ColorRect.new()
	dim.color = Color(0.03, 0.02, 0.05, alpha)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(dim)
	return layer

func _build_menu() -> Control:
	var layer := _full_dim(0.96)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(center)
	var panel := _panel(Palette.PANEL_2)
	center.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	v.custom_minimum_size.x = 320
	panel.add_child(v)
	var t := _label("КОСТИ\nПОДЗЕМЕЛЬЯ", 24, Palette.GOLD, Palette.FONT_TITLE)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(t)
	var hint := _label("Выбери режим", 12, Palette.MUTED)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(hint)

	var toggle := CheckBox.new()
	toggle.text = "2 игрока на одном телефоне"
	toggle.add_theme_font_size_override("font_size", 13)
	toggle.add_theme_color_override("font_color", Palette.TEXT)
	toggle.toggled.connect(func(on: bool): second_is_human = on)
	v.add_child(toggle)

	for key in MatchState.MODE_ORDER:
		v.add_child(_mode_button(key, MatchState.MODES[key]))
	var quit_btn := _button("Выход", true)
	quit_btn.pressed.connect(func(): get_tree().quit())
	v.add_child(quit_btn)
	return layer

## Кнопка режима: название и описание отдельными строками с переносом.
## Это PanelContainer, а не Button: у кнопки высоту приходится задавать руками, и
## описание в две строки вылезало за её край. Контейнер подстраивается сам.
func _mode_button(key: String, cfg: Dictionary) -> Control:
	var box := PanelContainer.new()
	box.add_theme_stylebox_override("panel", _mode_box())
	box.custom_minimum_size.x = 300
	box.mouse_filter = Control.MOUSE_FILTER_STOP
	box.gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			_start_mode(key)
	)
	var inner := VBoxContainer.new()
	inner.add_theme_constant_override("separation", 3)
	inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(inner)
	inner.add_child(_label(String(cfg["title"]), 13, Palette.GOLD_LIGHT))
	var s := _label(String(cfg["sub"]), 11, Palette.MUTED)
	s.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	s.custom_minimum_size.x = 268
	s.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner.add_child(s)
	return box

func _build_veil() -> Control:
	# ширма плотная: сквозь неё не должно просвечивать поле с чужими ловушками
	var layer := _full_dim(1.0)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(center)
	var panel := _panel(Palette.PANEL_2)
	center.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	v.custom_minimum_size.x = 300
	panel.add_child(v)
	var hand := _label("🖐", 44, Palette.GOLD_LIGHT)
	hand.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(hand)
	veil_title = _label("", 20, Palette.GOLD, Palette.FONT_TITLE)
	veil_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(veil_title)
	var sub := _label("Передай устройство и не подглядывай.", 12, Palette.MUTED)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(sub)
	var b := _button("Я готов")
	b.pressed.connect(_hide_veil)
	v.add_child(b)
	return layer

## Экран правил. Способности показаны сгенерированными иконками — здесь они
## крупные (44px) и читаются, в отличие от значка на кубе, где остаются эмодзи.
const ABILITY_ICONS := {
	"shield": "res://assets/icons/icon_shield.png",
	"spikes": "res://assets/icons/icon_spiked_ball.png",
	"mine": "res://assets/icons/icon_bomb.png",
	"jaw": "res://assets/icons/icon_jaw.png",
	"friendly": "res://assets/icons/icon_handshake.png",
	"warlock": "res://assets/icons/icon_orb.png",
}
const ABILITY_TEXT := {
	"shield": "Два хода соперника его нельзя съесть — даже колдуном.",
	"spikes": "Скрыт от соперника. Съевший теряет 10 очков.",
	"mine": "Скрыта. Уничтожает себя и атакующего, ход сгорает.",
	"jaw": "При выставлении съедает вражеский куб справа.",
	"friendly": "Прибавляет к себе сумму значений соседей, максимум 12.",
	"warlock": "Ест куб любого значения и копирует его. Щит не пробивает.",
}

func _build_rules() -> Control:
	var layer := _full_dim(0.96)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(center)
	var panel := _panel(Palette.PANEL_2)
	center.add_child(panel)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(330, 640)
	panel.add_child(scroll)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	v.custom_minimum_size.x = 314
	scroll.add_child(v)

	var t := _label("Правила", 24, Palette.GOLD, Palette.FONT_TITLE)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(t)
	v.add_child(_rules_head("Ход"))
	v.add_child(_rules_line("Выбери куб в руке и поставь на пустую клетку или съешь вражеский."))
	v.add_child(_rules_line("Базовый куб ест куб со значением не больше своего: шестёрка ест всех, единица — только единицу."))
	v.add_child(_rules_head("Очки за ход"))
	v.add_child(_rules_line("Съел — значение съеденного куба."))
	v.add_child(_rules_line("Кубы на поле — сумма значений всех твоих кубов, начисляется каждый ход."))
	v.add_child(_rules_line("Комбо из твоих кубов: пара +5, две пары +10, сет +15, фулл-хаус +25, каре +40, пятёрка +60, шестёрка +100."))
	v.add_child(_rules_head("Особые кубы"))
	for key in ["shield", "spikes", "mine", "jaw", "friendly", "warlock"]:
		v.add_child(_ability_row(key))
	var b := _button("Понятно")
	b.pressed.connect(func(): rules_layer.visible = false)
	v.add_child(b)
	return layer

func _rules_head(text: String) -> Control:
	var l := _label(text, 14, Palette.GOLD_LIGHT, Palette.FONT_TITLE)
	l.custom_minimum_size.y = 26
	return l

func _rules_line(text: String) -> Control:
	var l := _label("• " + text, 12, Palette.TEXT)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size.x = 300
	return l

func _ability_row(key: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var path := String(ABILITY_ICONS[key])
	if ResourceLoader.exists(path):
		var ic := TextureRect.new()
		ic.texture = load(path)
		ic.custom_minimum_size = Vector2(44, 44)
		ic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		ic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		row.add_child(ic)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 1)
	row.add_child(col)
	col.add_child(_label(String(Rules.TYPES[key]["name"]), 12, Palette.GOLD_LIGHT))
	var d := _label(String(ABILITY_TEXT[key]), 11, Palette.MUTED)
	d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	d.custom_minimum_size.x = 246
	col.add_child(d)
	return row

func _build_overlay() -> Control:
	var layer := _full_dim(0.9)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(center)
	var panel := _panel(Palette.PANEL_2)
	panel.name = "Panel"
	center.add_child(panel)
	var v := VBoxContainer.new()
	v.name = "Box"
	v.add_theme_constant_override("separation", 10)
	v.custom_minimum_size.x = 300
	panel.add_child(v)
	return layer

# ----------------------------------------------------------------- меню

func _show_menu() -> void:
	menu_layer.visible = true
	veil_layer.visible = false
	over_layer.visible = false

func _start_mode(key: String) -> void:
	menu_layer.visible = false
	over_layer.visible = false
	selected = -1
	state = MatchState.new_match(key, int(Time.get_unix_time_from_system()) & 0x7fffffff, second_is_human)
	board_grid.columns = int(state["cfg"]["cols"])
	hist_sel = -1
	mode_tag.text = String(state["cfg"]["title"]).to_upper()
	for c in card_box.get_children():
		c.queue_free()
	toast("")
	_refresh()
	banner("РАУНД %d" % int(state["round"]))
	_begin_turn(String(state["turn"]))

## Единая точка передачи хода: бот, ширма или ожидание ввода. Сетевой игрок
## позже добавляется сюда же — ещё одной ветвью по типу сиденья.
func _begin_turn(seat: String) -> void:
	selected = -1
	if MatchState.seat_kind(state, seat) == "bot":
		busy = true
		_refresh()
		await get_tree().create_timer(BOT_DELAY).timeout
		if state.is_empty():
			return
		var mv := Bot.choose_move(state, seat, rng)
		if mv.is_empty():
			_after_move()
			return
		await _do_move(seat, int(mv["hand"]), int(mv["cell"]))
		return
	if MatchState.needs_veil(state, seat):
		_show_veil(seat)
		return
	state["shown_to"] = seat
	busy = false
	_refresh()

func _show_veil(seat: String) -> void:
	busy = true
	selected = -1
	veil_title.text = "%s, твой ход" % MatchState.seat_name(state, seat)
	veil_layer.visible = true
	_refresh()

func _hide_veil() -> void:
	veil_layer.visible = false
	state["shown_to"] = String(state["turn"])
	busy = false
	_refresh()

func _hide_banner() -> void:
	# баннер живёт своей анимацией и успевает наложиться на кнопки оверлея.
	# Гасить одну альфу недостаточно — твин её тут же поднимает обратно.
	if _banner_tween != null and _banner_tween.is_valid():
		_banner_tween.kill()
	var panel := get_node_or_null("BannerPanel")
	if panel != null:
		panel.modulate.a = 0.0

func _show_result(title: String, detail: String, button: String, on_press: Callable) -> void:
	_hide_banner()
	var box: VBoxContainer = over_layer.get_node("CenterContainer/Panel/Box") if over_layer.has_node("CenterContainer/Panel/Box") else null
	if box == null:
		# CenterContainer добавляется без имени, ищем по типу
		for c in over_layer.get_children():
			if c is CenterContainer:
				box = c.get_child(0).get_child(0)
	for c in box.get_children():
		c.queue_free()
	var t := _label(title, 22, Palette.GOLD, Palette.FONT_TITLE)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(t)
	var d := _label(detail, 13, Palette.TEXT)
	d.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(d)
	var b := _button(button)
	b.pressed.connect(func():
		over_layer.visible = false
		on_press.call()
	)
	box.add_child(b)
	var m := _button("В меню", true)
	m.pressed.connect(_show_menu)
	box.add_child(m)
	over_layer.visible = true

# ------------------------------------------------------------- отображение

func _refresh() -> void:
	if state.is_empty():
		return
	var cfg: Dictionary = state["cfg"]
	var me := viewer()
	var foe := MatchState.other_seat(state, me)
	my_name.text = MatchState.seat_name(state, me).to_upper()
	foe_name.text = MatchState.seat_name(state, foe).to_upper()
	var kind := String(cfg["kind"])
	my_score.text = _score_text(me, kind, cfg)
	foe_score.text = _score_text(foe, kind, cfg)
	my_score.add_theme_color_override("font_color",
		Palette.NEG if int(state["players"][me]["score"]) < 0 else Palette.GOLD_LIGHT)
	if kind == "lives":
		my_hearts.text = _hearts(int(state["players"][me]["lives"]))
		foe_hearts.text = _hearts(int(state["players"][foe]["lives"]))
	elif kind == "bo3":
		my_hearts.text = _stars(int(state["players"][me]["wins"]))
		foe_hearts.text = _stars(int(state["players"][foe]["wins"]))
	else:
		my_hearts.text = ""
		foe_hearts.text = ""
	my_deck.text = "Колода: %d" % state["players"][me]["deck"].size()
	var turn := String(state["turn"])
	var move_no: int = mini(int(state["players"][turn]["moves"]) + 1, int(cfg["moves"]))
	turn_info.text = "РАУНД %d · ХОД %d/%d" % [int(state["round"]), move_no, int(cfg["moves"])]
	var vs_bot := MatchState.seat_kind(state, "e") == "bot"
	if turn == me and vs_bot:
		turn_who.text = "ТВОЙ ХОД"
	else:
		turn_who.text = "ХОД: " + MatchState.seat_name(state, turn).to_upper()
	turn_who.add_theme_color_override("font_color", Palette.GOLD_LIGHT if turn == me else Palette.NEG)

	for c in foe_hand_row.get_children():
		c.queue_free()
	for i in state["players"][foe]["hand"].size():
		var back := Panel.new()
		back.custom_minimum_size = Vector2(22, 22)
		back.add_theme_stylebox_override("panel", _mini_box())
		foe_hand_row.add_child(back)

	foe_deck.text = "Колода: %d" % state["players"][foe]["deck"].size()
	hint = _find_hint(me) if input_allowed() and String(state["turn"]) == me else {}
	_rebuild_board(me)
	_rebuild_hand(me)
	_rebuild_history()
	_update_sel_info(me)

## Лента ходов. Таблетка показывает номер и итог хода; при взрыве мины — 💥,
## как в веб-версии. Тап раскрывает карточку этого хода.
func _rebuild_history() -> void:
	for c in hist_strip.get_children():
		c.queue_free()
	var hist: Array = state["history"]
	var sel_idx := hist_sel if (hist_sel >= 0 and hist_sel < hist.size()) else hist.size() - 1
	for i in hist.size():
		var m: Dictionary = hist[i]
		var foe: bool = String(m["who"]) != viewer()
		var pill := PanelContainer.new()
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(1, 0.33, 0.4, 0.12) if foe else Color(1, 1, 1, 0.05)
		if i == sel_idx:
			sb.border_color = Palette.DANGER if foe else Palette.GOLD
			sb.set_border_width_all(2)
		else:
			sb.border_color = Palette.CELL_EDGE
			sb.set_border_width_all(1)
		sb.set_corner_radius_all(8)
		sb.content_margin_left = 8
		sb.content_margin_right = 8
		sb.content_margin_top = 2
		sb.content_margin_bottom = 2
		pill.add_theme_stylebox_override("panel", sb)
		pill.mouse_filter = Control.MOUSE_FILTER_STOP
		pill.gui_input.connect(func(e: InputEvent):
			if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
				hist_sel = i
				_show_card(hist[i])
				_rebuild_history()
		)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		pill.add_child(row)
		var n := _label(str(int(m["n"])), 10, Palette.MUTED)
		n.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(n)
		var pts := int(m["pts"])
		var val := _label("💥" if bool(m["mined"]) else str(absi(pts)), 10,
			Palette.NEG if pts < 0 else Palette.GOLD_LIGHT)
		val.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(val)
		hist_strip.add_child(pill)

func _score_text(seat: String, kind: String, cfg: Dictionary) -> String:
	var sc := int(state["players"][seat]["score"])
	if kind == "race":
		return "%d/%d" % [sc, int(cfg["target"])]
	if String(cfg.get("win_by", "")) == "count":
		var n := Rules.owner_count(state["board"], seat)
		return "%d %s · %d очк." % [n, _plural(n, "куб", "куба", "кубов"), sc]
	return str(sc)

func _rebuild_board(me: String) -> void:
	for c in board_grid.get_children():
		c.queue_free()
	var cols := int(state["cfg"]["cols"])
	var cell_w: float = (390.0 - 28.0 - CELL_GAP * (cols - 1)) / float(cols)
	var valid := _valid_cells(me)
	var hint_cell: int = int(hint.get("cell", -1)) if (not hint.is_empty() and selected == int(hint.get("hand", -1))) else -1
	for i in state["board"].size():
		var slot := Panel.new()
		slot.custom_minimum_size = Vector2(cell_w, cell_w)
		slot.add_theme_stylebox_override("panel", _cell_box(valid.has(i), state["board"][i] != null, i == hint_cell))
		slot.mouse_filter = Control.MOUSE_FILTER_STOP
		slot.gui_input.connect(_on_cell_input.bind(i))
		board_grid.add_child(slot)
		var cell = state["board"][i]
		if cell != null:
			var d := DieView.new()
			d.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
			var inset := cell_w * 0.08
			d.offset_left = inset
			d.offset_top = inset
			d.offset_right = -inset
			d.offset_bottom = -inset
			d.mouse_filter = Control.MOUSE_FILTER_IGNORE
			slot.add_child(d)
			# скрытый тип виден только владельцу и только его глазами
			var hidden: bool = bool(Rules.TYPES[String(cell["type"])]["hidden"])
			var seen: bool = String(cell["owner"]) == me
			d.setup(int(cell["v"]), String(cell["type"]), String(cell["owner"]) == me,
				not hidden or seen, int(cell["shield"]))

func _rebuild_hand(me: String) -> void:
	for c in hand_row.get_children():
		c.queue_free()
	var hand: Array = state["players"][me]["hand"]
	var can := input_allowed() and String(state["turn"]) == me
	for i in hand.size():
		var die: Dictionary = hand[i]
		var d := DieView.new()
		d.custom_minimum_size = Vector2(HAND_PX, HAND_PX)
		d.clickable = can
		# в своей руке владелец видит всё, включая ловушки
		d.setup(int(die["value"]), String(die["type"]), me == "p", true)
		d.pressed.connect(_on_hand_pressed.bind(i))
		hand_row.add_child(d)
		if i == selected:
			d.set_selected(true)
		elif not hint.is_empty() and i == int(hint["hand"]):
			d.play_hint()   # пульсирует, пока игрок не выбрал что-то сам

func _update_sel_info(me: String) -> void:
	if not input_allowed():
		var turn := String(state["turn"])
		sel_info.text = "Соперник думает…" if MatchState.seat_kind(state, turn) == "bot" else "Секунду…"
		return
	if selected >= 0:
		var hand: Array = state["players"][me]["hand"]
		if selected < hand.size():
			if not hint.is_empty() and selected == int(hint["hand"]):
				sel_info.text = "💡 Поставь на светящуюся клетку — %s +%d!" % [String(hint["name"]), int(hint["bonus"])]
				return
			var die: Dictionary = hand[selected]
			var t: Dictionary = Rules.TYPES[String(die["type"])]
			sel_info.text = "%s %d — выбери подсвеченную клетку." % [String(t["name"]), int(die["value"])]
			return
	if not hint.is_empty():
		sel_info.text = "💡 Светящийся куб соберёт %s +%d!" % [String(hint["name"]), int(hint["bonus"])]
		return
	sel_info.text = "Выбери куб в руке."

func _valid_cells(me: String) -> Array:
	if not input_allowed() or selected < 0 or String(state["turn"]) != me:
		return []
	var hand: Array = state["players"][me]["hand"]
	if selected >= hand.size():
		return []
	return Rules.legal_targets(state["board"], hand[selected], me)

# ------------------------------------------------------------------- ввод

func _on_hand_pressed(_d: DieView, idx: int) -> void:
	if not input_allowed():
		return
	selected = -1 if selected == idx else idx
	_refresh()

func _on_cell_input(event: InputEvent, idx: int) -> void:
	if not input_allowed() or selected < 0:
		return
	if not (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
		return
	if not _valid_cells(viewer()).has(idx):
		return
	await _do_move(String(state["turn"]), selected, idx)

# -------------------------------------------------------------------- ход

func _do_move(seat: String, hand_idx: int, cell_idx: int) -> void:
	busy = true
	selected = -1
	var res := MatchState.play(state, seat, hand_idx, cell_idx)
	_refresh()
	_animate_place(int(res["placed"]))
	if bool(res["mined"]):
		_boom(res["boom"])
		toast("Мина! Ход сгорел", seat != viewer())
	var combo: Dictionary = res["combo"]
	if not combo.is_empty() and int(combo["bonus"]) >= 25:
		_combo_flash()
	await _play_card(res)
	_after_move()

func _after_move() -> void:
	var ev := MatchState.advance(state)
	match String(ev["event"]):
		"round_end":
			var out := MatchState.close_round(state)
			_refresh()   # жизни и звёзды уже списаны — показать до оверлея
			var final := MatchState.match_outcome(state)
			if bool(out["match_over"]):
				busy = true
				var fin := _match_phrases(String(final["winner"]))
				_show_result(String(fin["title"]), String(fin["text"]), "Ещё раз",
					func(): _start_mode(String(state["mode"])))
				return
			busy = true
			var rp := _round_phrases(String(out["winner"]), String(out["detail"]))
			_show_result(String(rp["title"]), String(rp["text"]), "Следующий раунд", func():
				MatchState.new_round(state)
				hist_sel = -1
				for c in card_box.get_children():
					c.queue_free()
				toast("")
				_refresh()
				banner("РАУНД %d" % int(state["round"]))
				_begin_turn(String(state["turn"]))
			)
		"pass":
			toast("%s: нет ходов — пас" % MatchState.seat_name(state, String(ev["seat"])),
				String(ev["seat"]) != viewer())
			_refresh()
			await get_tree().create_timer(0.9).timeout
			_after_move()
		"turn":
			await _begin_turn(String(ev["seat"]))

## Фразы исхода раунда. Против бота обращаемся на «ты», между людьми — по именам,
## и всегда говорим, что именно произошло, а не только счёт.
func _round_phrases(winner: String, detail: String) -> Dictionary:
	var vs_bot := MatchState.seat_kind(state, "e") == "bot"
	if winner == "":
		return {"title": "НИЧЬЯ В РАУНДЕ", "text": detail + " — никто не теряет ♥"}
	var loser := MatchState.other_seat(state, winner)
	var title := ""
	if vs_bot:
		title = "РАУНД ТВОЙ!" if winner == "p" else "РАУНД ЗА ВРАГОМ"
	else:
		title = MatchState.seat_name(state, winner).to_upper() + " БЕРЁТ РАУНД"
	var text := detail
	if String(state["cfg"]["kind"]) == "lives":
		var who := "ты теряешь" if (vs_bot and loser == "p") else \
			("враг теряет" if vs_bot else MatchState.seat_name(state, loser) + " теряет")
		text = "%s — %s ♥" % [detail, who]
	elif String(state["cfg"]["kind"]) == "bo3":
		text = "%s · победы %d : %d" % [detail,
			int(state["players"]["p"]["wins"]), int(state["players"]["e"]["wins"])]
	return {"title": title, "text": text}

## Фразы конца матча. «Победа / Жизни 3:0» звучало как отчёт судьи, поэтому
## говорим человеческим языком: кто и почему выиграл.
func _match_phrases(winner: String) -> Dictionary:
	var vs_bot := MatchState.seat_kind(state, "e") == "bot"
	var kind := String(state["cfg"]["kind"])
	var p_name := MatchState.seat_name(state, "p")
	var e_name := MatchState.seat_name(state, "e")
	var title := "НИЧЬЯ"
	if winner != "":
		if vs_bot:
			title = "ПОБЕДА!" if winner == "p" else "ПОРАЖЕНИЕ"
		else:
			title = MatchState.seat_name(state, winner).to_upper() + " ПОБЕДИЛ!"
	var text := ""
	match kind:
		"lives":
			if winner == "":
				text = "Жизни кончились у обоих одновременно."
			elif vs_bot:
				text = "Враг повержен!" if winner == "p" else "Подземелье забрало твои кости."
			else:
				text = "%s остался без жизней." % MatchState.other_seat(state, winner).replace("p", p_name).replace("e", e_name)
		"race":
			var target := int(state["cfg"]["target"])
			var sp := int(state["players"]["p"]["score"])
			var se := int(state["players"]["e"]["score"])
			if winner == "":
				text = "Ничья: %d : %d" % [sp, se]
			else:
				var who := "Ты добежал" if (vs_bot and winner == "p") else \
					("Враг добежал" if vs_bot else MatchState.seat_name(state, winner) + " добежал")
				text = "%s до %d! Итог %d : %d" % [who, target, sp, se]
		_:
			var wp := int(state["players"]["p"]["wins"])
			var we := int(state["players"]["e"]["wins"])
			if wp != we:
				var w := maxi(wp, we)
				var who2 := "Ты взял" if (vs_bot and winner == "p") else \
					("Враг взял" if vs_bot else MatchState.seat_name(state, winner) + " взял")
				text = "%s %d %s из 3." % [who2, w, _plural(w, "раунд", "раунда", "раундов")]
			else:
				text = "Раунды поделили %d : %d, решили очки за матч: %d : %d" % [wp, we,
					int(state["players"]["p"]["total"]), int(state["players"]["e"]["total"])]
	return {"title": title, "text": text}

## Согласование числа: 1 куб, 2 куба, 5 кубов.
func _plural(n: int, one: String, few: String, many: String) -> String:
	var m10 := n % 10
	var m100 := n % 100
	if m10 == 1 and m100 != 11:
		return one
	if m10 >= 2 and m10 <= 4 and (m100 < 10 or m100 >= 20):
		return few
	return many

func _animate_place(cell_idx: int) -> void:
	if cell_idx < 0 or cell_idx >= board_grid.get_child_count():
		return
	for c in board_grid.get_child(cell_idx).get_children():
		if c is DieView:
			c.play_place()

## Карточка выбранного хода из ленты — без анимации, просто показать.
func _show_card(record: Dictionary) -> void:
	for c in card_box.get_children():
		c.queue_free()
	var panel := _panel(Palette.PANEL_2)
	card_box.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	panel.add_child(v)
	var head := HBoxContainer.new()
	v.add_child(head)
	var seat := String(record["who"])
	var who := MatchState.seat_name(state, seat).to_upper()
	if seat == "p" and MatchState.seat_kind(state, "e") == "bot":
		who = "ТВОЙ ХОД"
	var htext := "%s %d" % [who, int(record["n"])] if who == "ТВОЙ ХОД" 		else "%s · ХОД %d" % [who, int(record["n"])]
	head.add_child(_label(htext, 10, Palette.GOLD_LIGHT))
	head.add_child(_grow())
	var pts := int(record["pts"])
	var total := _label("💥 0" if bool(record["mined"]) else str(absi(pts)), 22,
		Palette.NEG if pts < 0 else Palette.GOLD_LIGHT, Palette.FONT_UI)
	head.add_child(total)
	var chips := HFlowContainer.new()
	chips.add_theme_constant_override("h_separation", 6)
	chips.add_theme_constant_override("v_separation", 6)
	v.add_child(chips)
	for p in record["parts"]:
		chips.add_child(_chip(p))

## Карточка хода: жетоны появляются по одному, число летит из клетки в свой
## жетон, итог проявляется последним. Порядок важен — итог, обогнавший
## последний жетон, читается как ошибка подсчёта.
func _play_card(res: Dictionary) -> void:
	for c in card_box.get_children():
		c.queue_free()
	var panel := _panel(Palette.PANEL_2)
	card_box.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	panel.add_child(v)
	var head := HBoxContainer.new()
	v.add_child(head)
	var seat := String(res["seat"])
	var who := MatchState.seat_name(state, seat).to_upper()
	if seat == "p" and MatchState.seat_kind(state, "e") == "bot":
		who = "ТВОЙ ХОД"
	var head_text := "%s %d" % [who, state["history"].size()] if who == "ТВОЙ ХОД" 		else "%s · ХОД %d" % [who, state["history"].size()]
	head.add_child(_label(head_text, 10, Palette.GOLD_LIGHT))
	head.add_child(_grow())
	var total := _label("", 22, Palette.GOLD_LIGHT, Palette.FONT_UI)
	total.modulate.a = 0.0
	head.add_child(total)
	# жетоны переносятся на вторую строку: в один ряд четыре штуки не влезают и
	# карточка вылезала за край экрана
	var chips := HFlowContainer.new()
	chips.add_theme_constant_override("h_separation", 6)
	chips.add_theme_constant_override("v_separation", 6)
	v.add_child(chips)

	var parts: Array = res["parts"]
	for p in parts:
		var chip := _chip(p)
		chip.modulate.a = 0.0
		chip.pivot_offset = Vector2(20, 12)
		chip.scale = Vector2(0.7, 0.7)
		chips.add_child(chip)
	# ждём раскладки: до неё позиции жетонов нулевые и числу некуда лететь
	await get_tree().process_frame
	await get_tree().process_frame

	for i in parts.size():
		var p: Dictionary = parts[i]
		var chip: Control = chips.get_child(i)
		if p.has("hl"):
			for ci in p["hl"]:
				_glow_cell(int(ci))
		if p.has("v") and not p.get("die", false):
			await _fly_number(p, chip, seat)
		_pop_in(chip)
		await get_tree().create_timer(0.16).timeout

	var pts := int(res["pts"])
	total.text = "💥 0" if bool(res["mined"]) else str(absi(pts))
	total.add_theme_color_override("font_color", Palette.NEG if pts < 0 else Palette.GOLD_LIGHT)
	await get_tree().create_timer(0.1).timeout
	_pop_in(total, 1.3)

## Короткое сообщение под зоной соперника: пас, взрыв, исход кона.
func toast(text: String, foe: bool = false) -> void:
	toast_label.text = text
	toast_label.add_theme_color_override("font_color", Palette.NEG if foe else Palette.GOLD_LIGHT)

## Баннер по центру: «РАУНД 2», «500!». Живёт полторы секунды и гаснет.
func banner(text: String) -> void:
	banner_label.text = text
	var panel: Control = get_node("BannerPanel")
	if _banner_tween != null and _banner_tween.is_valid():
		_banner_tween.kill()
	panel.scale = Vector2(0.7, 0.7)
	panel.pivot_offset = panel.size * 0.5
	_banner_tween = create_tween()
	_banner_tween.tween_property(panel, "modulate:a", 1.0, 0.12)
	_banner_tween.parallel().tween_property(panel, "scale", Vector2(1.06, 1.06), 0.16).set_ease(Tween.EASE_OUT)
	_banner_tween.tween_property(panel, "scale", Vector2.ONE, 0.1)
	_banner_tween.tween_interval(0.85)
	_banner_tween.tween_property(panel, "modulate:a", 0.0, 0.3)

## Тактильный отклик. На настольных платформах ничего не делает.
func buzz(pattern_ms: int) -> void:
	Input.vibrate_handheld(pattern_ms)

## Взрыв мины: вспышка клетки и знак поверх неё.
func _boom(cells: Array) -> void:
	buzz(180)
	for ci in cells:
		var idx := int(ci)
		if idx < 0 or idx >= board_grid.get_child_count():
			continue
		var slot: Control = board_grid.get_child(idx)
		var flash := ColorRect.new()
		flash.color = Color(1, 0.66, 0.24, 0.9)
		flash.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(flash)
		var tw := create_tween()
		tw.tween_property(flash, "color", Color(0.9, 0.25, 0.15, 0.0), 0.55)
		tw.tween_callback(flash.queue_free)
	if not cells.is_empty():
		var first := int(cells[0])
		if first < board_grid.get_child_count():
			var slot2: Control = board_grid.get_child(first)
			var mark := _label("💥", 30, Palette.GOLD_LIGHT)
			add_child(mark)
			mark.global_position = slot2.global_position + slot2.size * 0.5 - Vector2(18, 18)
			mark.z_index = 110
			var tw2 := create_tween()
			tw2.tween_property(mark, "global_position:y", mark.global_position.y - 40.0, 0.9)
			tw2.parallel().tween_property(mark, "modulate:a", 0.0, 0.9)
			tw2.tween_callback(mark.queue_free)

## Вспышка всей доски: комбо от фулл-хауса и выше.
func _combo_flash() -> void:
	buzz(60)
	var flash := ColorRect.new()
	flash.color = Color(1, 0.92, 0.7, 0.32)
	flash.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	board_grid.add_child(flash)
	var tw := create_tween()
	tw.tween_property(flash, "color", Color(1, 0.92, 0.7, 0.0), 0.65)
	tw.tween_callback(flash.queue_free)

## Подсказка: куб в руке, который поднимет комбо минимум на +10, и клетка под
## него. Помогает новичку увидеть, ради чего вообще собирать кубы.
func _find_hint(seat: String) -> Dictionary:
	var hand: Array = state["players"][seat]["hand"]
	var cur := int(Rules.combo_bonus(Rules.owner_vals(state["board"], seat))["bonus"])
	var best := {}
	for hi in hand.size():
		var die: Dictionary = hand[hi]
		for ci in Rules.legal_targets(state["board"], die, seat):
			var b := []
			for cell in state["board"]:
				b.append(null if cell == null else cell.duplicate())
			var v := int(die["value"])
			if b[ci] != null and String(die["type"]) == "warlock":
				v = int(b[ci]["v"])
			b[ci] = {"v": v, "type": String(die["type"]), "owner": seat, "shield": 0}
			if String(die["type"]) == "friendly":
				b[ci]["v"] = mini(v + Rules.neighbor_sum(b, ci, int(state["cols"]), b.size()), Rules.FRIENDLY_CAP)
			var cb := Rules.combo_bonus(Rules.owner_vals(b, seat))
			var gainedbonus := int(cb["bonus"]) - cur
			if gainedbonus >= 10 and (best.is_empty() or int(cb["bonus"]) > int(best["bonus"])):
				best = {"hand": hi, "cell": ci, "bonus": int(cb["bonus"]), "name": String(cb["name"]).replace("!", "")}
	return best

func _glow_cell(idx: int) -> void:
	if idx < 0 or idx >= board_grid.get_child_count():
		return
	for c in board_grid.get_child(idx).get_children():
		if c is DieView:
			c.play_glow()

func _fly_number(part: Dictionary, chip: Control, seat: String) -> void:
	var src: Vector2 = chip.global_position + chip.size * 0.5
	var from_cell := int(part.get("ci", -1))
	if from_cell >= 0 and from_cell < board_grid.get_child_count():
		var slot: Control = board_grid.get_child(from_cell)
		src = slot.global_position + slot.size * 0.5
	var neg: bool = bool(part.get("neg", false))
	var col := Palette.NEG if (neg or seat == "e") else Palette.GOLD_LIGHT
	var fly := _label("%s%d" % ["−" if neg else "+", int(part["v"])], 17, col, Palette.FONT_UI)
	add_child(fly)
	fly.global_position = src
	fly.z_index = 100
	var dst: Vector2 = chip.global_position + chip.size * 0.5
	var tw := create_tween().set_parallel(true)
	tw.tween_property(fly, "global_position", dst, 0.32).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_CUBIC)
	tw.tween_property(fly, "scale", Vector2(0.7, 0.7), 0.32)
	tw.tween_property(fly, "modulate:a", 0.15, 0.32)
	await tw.finished
	fly.queue_free()

func _pop_in(node: Control, overshoot: float = 1.12) -> void:
	node.modulate.a = 1.0
	var tw := create_tween()
	tw.tween_property(node, "scale", Vector2(overshoot, overshoot), 0.10).set_ease(Tween.EASE_OUT)
	tw.tween_property(node, "scale", Vector2.ONE, 0.12)

# ------------------------------------------------------- снимки для проверки

func _shot_scenario() -> void:
	match _shot_mode:
		"menu":
			pass
		"rules":
			_start_mode("classic")
			rules_layer.visible = true
		"round", "win", "hotseat_round":
			# доигрываем раунд до исхода, чтобы на кадр попали сами фразы
			second_is_human = (_shot_mode == "hotseat_round")
			_start_mode("classic")
			state["players"]["p"]["score"] = 34
			state["players"]["e"]["score"] = 12
			if _shot_mode == "win":
				state["players"]["e"]["lives"] = 1
			for seat in state["order"]:
				state["players"][seat]["moves"] = int(state["cfg"]["moves"])
			veil_layer.visible = false
			_after_move()
			await get_tree().process_frame
		"veil":
			second_is_human = true
			_start_mode("classic")
			await get_tree().process_frame
		"move":
			_start_mode("classic")
			state["board"][0] = {"v": 2, "type": "basic", "owner": "e", "shield": 0}
			state["board"][3] = {"v": 4, "type": "basic", "owner": "p", "shield": 0}
			state["board"][4] = {"v": 4, "type": "basic", "owner": "p", "shield": 0}
			state["board"][5] = {"v": 6, "type": "shield", "owner": "e", "shield": 2}
			state["players"]["p"]["hand"][0] = {"value": 4, "type": "basic"}
			state["shown_to"] = "p"
			selected = 0
			_refresh()
			var res := MatchState.play(state, "p", 0, 0)
			_refresh()
			_animate_place(int(res["placed"]))
			await _play_card(res)
		_:
			_start_mode("classic")
	for i in 4:
		await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	img.save_png(_shot_path)
	print("снимок: ", _shot_path)
	get_tree().quit()

# ------------------------------------------------------------ вспомогательное

func _label(text: String, size_px: int, col: Color, font_path: String = "") -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size_px)
	l.add_theme_color_override("font_color", col)
	if font_path != "" and ResourceLoader.exists(font_path):
		l.add_theme_font_override("font", load(font_path))
	return l

func _button(text: String, ghost: bool = false) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", 13)
	b.custom_minimum_size.y = 40 if not ghost else 32
	var sb := StyleBoxFlat.new()
	if ghost:
		sb.bg_color = Color(1, 1, 1, 0.05)
		sb.border_color = Palette.CELL_EDGE
		b.add_theme_color_override("font_color", Palette.MUTED)
	else:
		sb.bg_color = Palette.GOLD
		b.add_theme_color_override("font_color", Color("1d1206"))
	sb.set_corner_radius_all(10)
	sb.set_border_width_all(2 if ghost else 0)
	sb.content_margin_left = 16
	sb.content_margin_right = 16
	b.add_theme_stylebox_override("normal", sb)
	b.add_theme_stylebox_override("hover", sb)
	b.add_theme_stylebox_override("pressed", sb)
	return b

func _grow() -> Control:
	var c := Control.new()
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return c

func _panel(bg: Color = Palette.PANEL) -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(12)
	sb.border_color = Palette.CELL_EDGE
	sb.set_border_width_all(2)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	p.add_theme_stylebox_override("panel", sb)
	return p

func _mode_box(pressed: bool = false) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Palette.PANEL if not pressed else Palette.CELL
	sb.set_corner_radius_all(10)
	sb.border_color = Palette.CELL_EDGE
	sb.set_border_width_all(2)
	sb.content_margin_left = 10
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	return sb

func _cell_box(valid: bool, has_die: bool, hinted: bool = false) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Palette.CELL
	sb.set_corner_radius_all(12)
	sb.set_border_width_all(3)
	sb.border_color = Palette.CELL_EDGE
	if valid:
		sb.border_color = Palette.DANGER if has_die else Palette.GOLD
	if hinted:
		# подсказанная клетка светится ярче остальных
		sb.border_color = Palette.GOLD_LIGHT
		sb.set_border_width_all(4)
		sb.shadow_color = Color(1, 0.86, 0.45, 0.5)
		sb.shadow_size = 8
	return sb

func _mini_box() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color("3a2140")
	sb.set_corner_radius_all(5)
	sb.border_color = Color("4d2c47")
	sb.set_border_width_all(2)
	return sb

func _chip(part: Dictionary) -> Control:
	var box := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color("181226")
	sb.set_corner_radius_all(8)
	sb.border_color = Color("443463")
	sb.set_border_width_all(1)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	box.add_theme_stylebox_override("panel", sb)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 5)
	box.add_child(row)
	var caption := String(part["t"])
	if part.has("icon"):
		caption = String(part["icon"]) + " " + caption
	row.add_child(_label(caption, 12, Palette.MUTED))
	if part.has("v"):
		var neg: bool = bool(part.get("neg", false))
		row.add_child(_label(str(int(part["v"])), 12, Palette.NEG if neg else Palette.GOLD_LIGHT))
	return box

func _hearts(n: int) -> String:
	var s := ""
	for i in Rules.LIVES_MAX:
		s += "♥" if i < n else "♡"
	return s

func _stars(n: int) -> String:
	var s := ""
	for i in 2:
		s += "★" if i < n else "☆"
	return s

## Виньетка: к краям темнее. Держит взгляд в центре и глушит кладку по углам.
func _vignette() -> Texture2D:
	var g := Gradient.new()
	g.set_color(0, Color(0, 0, 0, 0))
	g.set_color(1, Color(0.02, 0.01, 0.04, 0.85))
	g.add_point(0.55, Color(0, 0, 0, 0.05))
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.45)
	t.fill_to = Vector2(1.15, 1.05)
	t.width = 256
	t.height = 256
	return t

func _radial_glow() -> Texture2D:
	var g := Gradient.new()
	g.set_color(0, Color(0.42, 0.28, 0.62, 0.5))
	g.set_color(1, Color(0, 0, 0, 0))
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.0)
	t.fill_to = Vector2(1.1, 0.9)
	t.width = 256
	t.height = 256
	return t
