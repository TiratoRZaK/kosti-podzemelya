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
var card_box: VBoxContainer
var hand_row: HBoxContainer
var my_name: Label
var my_score: Label
var my_hearts: Label
var my_deck: Label
var menu_layer: Control
var veil_layer: Control
var veil_title: Label
var over_layer: Control

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
	var glow := TextureRect.new()
	glow.texture = _radial_glow()
	glow.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	glow.stretch_mode = TextureRect.STRETCH_SCALE
	glow.modulate = Color(1, 1, 1, 0.5)
	add_child(glow)

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

func _title_block() -> Control:
	var box := VBoxContainer.new()
	var t := _label("КОСТИ ПОДЗЕМЕЛЬЯ", 25, Palette.GOLD, Palette.FONT_TITLE)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(t)
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
	foe_hand_row = HBoxContainer.new()
	foe_hand_row.add_theme_constant_override("separation", 6)
	v.add_child(foe_hand_row)
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
		var cfg: Dictionary = MatchState.MODES[key]
		if String(cfg["deck"]) == "draft":
			continue      # драфту нужен экран выбора колоды, он ещё не перенесён
		v.add_child(_mode_button(key, cfg))
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
	_refresh()
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

func _show_result(title: String, detail: String, button: String, on_press: Callable) -> void:
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

	_rebuild_board(me)
	_rebuild_hand(me)
	_update_sel_info(me)

func _score_text(seat: String, kind: String, cfg: Dictionary) -> String:
	var sc := int(state["players"][seat]["score"])
	if kind == "race":
		return "%d/%d" % [sc, int(cfg["target"])]
	if String(cfg.get("win_by", "")) == "count":
		var n := Rules.owner_count(state["board"], seat)
		return "%d куб · %d" % [n, sc]
	return str(sc)

func _rebuild_board(me: String) -> void:
	for c in board_grid.get_children():
		c.queue_free()
	var cols := int(state["cfg"]["cols"])
	var cell_w: float = (390.0 - 28.0 - CELL_GAP * (cols - 1)) / float(cols)
	var valid := _valid_cells(me)
	for i in state["board"].size():
		var slot := Panel.new()
		slot.custom_minimum_size = Vector2(cell_w, cell_w)
		slot.add_theme_stylebox_override("panel", _cell_box(valid.has(i), state["board"][i] != null))
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

func _update_sel_info(me: String) -> void:
	if not input_allowed():
		var turn := String(state["turn"])
		sel_info.text = "Соперник думает…" if MatchState.seat_kind(state, turn) == "bot" else "Секунду…"
		return
	if selected >= 0:
		var hand: Array = state["players"][me]["hand"]
		if selected < hand.size():
			var die: Dictionary = hand[selected]
			var t: Dictionary = Rules.TYPES[String(die["type"])]
			sel_info.text = "%s %d — выбери подсвеченную клетку." % [String(t["name"]), int(die["value"])]
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
	await _play_card(res)
	_after_move()

func _after_move() -> void:
	var ev := MatchState.advance(state)
	match String(ev["event"]):
		"round_end":
			var out := MatchState.close_round(state)
			var final := MatchState.match_outcome(state)
			if bool(out["match_over"]):
				var who := String(final["winner"])
				var title := "НИЧЬЯ" if who == "" else (MatchState.seat_name(state, who).to_upper() + " ПОБЕДИЛ!")
				if who == "p" and MatchState.seat_kind(state, "e") == "bot":
					title = "ПОБЕДА!"
				elif who == "e" and MatchState.seat_kind(state, "e") == "bot":
					title = "ПОРАЖЕНИЕ"
				busy = true
				_show_result(title, String(final["detail"]), "Ещё раз", func(): _start_mode(String(state["mode"])))
				return
			var rtitle := "НИЧЬЯ В РАУНДЕ" if String(out["winner"]) == "" \
				else MatchState.seat_name(state, String(out["winner"])).to_upper() + " БЕРЁТ РАУНД"
			busy = true
			_show_result(rtitle, String(out["detail"]), "Следующий раунд", func():
				MatchState.new_round(state)
				_refresh()
				_begin_turn(String(state["turn"]))
			)
		"pass":
			_refresh()
			await get_tree().create_timer(0.7).timeout
			_after_move()
		"turn":
			await _begin_turn(String(ev["seat"]))

func _animate_place(cell_idx: int) -> void:
	if cell_idx < 0 or cell_idx >= board_grid.get_child_count():
		return
	for c in board_grid.get_child(cell_idx).get_children():
		if c is DieView:
			c.play_place()

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
	head.add_child(_label("%s · ХОД %d" % [who, state["history"].size()], 10, Palette.GOLD_LIGHT))
	head.add_child(_grow())
	var total := _label("", 22, Palette.GOLD_LIGHT, Palette.FONT_UI)
	total.modulate.a = 0.0
	head.add_child(total)
	var chips := HBoxContainer.new()
	chips.add_theme_constant_override("separation", 6)
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

func _cell_box(valid: bool, has_die: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Palette.CELL
	sb.set_corner_radius_all(12)
	sb.set_border_width_all(3)
	sb.border_color = Palette.CELL_EDGE
	if valid:
		sb.border_color = Palette.DANGER if has_die else Palette.GOLD
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
