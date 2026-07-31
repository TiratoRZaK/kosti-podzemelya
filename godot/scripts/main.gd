extends Control

## Экран матча. Интерфейс собирается кодом: разметку в .tscn удобно править в
## редакторе мышью, а мне — вслепую, поэтому вся структура здесь и её видно
## целиком.
##
## Логика лежит в MatchState/Rules/Bot и про интерфейс ничего не знает. Здесь
## только показ и ввод — тот же раздел, что в вебе между applyMove и presentMove.
##
## Снимок экрана: запуск с `--shot=путь.png` рисует состояние, сохраняет кадр и
## выходит. Иначе Godot-окно мне не увидеть и «делать красиво» пришлось бы вслепую.

const CELL_GAP := 9
const HAND_SIZE_PX := 74

var state: Dictionary
var rng := RandomNumberGenerator.new()
var selected := -1
var busy := false

# узлы интерфейса
var foe_score: Label
var foe_hearts: Label
var foe_hand_row: HBoxContainer
var turn_info: Label
var turn_who: Label
var board_grid: GridContainer
var sel_info: Label
var card_box: VBoxContainer
var hand_row: HBoxContainer
var my_score: Label
var my_hearts: Label
var my_deck: Label

var _shot_path := ""
var _shot_after_move := false

func _ready() -> void:
	_parse_args()
	rng.seed = 20260731
	state = MatchState.new_match("classic", 20260731, false)
	state["shown_to"] = "p"
	_build_ui()
	_refresh()
	if _shot_path != "":
		if _shot_after_move:
			await _demo_move()
		await _screenshot_and_quit()

func _parse_args() -> void:
	var all := OS.get_cmdline_args() + OS.get_cmdline_user_args()
	for a in all:
		if a.begins_with("--shot="):
			_shot_path = a.substr(7)
		elif a == "--shot-move":
			_shot_after_move = true

## Заготовка для снимка: расставляет предсказуемую доску и делает ход со
## съедением и комбо, чтобы на кадр попали жетоны и итог хода.
func _demo_move() -> void:
	state["board"][0] = {"v": 2, "type": "basic", "owner": "e", "shield": 0}
	state["board"][3] = {"v": 4, "type": "basic", "owner": "p", "shield": 0}
	state["board"][4] = {"v": 4, "type": "basic", "owner": "p", "shield": 0}
	state["board"][5] = {"v": 6, "type": "shield", "owner": "e", "shield": 2}
	state["players"]["p"]["hand"][0] = {"value": 4, "type": "basic"}
	selected = 0
	_refresh()
	var res := MatchState.play(state, "p", 0, 0)
	_refresh()
	_animate_place(int(res["placed"]))
	await _play_card(res)

# --------------------------------------------------------------- построение

func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.color = Palette.BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	# тёплый подсвет сверху — «факелы» подземелья, пока без текстуры
	var glow := TextureRect.new()
	glow.texture = _radial_glow()
	glow.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	glow.stretch_mode = TextureRect.STRETCH_SCALE
	glow.modulate = Color(1, 1, 1, 0.55)
	add_child(glow)

	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 10)
	var pad := MarginContainer.new()
	pad.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, 14)
	add_child(pad)
	pad.add_child(root)

	root.add_child(_title_block())
	root.add_child(_foe_zone())
	root.add_child(_turn_bar())
	board_grid = GridContainer.new()
	board_grid.columns = int(state["cfg"]["cols"])
	board_grid.add_theme_constant_override("h_separation", CELL_GAP)
	board_grid.add_theme_constant_override("v_separation", CELL_GAP)
	root.add_child(board_grid)
	sel_info = _label("", 12, Palette.MUTED)
	sel_info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sel_info.custom_minimum_size.y = 34
	sel_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(sel_info)
	# место под карточку хода держим всегда: иначе доска и рука прыгают после
	# каждого хода, а между ними зияет пустота, пока карточки нет
	card_box = VBoxContainer.new()
	card_box.add_theme_constant_override("separation", 6)
	card_box.custom_minimum_size.y = 96
	card_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(card_box)
	root.add_child(_my_zone())

func _title_block() -> Control:
	var box := VBoxContainer.new()
	var t := _label("КОСТИ ПОДЗЕМЕЛЬЯ", 25, Palette.GOLD, Palette.FONT_TITLE)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(t)
	var sub := _label(String(state["cfg"]["title"]).to_upper(), 10, Palette.MUTED)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(sub)
	return box

func _foe_zone() -> Control:
	var panel := _panel()
	var v := VBoxContainer.new()
	panel.add_child(v)
	var row := HBoxContainer.new()
	v.add_child(row)
	row.add_child(_label(MatchState.seat_name(state, "e").to_upper(), 10, Palette.MUTED))
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
	row.add_child(_label(MatchState.seat_name(state, "p").to_upper(), 10, Palette.MUTED))
	row.add_child(_grow())
	my_hearts = _label("", 15, Palette.DANGER)
	row.add_child(my_hearts)
	row.add_child(_grow())
	my_score = _label("0", 20, Palette.GOLD_LIGHT, Palette.FONT_UI)
	row.add_child(my_score)
	hand_row = HBoxContainer.new()
	hand_row.add_theme_constant_override("separation", 10)
	hand_row.alignment = BoxContainer.ALIGNMENT_CENTER
	hand_row.custom_minimum_size.y = HAND_SIZE_PX
	v.add_child(hand_row)
	my_deck = _label("", 10, Palette.MUTED)
	v.add_child(my_deck)
	return panel

# ------------------------------------------------------------- отображение

func _refresh() -> void:
	var cfg: Dictionary = state["cfg"]
	var me := "p"
	var foe := "e"
	my_score.text = str(int(state["players"][me]["score"]))
	foe_score.text = str(int(state["players"][foe]["score"]))
	my_hearts.text = _hearts(int(state["players"][me]["lives"]))
	foe_hearts.text = _hearts(int(state["players"][foe]["lives"]))
	my_deck.text = "Колода: %d" % state["players"][me]["deck"].size()
	var move_no: int = mini(int(state["players"][String(state["turn"])]["moves"]) + 1, int(cfg["moves"]))
	turn_info.text = "РАУНД %d · ХОД %d/%d" % [int(state["round"]), move_no, int(cfg["moves"])]
	var my_turn := String(state["turn"]) == me
	turn_who.text = "ТВОЙ ХОД" if my_turn else "ХОД: " + MatchState.seat_name(state, foe).to_upper()
	turn_who.add_theme_color_override("font_color", Palette.GOLD_LIGHT if my_turn else Palette.NEG)

	# рубашки соперника
	for c in foe_hand_row.get_children():
		c.queue_free()
	for i in state["players"][foe]["hand"].size():
		var back := Panel.new()
		back.custom_minimum_size = Vector2(22, 22)
		back.add_theme_stylebox_override("panel", _mini_box())
		foe_hand_row.add_child(back)

	_rebuild_board()
	_rebuild_hand()
	_update_sel_info()

func _rebuild_board() -> void:
	for c in board_grid.get_children():
		c.queue_free()
	var cell_w: float = (390.0 - 28.0 - CELL_GAP * (int(state["cfg"]["cols"]) - 1)) / float(state["cfg"]["cols"])
	var valid := _valid_cells()
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
			d.offset_left = cell_w * 0.08
			d.offset_top = cell_w * 0.08
			d.offset_right = -cell_w * 0.08
			d.offset_bottom = -cell_w * 0.08
			d.mouse_filter = Control.MOUSE_FILTER_IGNORE
			slot.add_child(d)
			# скрытый тип чужого куба значка не получает — ловушки должны работать
			var seen: bool = String(cell["owner"]) == "p"
			var hidden: bool = bool(Rules.TYPES[String(cell["type"])]["hidden"])
			d.setup(int(cell["v"]), String(cell["type"]), String(cell["owner"]) == "p",
				not hidden or seen, int(cell["shield"]))

func _rebuild_hand() -> void:
	for c in hand_row.get_children():
		c.queue_free()
	var hand: Array = state["players"]["p"]["hand"]
	for i in hand.size():
		var die: Dictionary = hand[i]
		var d := DieView.new()
		d.custom_minimum_size = Vector2(HAND_SIZE_PX, HAND_SIZE_PX)
		d.clickable = not busy and String(state["turn"]) == "p"
		d.setup(int(die["value"]), String(die["type"]), true, true)
		d.pressed.connect(_on_hand_pressed.bind(i))
		hand_row.add_child(d)
		if i == selected:
			d.set_selected(true)

func _update_sel_info() -> void:
	if busy:
		sel_info.text = "Соперник думает…"
		return
	if selected >= 0:
		var die: Dictionary = state["players"]["p"]["hand"][selected]
		var t: Dictionary = Rules.TYPES[String(die["type"])]
		sel_info.text = "%s %d — выбери подсвеченную клетку." % [String(t["name"]), int(die["value"])]
	else:
		sel_info.text = "Выбери куб в руке."

func _valid_cells() -> Array:
	if busy or selected < 0 or String(state["turn"]) != "p":
		return []
	var hand: Array = state["players"]["p"]["hand"]
	if selected >= hand.size():
		return []
	return Rules.legal_targets(state["board"], hand[selected], "p")

# ------------------------------------------------------------------- ввод

func _on_hand_pressed(_d: DieView, idx: int) -> void:
	if busy or String(state["turn"]) != "p":
		return
	selected = -1 if selected == idx else idx
	_rebuild_board()
	_rebuild_hand()
	_update_sel_info()

func _on_cell_input(event: InputEvent, idx: int) -> void:
	if busy or selected < 0 or String(state["turn"]) != "p":
		return
	if not (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
		return
	if not _valid_cells().has(idx):
		return
	_do_move("p", selected, idx)

# -------------------------------------------------------------------- ход

func _do_move(seat: String, hand_idx: int, cell_idx: int) -> void:
	busy = true
	selected = -1
	var res := MatchState.play(state, seat, hand_idx, cell_idx)
	_refresh()
	_animate_place(int(res["placed"]))
	await _play_card(res)
	var ev := MatchState.advance(state)
	match String(ev["event"]):
		"round_end":
			var out := MatchState.close_round(state)
			if bool(out["match_over"]):
				busy = true
				sel_info.text = "Матч окончен: " + String(MatchState.match_outcome(state)["detail"])
				return
			MatchState.new_round(state)
			busy = false
			_refresh()
		"pass":
			busy = false
			_refresh()
			await get_tree().create_timer(0.6).timeout
			_after_turn()
		"turn":
			busy = String(ev["seat"]) != "p"
			_refresh()
			_after_turn()

func _after_turn() -> void:
	if String(state["turn"]) == "p":
		busy = false
		_refresh()
		return
	# ход бота
	await get_tree().create_timer(0.7).timeout
	var mv := Bot.choose_move(state, String(state["turn"]), rng)
	if mv.is_empty():
		MatchState.advance(state)
		busy = false
		_refresh()
		return
	_do_move(String(state["turn"]), int(mv["hand"]), int(mv["cell"]))

func _animate_place(cell_idx: int) -> void:
	if cell_idx < 0 or cell_idx >= board_grid.get_child_count():
		return
	var slot := board_grid.get_child(cell_idx)
	for c in slot.get_children():
		if c is DieView:
			c.play_place()

## Карточка хода: жетоны появляются по одному, число летит из клетки в свой
## жетон, и только когда все на месте — проявляется итог справа. Порядок важен:
## итог, обогнавший последний жетон, читается как ошибка подсчёта.
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
	var who := "ТВОЙ ХОД" if String(res["seat"]) == "p" else MatchState.seat_name(state, String(res["seat"])).to_upper()
	head.add_child(_label("%s %d" % [who, state["history"].size()], 10, Palette.GOLD_LIGHT))
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
		chip.scale = Vector2(0.7, 0.7)
		chips.add_child(chip)
	# ждём раскладки, иначе позиции жетонов ещё нулевые и числу некуда лететь
	await get_tree().process_frame
	await get_tree().process_frame

	for i in parts.size():
		var p: Dictionary = parts[i]
		var chip: Control = chips.get_child(i)
		if p.has("hl"):
			for ci in p["hl"]:
				_glow_cell(int(ci))
		if p.has("v") and not p.get("die", false):
			await _fly_number(p, chip, String(res["seat"]))
		_pop_in(chip)
		await get_tree().create_timer(0.18).timeout

	var pts := int(res["pts"])
	total.text = "💥 0" if bool(res["mined"]) else str(absi(pts))
	total.add_theme_color_override("font_color", Palette.NEG if pts < 0 else Palette.GOLD_LIGHT)
	await get_tree().create_timer(0.12).timeout
	_pop_in(total, 1.35)

func _glow_cell(idx: int) -> void:
	if idx < 0 or idx >= board_grid.get_child_count():
		return
	for c in board_grid.get_child(idx).get_children():
		if c is DieView:
			c.play_glow()

## Число вылетает из клетки и влетает в свой жетон.
func _fly_number(part: Dictionary, chip: Control, seat: String) -> void:
	var from_cell: int = int(part.get("ci", -1))
	var src: Vector2 = chip.global_position + chip.size * 0.5
	if from_cell >= 0 and from_cell < board_grid.get_child_count():
		var slot: Control = board_grid.get_child(from_cell)
		src = slot.global_position + slot.size * 0.5
	var neg: bool = bool(part.get("neg", false))
	var fly := _label("%s%d" % ["−" if neg else "+", int(part["v"])], 16,
		Palette.NEG if neg else (Palette.NEG if seat == "e" else Palette.GOLD_LIGHT), Palette.FONT_UI)
	add_child(fly)
	fly.global_position = src
	fly.z_index = 100
	var dst: Vector2 = chip.global_position + chip.size * 0.5
	var tw := create_tween().set_parallel(true)
	tw.tween_property(fly, "global_position", dst, 0.34).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_CUBIC)
	tw.tween_property(fly, "scale", Vector2(0.7, 0.7), 0.34)
	tw.tween_property(fly, "modulate:a", 0.15, 0.34)
	await tw.finished
	fly.queue_free()

func _pop_in(node: Control, overshoot: float = 1.12) -> void:
	node.modulate.a = 1.0
	var tw := create_tween()
	tw.tween_property(node, "scale", Vector2(overshoot, overshoot), 0.10).set_ease(Tween.EASE_OUT)
	tw.tween_property(node, "scale", Vector2.ONE, 0.12)

# ------------------------------------------------------------ вспомогательное

func _label(text: String, size_px: int, col: Color, font_path: String = "") -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size_px)
	l.add_theme_color_override("font_color", col)
	if font_path != "" and ResourceLoader.exists(font_path):
		l.add_theme_font_override("font", load(font_path))
	return l

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
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	p.add_theme_stylebox_override("panel", sb)
	return p

func _cell_box(valid: bool, has_die: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Palette.CELL
	sb.set_corner_radius_all(12)
	sb.set_border_width_all(3)
	if valid:
		sb.border_color = Palette.DANGER if has_die else Palette.GOLD
	else:
		sb.border_color = Palette.CELL_EDGE
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

## Мягкое световое пятно сверху — заготовка под текстуру подземелья.
func _radial_glow() -> Texture2D:
	var g := Gradient.new()
	g.set_color(0, Color(0.42, 0.28, 0.62, 0.55))
	g.set_color(1, Color(0, 0, 0, 0))
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.0)
	t.fill_to = Vector2(1.1, 0.9)
	t.width = 256
	t.height = 256
	return t

func _screenshot_and_quit() -> void:
	# несколько кадров, чтобы раскладка и шрифты успели примениться
	for i in 4:
		await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	img.save_png(_shot_path)
	print("снимок: ", _shot_path)
	get_tree().quit()
