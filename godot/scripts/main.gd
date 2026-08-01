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
var opponent := "bot"            # bot | human (хотсит) | remote (по сети)
var my_seat := "p"               # своё сиденье: у клиента по сети — второе
var foe_player := "Соперник"     # имя соперника, приходит по сети при знакомстве
var lan: Lan
var foe_left := false            # соперник вышел сам — гасит «СВЯЗЬ ПОТЕРЯНА» вдогонку
var lobby_layer: Control
var lobby_box: VBoxContainer
var selected := -1
var busy := false

# Годо-аналог S.token и schedule() веб-прототипа: паузы (пас-таймер, раздумье
# бота, фанфара) переживают смену партии, и отложенное продолжение двигало бы
# уже другой матч. Перед каждым игровым await запоминаем токен, после — сверяем.
var flow_token := 0
var net_moves: Array = []        # ходы соперника, пришедшие раньше, чем поток до них дошёл
var waiting_remote := false      # поток остановился и ждёт ход соперника из сети
var pending_next_round := false  # хост открыл раунд, пока мы ещё доигрывали свой

# узлы
var foe_name: Label
var foe_score: Label
var foe_hearts: LifeRow
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
var my_hearts: LifeRow
var my_deck: Label
var menu_layer: Control
var veil_layer: Control
var veil_title: Label
var over_layer: Control

var _banner_tween: Tween
var banner_panel: PanelContainer
var _shot_path := ""
var _shot_mode := ""
var _wall_rect: TextureRect          # фон ждёт фоновой загрузки, см. _process
var durak_root: Control
var _safe := Vector4(14, 14, 14, 14)   # отступы экрана: лево, верх, право, низ
var card_scroll: ScrollContainer
var boot_note: Label
var _boot_ms := 0
var hand_px := HAND_PX

# Дуракуб: своя машина состояний (Durak) и свой экран. Боевая раскладка ему не
# годится — нет ни очков, ни жизней, ни истории ходов, зато есть стол из пар.
var battle_root: Control
var durak_layer: Control
var in_durak := false
var d_state: Dictionary
var d_frozen: Array = []          # стол, задержанный на экране: «Бито»/«Взять» его сразу очищают
var d_notice := ""                # крупное сообщение вместо подсказки («забираешь стол»)
var d_foe_name: Label
var d_foe_count: Label
var d_foe_hand: HBoxContainer
var d_discard: Label
var d_info: Label
var d_trump_mark: SuitMark
var d_who: Label
var d_toast_label: Label
var d_table: GridContainer
var d_hint: Label
var d_my_name: Label
var d_my_count: Label
var d_hand: HFlowContainer
var d_actions: HBoxContainer
var d_talon: Label
var rules_battle_box: VBoxContainer
var rules_durak_box: VBoxContainer
var menu_note: Label
var menu_hint: Label
var kind_box: VBoxContainer        # шаг 1 меню: с кем играем
var modes_box: VBoxContainer       # шаг 2 меню: во что играем
var name_layer: Control
var name_input: LineEdit
var name_error: Label
var name_cancel: Button

func _ready() -> void:
	_parse_args()
	rng.seed = 20260731
	_boot_ms = Time.get_ticks_msec()      # столько прошло от инициализации движка
	_build_ui()
	_apply_safe_area()
	get_viewport().size_changed.connect(_apply_safe_area)
	_show_menu()
	_report_boot()
	# имя спрашиваем один раз за установку; снимки экранов этим не тормозим
	if _shot_path == "" and not Profile.has_name():
		_show_name_screen(true)
	if _shot_path != "":
		await _shot_scenario()

## Замер запуска: сколько ушло на движок до нашего кода и сколько на интерфейс.
func _report_boot() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	if boot_note == null:
		return
	var ui := Time.get_ticks_msec() - _boot_ms
	# игроку показываем, только если запуск был ненормально долгим: в обычной
	# партии эта строка — мусор на экране, а при 40 секундах ожидания она объясняет,
	# куда ушло время
	boot_note.text = "запуск: движок %d мс · интерфейс %d мс" % [_boot_ms, ui] if _boot_ms > 5000 else ""
	print("[boot] движок=%d мс интерфейс=%d мс" % [_boot_ms, ui])

## Вернуть экран на место. Тряска двигает контейнер, и если её оборвало сменой
## режима или раунда, интерфейс остался бы съехавшим — управлять им нельзя.
func _reset_shift() -> void:
	if _shake_tween != null and _shake_tween.is_valid():
		_shake_tween.kill()
	_shake_tween = null
	_set_shake_offset(Vector2.ZERO)
	# на всякий случай подчищаем и контейнеры: прежние сборки двигали их, и
	# сдвиг мог остаться в отступах
	for box in [battle_root, durak_root]:
		if box != null:
			box.position = Vector2.ZERO

## Отступы по безопасной зоне устройства. У телефона снизу жестовая полоса или
## кнопки навигации, сверху вырез — без этого нижняя часть экрана (рука и кнопки)
## уезжала под системную панель, особенно на большой доске, где всё и так плотно.
## В вебе ту же задачу решает env(safe-area-inset-*).
func _apply_safe_area() -> void:
	_reset_shift()
	var win := DisplayServer.window_get_size()
	var vp := get_viewport_rect().size
	var pad := 14.0
	var l := pad
	var t := pad
	var r := pad
	var b := pad
	if win.x > 0 and win.y > 0:
		var area := DisplayServer.get_display_safe_area()
		# безопасная зона приходит в пикселях устройства, а рисуем мы в логических
		var kx := vp.x / float(win.x)
		var ky := vp.y / float(win.y)
		if area.size.x > 0 and area.size.y > 0 and (area.size.x < win.x or area.size.y < win.y
				or area.position.x > 0 or area.position.y > 0):
			l = maxf(pad, area.position.x * kx)
			t = maxf(pad, area.position.y * ky)
			r = maxf(pad, (win.x - area.position.x - area.size.x) * kx)
			b = maxf(pad, (win.y - area.position.y - area.size.y) * ky)
	# На телефоне поверх игры рисуется жестовая полоса, а в полноэкранном режиме
	# система отдаёт «безопасной зоной» весь экран — на неё одну надеяться нельзя,
	# поэтому снизу держим отступ в любом случае.
	if OS.get_name() == "Android" or OS.get_name() == "iOS":
		b = maxf(b, 26.0)
		t = maxf(t, 18.0)
	_safe = Vector4(l, t, r, b)
	# на невысоких экранах ужимаем карточку хода и руку, иначе низ не влезает
	var avail := vp.y - t - b
	var compact: bool = avail < 800.0
	hand_px = 62 if compact else HAND_PX
	if hand_row != null:
		hand_row.custom_minimum_size.y = hand_px
	if card_scroll != null:
		card_scroll.custom_minimum_size.y = 92 if compact else 116
	for box in [battle_root, durak_root]:
		if box == null:
			continue
		box.add_theme_constant_override("margin_left", int(l))
		box.add_theme_constant_override("margin_top", int(t))
		box.add_theme_constant_override("margin_right", int(r))
		box.add_theme_constant_override("margin_bottom", int(b))
	_refresh_screen()

## Фон подставляем, когда фоновый поток его дочитает. Пока не готов — на экране
## заливка, и меню уже нажимается: запуск не ждёт декода текстуры.
func _process(_dt: float) -> void:
	if _wall_rect == null:
		return
	var status := ResourceLoader.load_threaded_get_status(BG_TEXTURE)
	if status == ResourceLoader.THREAD_LOAD_LOADED:
		_wall_rect.texture = ResourceLoader.load_threaded_get(BG_TEXTURE)
		_wall_rect = null
	elif status == ResourceLoader.THREAD_LOAD_FAILED or status == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
		_wall_rect = null

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
		elif a == "--shot-lobby":
			_shot_mode = "lobby"
		elif a == "--shot-durak":
			_shot_mode = "durak"
		elif a == "--shot-durak-veil":
			_shot_mode = "durak_veil"
		elif a == "--shot-durak-rules":
			_shot_mode = "durak_rules"
		elif a == "--shot-durak-bot":
			_shot_mode = "durak_bot"
		elif a == "--shot-durak-net":
			_shot_mode = "durak_net"
		elif a == "--shot-big":
			_shot_mode = "big"
		elif a == "--shot-net-client":
			_shot_mode = "net_client"
		elif a == "--shot-net-round":
			_shot_mode = "net_round"
		elif a == "--shot-net-rematch":
			_shot_mode = "net_rematch"
		elif a == "--shot-durak-take":
			_shot_mode = "durak_take"
		elif a == "--shot-durak-lose":
			_shot_mode = "durak_lose"
		elif a == "--shot-shield":
			_shot_mode = "shield"
		elif a == "--shot-fx":
			_shot_mode = "fx"
		elif a == "--shot-shake":
			_shot_mode = "shake"
		elif a == "--shot-combo":
			_shot_mode = "combo"
		elif a == "--shot-name":
			_shot_mode = "name_ask"
		elif a == "--shot-modes":
			_shot_mode = "modes"

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
	return my_seat

func input_allowed() -> bool:
	if state.is_empty() or busy or veil_layer.visible or menu_layer.visible or over_layer.visible:
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
		# картинку ждём не на старте: меню появляется сразу на заливке, а кладка
		# доезжает следующими кадрами. Так первый кадр не зависит от декода текстуры
		ResourceLoader.load_threaded_request(BG_TEXTURE)
		_wall_rect = wall
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
	add_child(pad)
	battle_root = pad
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
	# по центру: на 3×3 клетка мельче ширины экрана, и доска прижималась влево
	var board_wrap := CenterContainer.new()
	board_wrap.add_child(board_grid)
	root.add_child(board_wrap)
	sel_info = _label("", 12, Palette.MUTED)
	sel_info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sel_info.custom_minimum_size.y = 32
	sel_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(sel_info)
	# лента ходов: таблетки с номером и итогом, тап раскрывает нужную карточку
	hist_strip = HBoxContainer.new()
	hist_strip.add_theme_constant_override("separation", 6)
	hist_strip.custom_minimum_size.y = 40
	var strip_scroll := ScrollContainer.new()
	strip_scroll.custom_minimum_size.y = 44
	strip_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	strip_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	strip_scroll.add_child(hist_strip)
	root.add_child(strip_scroll)
	# Место под карточку хода держим всегда, иначе доска и рука прыгают. И держим
	# его ЖЁСТКО: на большой доске жетонов бывает три ряда, карточка вырастала и
	# выдавливала руку за нижний край экрана. Теперь лишнее прокручивается внутри
	# карточки, а рука остаётся на месте.
	card_box = VBoxContainer.new()
	card_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card_scroll = ScrollContainer.new()
	card_scroll.custom_minimum_size.y = 116
	card_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	card_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	card_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	card_scroll.add_child(card_box)
	root.add_child(card_scroll)
	root.add_child(_my_zone())

	# экран Дуракуба лежит рядом с боевым и включается вместо него; слои меню,
	# ширмы и исходов идут выше и работают для обоих
	durak_layer = _build_durak()
	add_child(durak_layer)

	menu_layer = _build_menu()
	add_child(menu_layer)
	veil_layer = _build_veil()
	add_child(veil_layer)
	over_layer = _build_overlay()
	add_child(over_layer)
	# Правила строятся при первом открытии: там шесть картинок способностей по
	# 512×512, и на старте они заметно задерживали появление меню.
	lobby_layer = _build_lobby()
	add_child(lobby_layer)
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
	bpanel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	banner_panel = bpanel
	# размером label управляет PanelContainer: свои anchors ломали расчёт и панель
	# показывалась пустой рамкой
	bpanel.add_child(banner_label)
	# центрируем контейнером, а не пресетом: на момент вызова пресета размер
	# панели ещё нулевой, и её уносило от центра экрана
	var bcenter := CenterContainer.new()
	bcenter.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bcenter.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bcenter.z_index = 119
	bcenter.add_child(bpanel)
	add_child(bcenter)
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
	foe_name = _label("", 12, Palette.MUTED)
	row.add_child(foe_name)
	row.add_child(_grow())
	foe_hearts = LifeRow.new()
	foe_hearts.setup(Rules.LIVES_MAX, Rules.LIVES_MAX)
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
	foe_deck = _label("", 11, Palette.MUTED)
	row2.add_child(foe_deck)
	return panel

func _turn_bar() -> Control:
	var row := HBoxContainer.new()
	turn_info = _label("", 12, Palette.MUTED)
	row.add_child(turn_info)
	row.add_child(_grow())
	turn_who = _label("", 12, Palette.GOLD_LIGHT)
	row.add_child(turn_who)
	return row

func _my_zone() -> Control:
	var panel := _panel()
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	panel.add_child(v)
	var row := HBoxContainer.new()
	v.add_child(row)
	my_name = _label("", 12, Palette.MUTED)
	row.add_child(my_name)
	row.add_child(_grow())
	my_hearts = LifeRow.new()
	my_hearts.setup(Rules.LIVES_MAX, Rules.LIVES_MAX)
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
	my_deck = _label("", 11, Palette.MUTED)
	bottom.add_child(my_deck)
	bottom.add_child(_grow())
	var rules_btn := _button("Правила", true)
	rules_btn.pressed.connect(_show_rules)
	bottom.add_child(rules_btn)
	var menu_btn := _button("Меню", true)
	menu_btn.pressed.connect(_show_menu)
	bottom.add_child(menu_btn)
	return panel

# --------------------------------------------------------------- дуракуб: экран

## Стол Дуракуба: шесть мест, в каждом атакующий куб и, если отбили, защитный
## поверх него со сдвигом — как карты в подкидном. Масти цветные, козырь золотой.
func _build_durak() -> Control:
	var layer := Control.new()
	layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.visible = false
	var pad := MarginContainer.new()
	pad.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	durak_root = pad
	layer.add_child(pad)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	pad.add_child(root)

	var t := _label("КОСТИ ПОДЗЕМЕЛЬЯ", 25, Palette.GOLD, Palette.FONT_TITLE)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(t)
	var tag := _label("ДУРАКУБ", 10, Palette.MUTED)
	tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(tag)

	var foe_panel := _panel()
	root.add_child(foe_panel)
	var fv := VBoxContainer.new()
	foe_panel.add_child(fv)
	var frow := HBoxContainer.new()
	fv.add_child(frow)
	d_foe_name = _label("", 10, Palette.MUTED)
	frow.add_child(d_foe_name)
	frow.add_child(_grow())
	d_foe_count = _label("0", 20, Palette.GOLD_LIGHT, Palette.FONT_UI)
	frow.add_child(d_foe_count)
	var frow2 := HBoxContainer.new()
	fv.add_child(frow2)
	d_foe_hand = HBoxContainer.new()
	d_foe_hand.add_theme_constant_override("separation", 6)
	frow2.add_child(d_foe_hand)
	frow2.add_child(_grow())
	d_discard = _label("", 10, Palette.MUTED)
	frow2.add_child(d_discard)

	d_toast_label = _label("", 12, Palette.GOLD_LIGHT)
	d_toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	d_toast_label.custom_minimum_size.y = 18
	root.add_child(d_toast_label)

	var irow := HBoxContainer.new()
	irow.add_theme_constant_override("separation", 5)
	root.add_child(irow)
	irow.add_child(_label("КОЗЫРЬ", 10, Palette.MUTED))
	d_trump_mark = SuitMark.new()
	d_trump_mark.custom_minimum_size = Vector2(13, 13)
	d_trump_mark.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	d_trump_mark.setup(0, Palette.GOLD_LIGHT)
	irow.add_child(d_trump_mark)
	d_info = _label("", 10, Palette.MUTED)
	irow.add_child(d_info)
	irow.add_child(_grow())
	d_who = _label("", 10, Palette.GOLD_LIGHT)
	irow.add_child(d_who)

	d_table = GridContainer.new()
	d_table.columns = 3
	d_table.add_theme_constant_override("h_separation", CELL_GAP)
	d_table.add_theme_constant_override("v_separation", CELL_GAP)
	root.add_child(d_table)

	d_hint = _label("", 12, Palette.MUTED)
	d_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	d_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	d_hint.custom_minimum_size.y = 34
	root.add_child(d_hint)
	root.add_child(_grow())

	var my_panel := _panel()
	root.add_child(my_panel)
	var mv := VBoxContainer.new()
	mv.add_theme_constant_override("separation", 8)
	my_panel.add_child(mv)
	var mrow := HBoxContainer.new()
	mv.add_child(mrow)
	d_my_name = _label("", 10, Palette.MUTED)
	mrow.add_child(d_my_name)
	mrow.add_child(_grow())
	d_my_count = _label("0", 20, Palette.GOLD_LIGHT, Palette.FONT_UI)
	mrow.add_child(d_my_count)
	# После «Взять» кубов бывает и полтора десятка. Прокрутка тут не годится:
	# полоса узкая, палец задевает кубы и получаются мисклики. Поэтому рука
	# переносится на второй ряд, а сами кубы мельчают — всё видно сразу.
	d_hand = HFlowContainer.new()
	d_hand.add_theme_constant_override("h_separation", 6)
	d_hand.add_theme_constant_override("v_separation", 6)
	d_hand.alignment = FlowContainer.ALIGNMENT_CENTER
	mv.add_child(d_hand)
	d_actions = HBoxContainer.new()
	d_actions.add_theme_constant_override("separation", 10)
	d_actions.alignment = BoxContainer.ALIGNMENT_CENTER
	d_actions.custom_minimum_size.y = 42
	mv.add_child(d_actions)
	var bottom := HBoxContainer.new()
	mv.add_child(bottom)
	d_talon = _label("", 10, Palette.MUTED)
	bottom.add_child(d_talon)
	bottom.add_child(_grow())
	var rules_btn := _button("Правила", true)
	rules_btn.pressed.connect(_show_rules)
	bottom.add_child(rules_btn)
	var menu_btn := _button("Меню", true)
	menu_btn.pressed.connect(_show_menu)
	bottom.add_child(menu_btn)
	return layer

## Куб с мастью. Значение крупно по центру, масть в углу; козырь подсвечен
## золотом — иначе игрок каждый ход сверяется с надписью в шапке.
func _d_die(die: Dictionary, px: int, trump: int, dim: bool = false, tilt: float = 0.0) -> Control:
	var face: Dictionary = Palette.SUIT_FACE[int(die["suit"])]
	var is_trump: bool = int(die["suit"]) == trump
	var slot := Panel.new()
	slot.custom_minimum_size = Vector2(px, px)
	var sb := StyleBoxFlat.new()
	sb.bg_color = face["bg"]
	sb.set_corner_radius_all(int(px * 0.22))
	sb.border_color = Palette.GOLD if is_trump else face["edge"]
	sb.set_border_width_all(3 if is_trump else 2)
	slot.add_theme_stylebox_override("panel", sb)
	if dim:
		slot.modulate = Color(1, 1, 1, 0.4)
	if tilt != 0.0:
		slot.pivot_offset = Vector2(px, px) * 0.5
		slot.rotation = deg_to_rad(tilt)
	var val := _label(str(int(die["value"])), int(px * 0.46), face["ink"], Palette.FONT_UI)
	val.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	val.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	val.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.add_child(val)
	var mark := SuitMark.new()
	mark.setup(int(die["suit"]), Palette.GOLD_LIGHT if is_trump else face["ink"])
	var m := px * 0.3
	mark.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	mark.offset_left = -m - px * 0.1
	mark.offset_top = px * 0.1
	mark.offset_right = -px * 0.1
	mark.offset_bottom = px * 0.1 + m
	slot.add_child(mark)
	return slot

## Название куба словами. Значков мастей в шрифтах нет, а рисованный значок в
## строку текста не вставить, поэтому в подсказках и сообщениях масть называется:
## «пятёрка червей», «отбил четвёрку пик шестёркой бубён».
const D_NUM := {
	"nom": ["", "единица", "двойка", "тройка", "четвёрка", "пятёрка", "шестёрка"],
	"acc": ["", "единицу", "двойку", "тройку", "четвёрку", "пятёрку", "шестёрку"],
	"ins": ["", "единицей", "двойкой", "тройкой", "четвёркой", "пятёркой", "шестёркой"],
}
const D_SUIT_GEN := ["пик", "червей", "бубён", "крестей"]

func _d_name(die: Dictionary, form: String = "nom") -> String:
	return "%s %s" % [D_NUM[form][int(die["value"])], D_SUIT_GEN[int(die["suit"])]]

# ------------------------------------------------------------ дуракуб: показ

## Чьими глазами смотрим — как в боевых режимах, по shown_to, а не по тому, чья
## роль: при безальтернативном действии роль уезжает без ширмы.
func _d_viewer() -> String:
	if d_state.is_empty():
		return "p"
	if MatchState.shared_device(d_state):
		var shown := String(d_state["shown_to"])
		if shown != "":
			return shown
		var a := Durak.actor(d_state)
		return a if a != "" else "p"
	return my_seat

func _d_input_allowed() -> bool:
	if d_state.is_empty() or busy or veil_layer.visible or menu_layer.visible or bool(d_state["over"]):
		return false
	var o := Durak.actor(d_state)
	if o == "" or not (MatchState.seat_is_human(d_state, o) and MatchState.seat_local(d_state, o)):
		return false
	return not MatchState.shared_device(d_state) or String(d_state["shown_to"]) == o

func d_toast(text: String, foe: bool = false) -> void:
	d_toast_label.text = text
	d_toast_label.add_theme_color_override("font_color", Palette.NEG if foe else Palette.GOLD_LIGHT)

func _d_refresh() -> void:
	if d_state.is_empty():
		return
	var me := _d_viewer()
	var foe := MatchState.other_seat(d_state, me)
	var my_hand: Array = Durak.hand_of(d_state, me)
	var foe_hand: Array = Durak.hand_of(d_state, foe)
	var acting := Durak.actor(d_state)
	var trump := int(d_state["trump"])
	var phase := String(d_state["phase"])
	# стол на экране может отставать от состояния: «Бито» и «Взять» очищают его
	# сразу, а игрок должен успеть увидеть, чем закончился кон
	var table: Array = d_frozen if not d_frozen.is_empty() else d_state["table"]

	d_my_name.text = MatchState.seat_name(d_state, me).to_upper()
	d_foe_name.text = MatchState.seat_name(d_state, foe).to_upper()
	d_my_count.text = "%d %s" % [my_hand.size(), _plural(my_hand.size(), "куб", "куба", "кубов")]
	d_foe_count.text = "%d %s" % [foe_hand.size(), _plural(foe_hand.size(), "куб", "куба", "кубов")]
	d_talon.text = "Колода: %d" % d_state["talon"].size()
	d_discard.text = "Бито: %d" % int(d_state["discard"])
	d_trump_mark.setup(trump, Palette.GOLD_LIGHT)
	d_info.text = "· СТОЛ %d/%d" % [table.size(), int(d_state["max_att"])]

	var i_act := acting == me
	if acting == "":
		d_who.text = "…"
		d_who.add_theme_color_override("font_color", Palette.MUTED)
	elif i_act:
		# сидящий за экраном и есть действующий — обращаемся к нему напрямую
		d_who.text = "ТЫ АТАКУЕШЬ" if phase == "attack" else "ОТБИВАЙСЯ!"
		d_who.add_theme_color_override("font_color", Palette.GOLD_LIGHT if phase == "attack" else Palette.NEG)
	else:
		d_who.text = "ХОД: " + MatchState.seat_name(d_state, acting).to_upper()
		d_who.add_theme_color_override("font_color", Palette.NEG)

	for c in d_foe_hand.get_children():
		c.queue_free()
	for i in foe_hand.size():
		var back := Panel.new()
		back.custom_minimum_size = Vector2(22, 22)
		back.add_theme_stylebox_override("panel", _mini_box())
		d_foe_hand.add_child(back)

	_d_rebuild_table(table, trump)
	var valid := _d_valid(me)
	_d_rebuild_hand(my_hand, valid, trump)
	_d_rebuild_actions(me)
	_d_update_hint(me, valid)

func _d_rebuild_table(table: Array, trump: int) -> void:
	for c in d_table.get_children():
		c.queue_free()
	# место в 1.12 высоты, поэтому по высоте считаем с этим коэффициентом; 470 —
	# всё остальное на экране Дуракуба, включая руку в два ряда
	var by_width: float = (390.0 - _safe.x - _safe.z - CELL_GAP * 2) / 3.0
	var by_height: float = (get_viewport_rect().size.y - _safe.y - _safe.w - 442.0 - CELL_GAP) / 2.0 / 1.12
	var cell_w: float = maxf(minf(by_width, by_height), 60.0)
	# 0.58 — чтобы защитный куб перекрывал атакующий только углом: при 0.66 он
	# налезал на само значение, и было не разобрать, чем атаковали
	var die_px := int(cell_w * 0.58)
	var undef := Durak.undefended_idx(d_state) if d_frozen.is_empty() else -1
	for i in Durak.MAX_TABLE:
		var slot := Panel.new()
		slot.custom_minimum_size = Vector2(cell_w, cell_w * 1.12)
		var pair = table[i] if i < table.size() else null
		# место с неотбитым кубом светится золотом: видно, что бить надо именно его
		slot.add_theme_stylebox_override("panel", _cell_box(false, pair != null, i == undef))
		slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		d_table.add_child(slot)
		if pair == null:
			continue
		var att := _d_die(pair["a"], die_px, trump)
		att.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
		att.offset_left = 6
		att.offset_top = 6
		att.offset_right = 6 + die_px
		att.offset_bottom = 6 + die_px
		slot.add_child(att)
		if pair["d"] != null:
			var dfn := _d_die(pair["d"], die_px, trump, false, 7.0)
			dfn.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
			dfn.offset_left = -6 - die_px
			dfn.offset_top = -6 - die_px
			dfn.offset_right = -6
			dfn.offset_bottom = -6
			slot.add_child(dfn)

func _d_rebuild_hand(hand: Array, valid: Array, trump: int) -> void:
	for c in d_hand.get_children():
		c.queue_free()
	# кубы мельчают, когда их много: шесть — крупные, дальше по два ряда
	var n := hand.size()
	var px := 50
	if n > 12:
		px = 40
	elif n > 6:
		px = 44
	for idx in _d_hand_order(hand, trump):
		var i := int(idx)
		var ok: bool = valid.has(i)
		var d := _d_die(hand[i], px, trump, not ok)
		if ok:
			d.mouse_filter = Control.MOUSE_FILTER_STOP
			d.gui_input.connect(func(e: InputEvent):
				if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
					_d_hand_pressed(i)
			)
		else:
			d.mouse_filter = Control.MOUSE_FILTER_IGNORE
		d_hand.add_child(d)

## Порядок показа руки: сначала обычные масти (внутри — по возрастанию значения),
## козыри в конец. Сортируется **только вид**: состояние и индексы остаются как
## есть, иначе по сети действие применилось бы к другому кубу.
func _d_hand_order(hand: Array, trump: int) -> Array:
	var order := []
	for i in hand.size():
		order.append(i)
	order.sort_custom(func(a, b):
		var da: Dictionary = hand[int(a)]
		var db: Dictionary = hand[int(b)]
		var ta: int = 1 if int(da["suit"]) == trump else 0
		var tb: int = 1 if int(db["suit"]) == trump else 0
		if ta != tb:
			return ta < tb
		if int(da["suit"]) != int(db["suit"]):
			return int(da["suit"]) < int(db["suit"])
		return int(da["value"]) < int(db["value"])
	)
	return order

## Чем местный человек может действовать прямо сейчас. Пусто, если ход не его.
func _d_valid(me: String) -> Array:
	var out := []
	if not _d_input_allowed() or Durak.actor(d_state) != me or not d_frozen.is_empty():
		return out
	var hand: Array = Durak.hand_of(d_state, me)
	if String(d_state["phase"]) == "attack":
		if d_state["table"].size() >= int(d_state["max_att"]):
			return out
		if Durak.hand_of(d_state, MatchState.other_seat(d_state, me)).is_empty():
			return out
		for i in hand.size():
			if Durak.can_throw(d_state, hand[i]):
				out.append(i)
		return out
	var idx := Durak.undefended_idx(d_state)
	if idx < 0:
		return out
	var att: Dictionary = d_state["table"][idx]["a"]
	for i in hand.size():
		if Durak.beats(hand[i], att, int(d_state["trump"])):
			out.append(i)
	return out

func _d_rebuild_actions(me: String) -> void:
	for c in d_actions.get_children():
		c.queue_free()
	if not _d_input_allowed() or Durak.actor(d_state) != me or not d_frozen.is_empty():
		return
	var phase := String(d_state["phase"])
	if phase == "attack" and not d_state["table"].is_empty() and Durak.undefended_idx(d_state) < 0:
		var b := _button("Бито")
		b.pressed.connect(func(): _d_bito(me))
		d_actions.add_child(b)
	elif phase == "defend":
		var b2 := _button("Взять")
		b2.pressed.connect(func(): _d_take(me))
		d_actions.add_child(b2)

func _d_update_hint(me: String, valid: Array) -> void:
	# важное сообщение («забираешь стол») перебивает обычную подсказку и держится,
	# пока его не снимет тот, кто поставил
	if d_notice != "":
		d_hint.add_theme_font_size_override("font_size", 15)
		d_hint.add_theme_color_override("font_color", Palette.GOLD_LIGHT)
		d_hint.text = d_notice
		return
	d_hint.add_theme_font_size_override("font_size", 12)
	d_hint.add_theme_color_override("font_color", Palette.MUTED)
	if not _d_input_allowed() or Durak.actor(d_state) != me:
		var acting := Durak.actor(d_state)
		var k := MatchState.seat_kind(d_state, acting) if acting != "" else ""
		if k == "bot":
			d_hint.text = "Соперник думает…"
		elif k == "remote":
			d_hint.text = "Ход соперника…"
		else:
			d_hint.text = "Секунду…"
		return
	if String(d_state["phase"]) == "attack":
		if d_state["table"].is_empty():
			d_hint.text = "Атакуй любым кубом."
		elif valid.is_empty():
			d_hint.text = "Подкидывать нечем — жми «Бито»."
		else:
			d_hint.text = "Подкинь куб со значением как на столе или жми «Бито»."
		return
	var idx := Durak.undefended_idx(d_state)
	if idx < 0:
		d_hint.text = ""
		return
	var att: Dictionary = d_state["table"][idx]["a"]
	if valid.is_empty():
		d_hint.text = "Побить %s нечем — придётся брать стол." % _d_name(att, "acc")
	else:
		d_hint.text = "Побей %s: нужен куб старше той же масти или любой козырь." % _d_name(att, "acc")

# ------------------------------------------------------------ дуракуб: поток

## seed_value < 0 — партию начинаем сами и, если играем по сети, объявляем сид
## сопернику; иначе сид пришёл от хоста и раздача у обоих совпадёт.
func _start_durak(seed_value: int = -1) -> void:
	_new_flow()
	_reset_shift()
	menu_layer.visible = false
	over_layer.visible = false
	in_durak = true
	battle_root.visible = false
	durak_layer.visible = true
	state = {}
	d_frozen = []
	var sd := seed_value if seed_value >= 0 else (int(Time.get_unix_time_from_system()) & 0x7fffffff)
	if seed_value < 0 and opponent == "remote" and lan != null and lan.is_host:
		lan.send_start("durak", sd)
	d_state = Durak.new_game(sd, opponent, my_seat, foe_player, Profile.display_name())
	d_toast("")
	busy = true
	_d_refresh()
	banner("ДУРАКУБ")
	await _durak_next(1.0)

## Единственная точка передачи роли: бот, безальтернативное действие, ширма или
## ожидание ввода. Ровно как beginTurn в боевых режимах.
func _durak_next(delay: float = 0.7) -> void:
	if d_state.is_empty():
		return
	if bool(d_state["over"]):
		await _d_finish()
		return
	var o := Durak.actor(d_state)
	if o == "":
		busy = true
		_d_refresh()
		return
	if MatchState.seat_kind(d_state, o) == "bot":
		busy = true
		_d_refresh()
		await get_tree().create_timer(delay).timeout
		if d_state.is_empty() or not in_durak:
			return
		await _d_bot()
		return
	# за удалённым сиденьем действует чужое устройство — ждём сообщения. Проверка
	# идёт ДО безальтернативного действия: иначе оба устройства выполнили бы его
	# сами и продублировали кон.
	if MatchState.seat_kind(d_state, o) == "remote":
		busy = true
		_d_refresh()
		return
	# безальтернативное действие ширмы не требует: выбора нет, стол и так открыт
	var forced := Durak.forced_action(d_state, o)
	if forced != "":
		busy = true
		_d_refresh()
		var who := MatchState.seat_name(d_state, o)
		var why := "%s не отбился — забирает стол" % who if forced == "take" \
			else "%s: подкидывать нечем — бито" % who
		d_toast(why, o != _d_viewer())
		await get_tree().create_timer(delay).timeout
		if d_state.is_empty() or not in_durak:
			return
		if forced == "take":
			await _d_take(o)
		else:
			await _d_bito(o)
		return
	if MatchState.needs_veil(d_state, o):
		_show_veil(o)
		return
	d_state["shown_to"] = o
	busy = false
	_d_refresh()

func _d_bot() -> void:
	var o := Durak.actor(d_state)
	if o == "" or MatchState.seat_kind(d_state, o) != "bot":
		return
	var act := Durak.bot_action(d_state)
	if act.is_empty():
		# ходить нечем и кон не закрыт — такого быть не должно, но экран не вешаем
		if String(d_state["phase"]) == "attack" and not d_state["table"].is_empty():
			await _d_bito(o)
		else:
			busy = true
			_d_refresh()
		return
	match String(act["act"]):
		"attack":
			await _d_attack(o, int(act["hand"]))
		"defend":
			await _d_defend(o, int(act["hand"]))
		"bito":
			await _d_bito(o)
		"take":
			await _d_take(o)

## По сети уходит само действие, а не состояние: сиденье, что сделал и каким
## кубом руки. Раздача у обоих от одного сида, поэтому индекса достаточно.
func _d_send(seat: String, act: String, idx: int = -1) -> void:
	if opponent == "remote" and lan != null and lan.connected:
		lan.send_durak_action(seat, act, idx)

func _on_lan_durak_action(seat: String, act: String, hand_idx: int) -> void:
	if d_state.is_empty() or not in_durak:
		return
	match act:
		"attack":
			await _d_attack(seat, hand_idx, false)
		"defend":
			await _d_defend(seat, hand_idx, false)
		"bito":
			await _d_bito(seat, false)
		"take":
			await _d_take(seat, false)

func _d_hand_pressed(idx: int) -> void:
	if not _d_input_allowed():
		return
	var o := Durak.actor(d_state)
	if o != _d_viewer():
		return
	if String(d_state["phase"]) == "attack":
		await _d_attack(o, idx)
	else:
		await _d_defend(o, idx)

## broadcast=false — действие пришло по сети и рассылать его обратно нельзя.
func _d_attack(seat: String, idx: int, broadcast: bool = true) -> void:
	var first: bool = d_state["table"].is_empty()
	var res := Durak.attack(d_state, seat, idx)
	if res.is_empty():
		return
	if broadcast:
		_d_send(seat, "attack", idx)
	busy = true
	buzz(20)
	d_toast("%s %s %s" % [MatchState.seat_name(d_state, seat),
		"атакует:" if first else "подкидывает:", _d_name(res["die"])], seat != _d_viewer())
	_d_refresh()
	await get_tree().create_timer(0.55).timeout
	if d_state.is_empty() or not in_durak:
		return
	await _durak_next(0.7)

func _d_defend(seat: String, idx: int, broadcast: bool = true) -> void:
	var res := Durak.defend(d_state, seat, idx)
	if res.is_empty():
		return
	if broadcast:
		_d_send(seat, "defend", idx)
	busy = true
	buzz(20)
	d_toast("%s отбил %s %s" % [MatchState.seat_name(d_state, seat),
		_d_name(res["against"], "acc"), _d_name(res["die"], "ins")], seat != _d_viewer())
	_d_refresh()
	await get_tree().create_timer(0.55).timeout
	if d_state.is_empty() or not in_durak:
		return
	await _durak_next(0.7)

func _d_bito(seat: String, broadcast: bool = true) -> void:
	if String(d_state["phase"]) != "attack" or Durak.undefended_idx(d_state) >= 0:
		return
	d_frozen = d_state["table"].duplicate()
	var res := Durak.bito(d_state, seat)
	if res.is_empty():
		d_frozen = []
		return
	if broadcast:
		_d_send(seat, "bito")
	busy = true
	d_toast("Бито")
	_d_refresh()
	await get_tree().create_timer(0.65).timeout
	d_frozen = []
	if d_state.is_empty() or not in_durak:
		return
	_d_refresh()
	await _durak_next(0.8)

func _d_take(seat: String, broadcast: bool = true) -> void:
	if String(d_state["phase"]) != "defend":
		return
	d_frozen = d_state["table"].duplicate()
	var res := Durak.take(d_state, seat)
	if res.is_empty():
		d_frozen = []
		return
	if broadcast:
		_d_send(seat, "take")
	busy = true
	buzz(120)
	# кубы приезжают в руку мгновенно и незаметно. Баннер по центру лёг бы на сам
	# стол, который игрок как раз должен разглядеть, поэтому говорим крупно в
	# строке подсказки и держим паузу подольше.
	var taken := 0
	for pair in d_frozen:
		taken += 1 if pair["d"] == null else 2
	var mine := seat == _d_viewer()
	var phrase := "+%d %s в руку" % [taken, _plural(taken, "куб", "куба", "кубов")]
	d_notice = ("ЗАБИРАЕШЬ СТОЛ · %s" % phrase) if mine \
		else ("СОПЕРНИК ЗАБИРАЕТ СТОЛ · %s" % phrase)
	d_toast("%s забирает стол" % MatchState.seat_name(d_state, seat), not mine)
	_d_refresh()
	await get_tree().create_timer(1.4).timeout
	d_notice = ""
	d_frozen = []
	if d_state.is_empty() or not in_durak:
		return
	_d_refresh()
	await _durak_next(0.8)

## Исход партии. Дуракуб — тот, кто остался с кубами; против бота говорим на «ты».
func _d_finish() -> void:
	busy = true
	_d_refresh()
	await get_tree().create_timer(0.6).timeout
	if d_state.is_empty() or not in_durak:
		return
	var loser := String(d_state["outcome"]["loser"])
	var mine := _my_view(d_state)
	var title := "НИЧЬЯ"
	var text := "Оба вышли одновременно — дуракубов сегодня нет."
	if loser != "":
		var winner := MatchState.other_seat(d_state, loser)
		if _solo(d_state) and loser == mine:
			# та самая фраза, из-за которой в это вообще играют
			title = "ТЫ ДУРАКУБ!"
			text = "Ты остался с кубами. Позор на все подземелья."
		elif _solo(d_state):
			title = "ПОБЕДА!"
			text = "Соперник остался с кубами — дуракуб он."
		else:
			title = MatchState.seat_name(d_state, loser).to_upper() + " — ДУРАКУБ!"
			text = "%s вышел первым, а %s остался с кубами." % [
				MatchState.seat_name(d_state, winner), MatchState.seat_name(d_state, loser)]
	_show_result(title, text, "Ещё раз", _start_durak)

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
	menu_hint = _label("", 12, Palette.MUTED)
	menu_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(menu_hint)
	# сообщения, пока открыто меню: обычный тост лежит под этим слоем и не виден
	menu_note = _label("", 11, Palette.GOLD_LIGHT)
	menu_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	menu_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	menu_note.custom_minimum_size.x = 300
	v.add_child(menu_note)

	# Шаг 1: с кем играем. Раньше вместо этого был чекбокс «2 игрока на одном
	# телефоне» рядом с режимами — из него не читалось, что игр вообще три вида.
	kind_box = VBoxContainer.new()
	kind_box.add_theme_constant_override("separation", 8)
	v.add_child(kind_box)
	kind_box.add_child(_kind_button("Одиночная", "против бота", func():
		opponent = "bot"
		_show_modes()
	))
	kind_box.add_child(_kind_button("Двое на одном телефоне", "по очереди, с ширмой при передаче", func():
		opponent = "human"
		_show_modes()
	))
	kind_box.add_child(_kind_button("По Wi-Fi", "с другом рядом, в одной сети Wi-Fi", func():
		_show_lobby()
	))
	kind_box.add_child(_kind_button("По сети", "пока не доступно", Callable(), true))
	var name_btn := _button("Сменить имя", true)
	name_btn.pressed.connect(func(): _show_name_screen(false))
	kind_box.add_child(name_btn)
	# Замер запуска. Нужен, чтобы не гадать: если «движок» большой, время уходит
	# до нашего кода — на распаковку библиотеки и проверки системы, и лечится это
	# сборкой, а не игрой.
	boot_note = _label("", 9, Palette.MUTED)
	boot_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	kind_box.add_child(boot_note)
	var quit_btn := _button("Выход", true)
	quit_btn.pressed.connect(func(): get_tree().quit())
	kind_box.add_child(quit_btn)

	# Шаг 2: режим. Тот же список, что был, плюс возврат к выбору вида игры.
	modes_box = VBoxContainer.new()
	modes_box.add_theme_constant_override("separation", 8)
	modes_box.visible = false
	v.add_child(modes_box)
	for key in MatchState.MODE_ORDER:
		modes_box.add_child(_mode_button(key, MatchState.MODES[key]))
	modes_box.add_child(_mode_button("durak", MatchState.DURAK_MODE))
	var back_btn := _button("Назад", true)
	back_btn.pressed.connect(_show_kinds)
	modes_box.add_child(back_btn)
	return layer

## Кнопка вида игры: название и пояснение. Недоступный вид показываем, но не
## включаем — иначе непонятно, что сетевая игра планируется.
func _kind_button(title: String, sub: String, on_press: Callable, disabled: bool = false) -> Control:
	var box := PanelContainer.new()
	box.add_theme_stylebox_override("panel", _mode_box())
	box.custom_minimum_size.x = 300
	if disabled:
		box.modulate = Color(1, 1, 1, 0.45)
		box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	else:
		box.mouse_filter = Control.MOUSE_FILTER_STOP
		box.gui_input.connect(func(e: InputEvent):
			if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
				on_press.call()
		)
	var inner := VBoxContainer.new()
	inner.add_theme_constant_override("separation", 3)
	inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(inner)
	inner.add_child(_label(title, 14, Palette.GOLD_LIGHT))
	var s := _label(sub, 11, Palette.MUTED)
	s.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	s.custom_minimum_size.x = 268
	s.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner.add_child(s)
	return box

## Шаг 1 меню: с кем играем.
func _show_kinds() -> void:
	kind_box.visible = true
	modes_box.visible = false
	menu_hint.text = "Привет, %s! С кем играем?" % Profile.display_name()

## Шаг 2 меню: во что играем.
func _show_modes() -> void:
	kind_box.visible = false
	modes_box.visible = true
	menu_hint.text = "Выбери режим"

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

## Экран имени: спрашивается один раз при первом запуске, потом доступен из меню.
## Имя видят соперники по Wi-Fi, поэтому об этом честно предупреждаем.
func _build_name_screen() -> Control:
	var layer := _full_dim(0.98)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(center)
	var panel := _panel(Palette.PANEL_2)
	center.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	v.custom_minimum_size.x = 300
	panel.add_child(v)
	var t := _label("КАК ТЕБЯ ЗВАТЬ?", 20, Palette.GOLD, Palette.FONT_TITLE)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(t)
	var sub := _label("Имя будет стоять в игре и увидят соперники по Wi-Fi.", 11, Palette.MUTED)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sub.custom_minimum_size.x = 290
	v.add_child(sub)
	name_input = LineEdit.new()
	name_input.max_length = Profile.MAX_LEN
	name_input.placeholder_text = "Игрок"
	name_input.alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_input.custom_minimum_size.y = 44
	name_input.add_theme_font_size_override("font_size", 16)
	name_input.text_submitted.connect(func(_t: String): _save_name())
	v.add_child(name_input)
	name_error = _label("", 11, Palette.NEG)
	name_error.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_error.custom_minimum_size.y = 16
	v.add_child(name_error)
	var ok := _button("Готово")
	ok.pressed.connect(_save_name)
	v.add_child(ok)
	name_cancel = _button("Отмена", true)
	name_cancel.pressed.connect(func():
		name_layer.visible = false
		_show_menu()
	)
	v.add_child(name_cancel)
	return layer

## first_run — экран нельзя закрыть, пока имя не введено: без него дальше игра
## подписывала бы игрока безликим «Игрок».
func _show_name_screen(first_run: bool) -> void:
	if name_layer == null:
		name_layer = _build_name_screen()
		add_child(name_layer)
	name_input.text = Profile.player_name()
	name_error.text = ""
	name_cancel.visible = not first_run
	name_layer.visible = true
	menu_layer.visible = not first_run
	name_input.grab_focus()

func _save_name() -> void:
	if not Profile.save_name(name_input.text):
		name_error.text = "Впиши хотя бы одну букву."
		return
	name_layer.visible = false
	# имя своего сиденья меняем и в идущей партии, чтобы не ждать следующей
	for st in [state, d_state]:
		if not st.is_empty() and st.has("seats"):
			for seat in st["order"]:
				if String(st["seats"][seat]["kind"]) == "human" and bool(st["seats"][seat]["local"]) \
						and (not MatchState.shared_device(st) or seat == "p"):
					st["seats"][seat]["name"] = Profile.display_name()
	_show_menu()
	_refresh_screen()

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

## Лобби локальной игры. Хост поднимает партию, второй ищет его широковещательным
## запросом — адрес вводить не нужно, оба телефона просто в одной сети Wi-Fi.
func _build_lobby() -> Control:
	var layer := _full_dim(0.96)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(center)
	var panel := _panel(Palette.PANEL_2)
	center.add_child(panel)
	lobby_box = VBoxContainer.new()
	lobby_box.add_theme_constant_override("separation", 10)
	lobby_box.custom_minimum_size.x = 300
	panel.add_child(lobby_box)
	return layer

func _show_lobby() -> void:
	menu_layer.visible = false
	lobby_layer.visible = true
	_lobby_idle()

func _lobby_idle() -> void:
	for c in lobby_box.get_children():
		c.queue_free()
	var t := _label("ИГРА ПО WI-FI", 20, Palette.GOLD, Palette.FONT_TITLE)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lobby_box.add_child(t)
	var hint_l := _label("Оба устройства должны быть в одной сети Wi-Fi. Интернет не нужен.", 11, Palette.MUTED)
	hint_l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint_l.custom_minimum_size.x = 290
	hint_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lobby_box.add_child(hint_l)

	var host_btn := _button("Создать игру")
	host_btn.pressed.connect(_lan_host)
	lobby_box.add_child(host_btn)
	var find_btn := _button("Найти игру")
	find_btn.pressed.connect(_lan_find)
	lobby_box.add_child(find_btn)
	var back := _button("Назад", true)
	back.pressed.connect(func():
		if lan != null:
			lan.stop()
		lobby_layer.visible = false
		_show_menu()
	)
	lobby_box.add_child(back)

func _lobby_message(text: String, with_back: bool = true) -> void:
	for c in lobby_box.get_children():
		c.queue_free()
	var t := _label("ИГРА ПО WI-FI", 20, Palette.GOLD, Palette.FONT_TITLE)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lobby_box.add_child(t)
	var m := _label(text, 12, Palette.TEXT)
	m.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	m.custom_minimum_size.x = 290
	m.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lobby_box.add_child(m)
	if with_back:
		var back := _button("Назад", true)
		back.pressed.connect(func():
			if lan != null:
				lan.stop()
			_lobby_idle()
		)
		lobby_box.add_child(back)

func _lan_host() -> void:
	_ensure_lan()
	# представляемся именем профиля: соперник увидит «Рустам», а не IP или модель
	if not lan.start_host(Profile.display_name()):
		_lobby_message("Не удалось открыть игру: порт занят. Закрой другую копию игры и попробуй снова.")
		return
	my_seat = "p"
	opponent = "remote"
	var ips: Array = Lan.local_ipv4()
	var addr: String = String(ips[0]) if not ips.is_empty() else "адрес не определён"
	var text := "Ждём соперника…\nПусть он нажмёт «Найти игру».\n\nТебя найдут как: %s\nАдрес: %s" % [
		Profile.display_name(), addr]
	if not lan.discovery_ok:
		# порт обнаружения занят: сама игра поднялась, но найти её не смогут
		text += "\n\nПоиск занят другой копией игры — соперник тебя не найдёт, пусть введёт адрес вручную."
	_lobby_message(text)

func _lan_find() -> void:
	_ensure_lan()
	_lobby_message("Ищем игру в сети…", false)
	lan.discover()

## Не нашли. Даём и повтор поиска, и ввод адреса руками: обнаружение зависит от
## того, пропускает ли сеть широковещательные пакеты, а прямое подключение по
## адресу работает всегда.
func _lobby_not_found() -> void:
	for c in lobby_box.get_children():
		c.queue_free()
	var t := _label("ИГРУ НЕ НАШЛИ", 18, Palette.GOLD, Palette.FONT_TITLE)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lobby_box.add_child(t)
	var m := _label("Проверь, что оба телефона в одной сети Wi-Fi и соперник нажал «Создать игру». Если не находит — попроси у него адрес, он написан у него на экране.", 12, Palette.TEXT)
	m.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	m.custom_minimum_size.x = 290
	m.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lobby_box.add_child(m)
	var again := _button("Искать снова")
	again.pressed.connect(_lan_find)
	lobby_box.add_child(again)
	var manual := _button("Ввести адрес")
	manual.pressed.connect(_lobby_manual)
	lobby_box.add_child(manual)
	var back := _button("Назад", true)
	back.pressed.connect(func():
		if lan != null:
			lan.stop()
		_lobby_idle()
	)
	lobby_box.add_child(back)

## Ввод адреса вручную — гарантированный путь, когда обнаружение не работает.
func _lobby_manual() -> void:
	for c in lobby_box.get_children():
		c.queue_free()
	var t := _label("АДРЕС СОПЕРНИКА", 18, Palette.GOLD, Palette.FONT_TITLE)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lobby_box.add_child(t)
	var m := _label("Адрес показан на экране того, кто создал игру.", 11, Palette.MUTED)
	m.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	m.custom_minimum_size.x = 290
	m.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lobby_box.add_child(m)
	var field := LineEdit.new()
	field.placeholder_text = "192.168.1.42"
	field.alignment = HORIZONTAL_ALIGNMENT_CENTER
	field.custom_minimum_size.y = 44
	field.add_theme_font_size_override("font_size", 16)
	# подсказываем свою подсеть: у соперника адрес почти наверняка из неё же
	var mine: Array = Lan.local_ipv4()
	if not mine.is_empty():
		var parts: PackedStringArray = String(mine[0]).split(".")
		if parts.size() == 4:
			field.text = "%s.%s.%s." % [parts[0], parts[1], parts[2]]
			field.caret_column = field.text.length()
	lobby_box.add_child(field)
	var go := _button("Подключиться")
	var try_join := func():
		var addr := field.text.strip_edges()
		if addr == "" or not addr.contains("."):
			_lobby_message("Адрес непохож на адрес. Он выглядит так: 192.168.1.42")
			return
		my_seat = "e"
		opponent = "remote"
		if not lan.join(addr):
			_lobby_message("Не удалось подключиться к %s. Проверь адрес и что игра создана." % addr)
		else:
			_lobby_message("Подключаемся к %s…" % addr, false)
	go.pressed.connect(try_join)
	field.text_submitted.connect(func(_t: String): try_join.call())
	lobby_box.add_child(go)
	var back := _button("Назад", true)
	back.pressed.connect(_lobby_not_found)
	lobby_box.add_child(back)

func _ensure_lan() -> void:
	if lan != null:
		return
	lan = Lan.new()
	lan.name = Lan.NODE_NAME       # путь узла обязан совпадать на обоих устройствах
	add_child(lan)
	lan.peer_connected.connect(_on_lan_connected)
	lan.peer_lost.connect(_on_lan_lost)
	lan.hosts_found.connect(_on_lan_hosts)
	lan.match_started.connect(_on_lan_match_started)
	lan.move_received.connect(_on_lan_move)
	lan.next_round_received.connect(_on_lan_next_round)
	lan.match_left.connect(_on_lan_left)
	lan.durak_action_received.connect(_on_lan_durak_action)
	lan.peer_named.connect(_on_lan_peer_named)

func _on_lan_hosts(list: Array) -> void:
	if list.is_empty():
		_lobby_not_found()
		return
	for c in lobby_box.get_children():
		c.queue_free()
	var t := _label("НАЙДЕННЫЕ ИГРЫ", 18, Palette.GOLD, Palette.FONT_TITLE)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lobby_box.add_child(t)
	# считаем тёзок: два «Игрока» в списке не различить, тогда добавим адрес
	var seen := {}
	for h in list:
		var nm := String(h["name"])
		seen[nm] = int(seen.get(nm, 0)) + 1
	for h in list:
		# показываем имя игрока, IP не показываем — он ни о чём не говорит
		var addr := String(h["address"])
		var tail := addr.substr(addr.rfind(".") + 1)
		var label := String(h["name"])
		if label == "":
			label = "Игрок %s" % tail
		elif int(seen.get(label, 0)) > 1:
			label = "%s · %s" % [label, tail]
		var b := _button(label)
		b.pressed.connect(func():
			my_seat = "e"       # у клиента своё сиденье второе
			opponent = "remote"
			foe_player = String(h["name"])
			if not lan.join(String(h["address"])):
				_lobby_message("Не удалось подключиться. Попробуй ещё раз.")
			else:
				_lobby_message("Подключаемся…", false)
		)
		lobby_box.add_child(b)
	var back := _button("Назад", true)
	back.pressed.connect(_lobby_idle)
	lobby_box.add_child(back)

func _on_lan_peer_named(name_of_peer: String) -> void:
	if name_of_peer == "":
		return
	foe_player = name_of_peer
	# имя могло прийти уже после начала партии — подставляем на месте
	for st in [state, d_state]:
		if not st.is_empty() and st.has("seats"):
			for seat in st["order"]:
				if String(st["seats"][seat]["kind"]) == "remote":
					st["seats"][seat]["name"] = foe_player
	_refresh_screen()

func _on_lan_connected() -> void:
	foe_left = false
	lan.send_hello()          # обе стороны сразу представляются
	if lan.is_host:
		# хост выбирает режим; клиент ждёт объявления партии
		lobby_layer.visible = false
		menu_layer.visible = true
		# сразу второй шаг: на первом хост выбрал бы «Одиночную» и порвал сетевую
		# партию, ведь тот экран переставляет opponent
		_show_modes()
		menu_note.text = "%s подключился — выбери режим." % foe_player
	else:
		_lobby_message("Подключились! Ждём, пока хост выберет режим…", false)

func _on_lan_lost() -> void:
	# соперник вышел сам — «СОПЕРНИК ВЫШЕЛ» уже показан, обрыв связи вдогонку
	# не должен перекрывать его окном «СВЯЗЬ ПОТЕРЯНА»
	if foe_left:
		return
	# отложенные шаги прежней партии не должны шевелить состояние под оверлеем
	_new_flow()
	if state.is_empty() and d_state.is_empty():
		_lobby_message("Соперник отключился.")
	else:
		busy = true
		_show_result("СВЯЗЬ ПОТЕРЯНА", "Соперник отключился.", "В меню", _show_menu)

func _on_lan_left() -> void:
	# сами уже вышли (встречное «вышел») или партия не сетевая — просто прибрать
	if not lan.connected or opponent != "remote":
		lan.stop.call_deferred()
		return
	foe_left = true
	_new_flow()
	# связь закрываем отложенно: сигнал пришёл изнутри опроса сети, выдёргивать
	# пир прямо под ним не стоит
	lan.stop.call_deferred()
	if state.is_empty() and d_state.is_empty():
		_lobby_message("Соперник вышел.")
		return
	busy = true
	_show_result("СОПЕРНИК ВЫШЕЛ", "Соперник покинул партию.", "В меню", _show_menu)

func _on_lan_match_started(mode: String, seed_value: int) -> void:
	# клиент собирает ту же партию из присланного сида
	lobby_layer.visible = false
	opponent = "remote"
	if mode == "durak":
		await _start_durak(seed_value)
		return
	_launch_match(mode, seed_value)

func _on_lan_move(seat: String, hand_idx: int, cell_idx: int) -> void:
	# ход соперника прилетел данными и применяется той же логикой, но не сразу:
	# пока идёт анимация или пас-таймер, advance ещё не передал ход сопернику, и
	# немедленный _do_move продвинул бы счётчики дважды — дальше раунды и жизни
	# закрываются в разное время и матчи расходятся
	if state.is_empty() or bool(state["over"]):
		return
	net_moves.append({"seat": seat, "hand": hand_idx, "cell": cell_idx})
	_try_net_move()

## Отложенный ход соперника применяется, когда поток дошёл до его ожидания.
func _try_net_move() -> void:
	if not waiting_remote or net_moves.is_empty():
		return
	waiting_remote = false
	var mv: Dictionary = net_moves.pop_front()
	_do_move(String(mv["seat"]), int(mv["hand"]), int(mv["cell"]), false)

func _on_lan_next_round() -> void:
	if state.is_empty():
		return
	# свой раунд ещё доигрывается (анимация финального хода, фанфара) — новый
	# начнём, когда цепочка сама закроет раунд: иначе new_round затёр бы доску до
	# close_round, жизнь осталась бы не списанной и счёт разошёлся бы с хостом
	if not over_layer.visible:
		pending_next_round = true
		return
	_next_round()

## Открыть следующий раунд. У хоста — по кнопке «Следующий раунд», у клиента —
## по сообщению сети; тело одно, чтобы экраны не расходились.
func _next_round() -> void:
	_new_flow()
	over_layer.visible = false
	MatchState.new_round(state)
	hist_sel = -1
	for c in card_box.get_children():
		c.queue_free()
	toast("")
	_refresh()
	banner("РАУНД %d" % int(state["round"]))
	_begin_turn(String(state["turn"]))

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

	rules_battle_box = VBoxContainer.new()
	rules_battle_box.add_theme_constant_override("separation", 8)
	v.add_child(rules_battle_box)
	var rb := rules_battle_box
	rb.add_child(_rules_head("Ход"))
	rb.add_child(_rules_line("Выбери куб в руке и поставь на пустую клетку или съешь вражеский."))
	rb.add_child(_rules_line("Базовый куб ест куб со значением не больше своего: шестёрка ест всех, единица — только единицу."))
	rb.add_child(_rules_head("Очки за ход"))
	rb.add_child(_rules_line("Съел — значение съеденного куба."))
	rb.add_child(_rules_line("Кубы на поле — сумма значений всех твоих кубов, начисляется каждый ход."))
	rb.add_child(_rules_line("Комбо из твоих кубов: пара +5, две пары +10, сет +15, фулл-хаус +25, каре +40, пятёрка +60, шестёрка +100."))
	rb.add_child(_rules_head("Особые кубы"))
	for key in ["shield", "spikes", "mine", "jaw", "friendly", "warlock"]:
		rb.add_child(_ability_row(key))

	rules_durak_box = VBoxContainer.new()
	rules_durak_box.add_theme_constant_override("separation", 8)
	rules_durak_box.visible = false
	v.add_child(rules_durak_box)
	var rd := rules_durak_box
	rd.add_child(_rules_head("Дуракуб"))
	rd.add_child(_rules_line("Подкидной дурак кубами: 24 куба, четыре масти по значениям от 1 до 6."))
	rd.add_child(_rules_line("Козырь — масть нижнего куба колоды, он написан в шапке. Козырные кубы обведены золотом."))
	rd.add_child(_rules_head("Атака и отбой"))
	rd.add_child(_rules_line("Атакующий выкладывает куб, защитник бьёт его старшим той же масти или любым козырём."))
	rd.add_child(_rules_line("Отбил — атакующий может подкинуть куб со значением, которое уже лежит на столе."))
	rd.add_child(_rules_line("Подкидывать больше нечего или незачем — «Бито»: стол уходит в отбой, роли меняются."))
	rd.add_child(_rules_line("Не отбился — «Взять»: весь стол уходит в руку, атакует тот же соперник."))
	rd.add_child(_rules_line("Атак в коне не больше, чем кубов было в руке защитника, и не больше шести."))
	rd.add_child(_rules_head("Конец партии"))
	rd.add_child(_rules_line("После кона руки добираются до шести из колоды, первым добирает атакующий."))
	rd.add_child(_rules_line("Колода кончилась и кто-то вышел без кубов — партия всё. Остался с кубами — ты дуракуб."))
	rd.add_child(_rules_line("Способностей и очков здесь нет — только масти, значения и козырь."))

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
	_new_flow()
	# уход в меню — выход из сетевой партии: сопернику уходит «вышел», связь
	# закрывается внутри send_leave вежливым разрывом. Без этого соперник
	# оставался на «Ждём хоста…» или ждал хода до конца времён.
	if opponent == "remote" and lan != null and lan.connected:
		lan.send_leave()
	_reset_shift()
	menu_layer.visible = true
	veil_layer.visible = false
	over_layer.visible = false
	menu_note.text = ""
	_show_kinds()          # меню всегда открывается с выбора вида игры
	_hide_banner()

func _show_rules() -> void:
	if rules_layer == null:
		rules_layer = _build_rules()
		add_child(rules_layer)
	# правила у Дуракуба свои: ни очков, ни способностей — только масти и козырь
	rules_battle_box.visible = not in_durak
	rules_durak_box.visible = in_durak
	rules_layer.visible = true
	_hide_banner()

## Начинается новая партия, раунд или меню: всё отложенное от прежнего потока —
## таймеры пасов, раздумье бота, недоигранные фанфары — сгорает по токену.
func _new_flow() -> void:
	flow_token += 1
	net_moves.clear()
	waiting_remote = false
	pending_next_round = false

func _start_mode(key: String) -> void:
	if key == "durak":
		await _start_durak()
		return
	var seed_value := int(Time.get_unix_time_from_system()) & 0x7fffffff
	if opponent == "remote" and lan != null and lan.is_host:
		lan.send_start(key, seed_value)      # соперник соберёт ту же раздачу из сида
	_launch_match(key, seed_value)

## Общий хвост запуска боевой партии: у хоста и одиночки из _start_mode, у
## клиента из _on_lan_match_started. Раньше клиент собирал партию своей копией
## этого кода, и в ней не гасился оверлей исхода: после «Ещё раз» у хоста клиент
## смотрел на «Ждём хоста…» поверх уже идущей новой партии.
func _launch_match(key: String, seed_value: int) -> void:
	_new_flow()
	_reset_shift()
	menu_layer.visible = false
	over_layer.visible = false
	in_durak = false
	d_state = {}
	durak_layer.visible = false
	battle_root.visible = true
	selected = -1
	state = MatchState.new_match(key, seed_value, opponent, my_seat, foe_player, Profile.display_name())
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
	var tok := flow_token
	if MatchState.seat_kind(state, seat) == "remote":
		busy = true
		_refresh()
		# ход мог прийти раньше, чем мы досмотрели свою анимацию — забираем из очереди
		waiting_remote = true
		_try_net_move()
		return
	if MatchState.seat_kind(state, seat) == "bot":
		busy = true
		_refresh()
		await get_tree().create_timer(BOT_DELAY).timeout
		if state.is_empty() or tok != flow_token:
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
	# баннер раунда живёт своей анимацией и успевает лечь поверх заголовка ширмы
	_hide_banner()
	var st: Dictionary = d_state if in_durak else state
	veil_title.text = "%s, твой ход" % MatchState.seat_name(st, seat)
	veil_layer.visible = true
	_refresh_screen()

func _hide_veil() -> void:
	veil_layer.visible = false
	if in_durak:
		d_state["shown_to"] = Durak.actor(d_state)
	else:
		state["shown_to"] = String(state["turn"])
	busy = false
	_refresh_screen()

## Перерисовка того экрана, который сейчас открыт. Ширма, исходы и меню общие для
## боевых режимов и Дуракуба, а состояния у них разные.
func _refresh_screen() -> void:
	if in_durak:
		_d_refresh()
	else:
		_refresh()

func _hide_banner() -> void:
	# баннер живёт своей анимацией и успевает наложиться на кнопки оверлея.
	# Гасить одну альфу недостаточно — твин её тут же поднимает обратно.
	if _banner_tween != null and _banner_tween.is_valid():
		_banner_tween.kill()
	var panel := banner_panel
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
	# перенос обязателен: без него длинная фраза растягивала панель за края экрана
	var t := _label(title, 22, Palette.GOLD, Palette.FONT_TITLE)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	t.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	t.custom_minimum_size.x = 300
	box.add_child(t)
	var d := _label(detail, 13, Palette.TEXT)
	d.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	d.custom_minimum_size.x = 300
	box.add_child(d)
	# В сетевой игре раунд двигает только хост: если кнопку нажмут оба, раунд
	# продвинется дважды и состояния разъедутся.
	var client_waits: bool = opponent == "remote" and lan != null and not lan.is_host and button != "В меню"
	if client_waits:
		var w := _label("Ждём хоста…", 12, Palette.MUTED)
		w.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		box.add_child(w)
	else:
		var b := _button(button)
		b.pressed.connect(func():
			over_layer.visible = false
			on_press.call()
		)
		box.add_child(b)
	# вторая кнопка не нужна, когда основная и так ведёт в меню: при обрыве связи
	# получалось два одинаковых «В меню» подряд
	if button != "В меню":
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
		my_hearts.setup(Rules.LIVES_MAX, int(state["players"][me]["lives"]))
		foe_hearts.setup(Rules.LIVES_MAX, int(state["players"][foe]["lives"]))
		my_hearts.visible = true
		foe_hearts.visible = true
	elif kind == "bo3":
		my_hearts.setup(2, int(state["players"][me]["wins"]), LifeRow.KIND_STAR, Palette.GOLD)
		foe_hearts.setup(2, int(state["players"][foe]["wins"]), LifeRow.KIND_STAR, Palette.GOLD)
		my_hearts.visible = true
		foe_hearts.visible = true
	else:
		my_hearts.visible = false
		foe_hearts.visible = false
	my_deck.text = "Колода: %d" % state["players"][me]["deck"].size()
	var turn := String(state["turn"])
	var move_no: int = mini(int(state["players"][turn]["moves"]) + 1, int(cfg["moves"]))
	turn_info.text = "РАУНД %d · ХОД %d/%d" % [int(state["round"]), move_no, int(cfg["moves"])]
	if _solo(state) and turn == me:
		turn_who.text = "ТВОЙ ХОД"
	elif _solo(state):
		turn_who.text = "ХОД СОПЕРНИКА"
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
		sb.content_margin_top = 8
		sb.content_margin_bottom = 8
		pill.add_theme_stylebox_override("panel", sb)
		pill.custom_minimum_size.y = 40      # попасть пальцем в 22 px невозможно
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
		# крупно — накопленное за раунд удержание, мелко — сколько держим сейчас:
		# раунд решает первое, и игрок должен видеть именно ту цифру, по которой
		# его судят
		var held := int(state["players"][seat].get("held", 0))
		var now := Rules.owner_count(state["board"], seat)
		return "%d · сейчас %d" % [held, now]
	return str(sc)

func _rebuild_board(me: String) -> void:
	for c in board_grid.get_children():
		c.queue_free()
	var cols := int(state["cfg"]["cols"])
	var cell_w := _cell_size(cols, state["board"].size())
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
			# лицо куба привязано к СИДЕНЬЮ, а не к «свой/чужой»: кость — первое
			# сиденье, кровь — второе. Иначе у второго игрока кубы в руке красные,
			# а на доске становились белыми
			d.setup(int(cell["v"]), String(cell["type"]), String(cell["owner"]) == "p",
				not hidden or seen, int(cell["shield"]))

## Размер клетки: по ширине экрана, но не выше того, что осталось от высоты.
## На поле 3×3 и на невысоких экранах доска иначе не влезает вместе с рукой.
## 582 — всё, кроме доски: титул, зона соперника, тост, шапка хода, подсказка,
## лента, карточка, своя зона с рукой и отступы между ними. Мерено по снимку на
## 390×844: на поле 3×2 клетку это не трогает, а на 3×3 она мельчает, и рука
## перестаёт уезжать под край экрана.
func _cell_size(cols: int, cells: int) -> float:
	var rows: int = ceili(float(cells) / float(cols))
	var by_width: float = (390.0 - _safe.x - _safe.z - CELL_GAP * (cols - 1)) / float(cols)
	# из высоты вычитаем и безопасную зону: под системной панелью рисовать нельзя
	var budget: float = get_viewport_rect().size.y - _safe.y - _safe.w - 554.0
	var by_height: float = (budget - CELL_GAP * (rows - 1)) / float(rows)
	return maxf(minf(by_width, by_height), 52.0)

func _rebuild_hand(me: String) -> void:
	for c in hand_row.get_children():
		c.queue_free()
	var hand: Array = state["players"][me]["hand"]
	var can := input_allowed() and String(state["turn"]) == me
	for i in hand.size():
		var die: Dictionary = hand[i]
		var d := DieView.new()
		d.custom_minimum_size = Vector2(hand_px, hand_px)
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
		var k := MatchState.seat_kind(state, turn)
		sel_info.text = "Соперник думает…" if k == "bot" else ("Ход соперника…" if k == "remote" else "Секунду…")
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

func _do_move(seat: String, hand_idx: int, cell_idx: int, broadcast: bool = true) -> void:
	var tok := flow_token
	busy = true
	selected = -1
	# по сети уходит сам ход, а не состояние: три числа вместо всей доски
	if broadcast and opponent == "remote" and lan != null and lan.connected:
		lan.send_move(seat, hand_idx, cell_idx)
	var res := MatchState.play(state, seat, hand_idx, cell_idx)
	_refresh()
	_animate_place(int(res["placed"]))
	if bool(res["mined"]):
		_boom(res["boom"])
		toast("Мина! Ход сгорел", seat != viewer())
	else:
		_play_effects(res)     # шипы, колдун, челюсть, дружелюбный
	var combo: Dictionary = res["combo"]
	if not combo.is_empty() and int(combo["bonus"]) > 0:
		# выкрик по центру поля для любой комбинации, от пары до шестёрки: она
		# начисляется каждый ход, и игрок должен видеть, за что
		_combo_call(String(combo["name"]), int(combo["bonus"]))
		if int(combo["bonus"]) >= 25:
			_combo_flash()
			_shake(4.0, 0.2)
	await _play_card(res)
	if tok != flow_token:
		return
	_after_move()

func _after_move() -> void:
	var tok := flow_token
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
			await _round_fanfare(String(out["winner"]), String(out["detail"]))
			if tok != flow_token:
				return
			# хост успел открыть следующий раунд, пока у нас шла фанфара — не
			# показываем исход поверх новой доски, а сразу догоняем
			if pending_next_round:
				_next_round()
				return
			_show_result(String(rp["title"]), String(rp["text"]), "Следующий раунд", func():
				if opponent == "remote" and lan != null and lan.connected:
					lan.send_next_round()
				_next_round()
			)
		"pass":
			toast("%s: нет ходов — пас" % MatchState.seat_name(state, String(ev["seat"])),
				String(ev["seat"]) != viewer())
			_refresh()
			await get_tree().create_timer(0.9).timeout
			if tok != flow_token:
				return
			_after_move()
		"turn":
			await _begin_turn(String(ev["seat"]))

## За экраном один человек — против бота и по сети. Тогда о нём говорим на «ты», а
## о сопернике в третьем лице. В хотсите за экраном двое, там только имена.
## Раньше это условие было «против бота», и по сети получалось «Ты теряет ♥»:
## имя своего сиденья в сетевой игре — «Ты», а фраза строилась в третьем лице.
func _solo(st: Dictionary) -> bool:
	return not st.is_empty() and not MatchState.shared_device(st)

## Подлежащее и сказуемое разом: «ты теряешь» / «Соперник теряет».
func _says(st: Dictionary, seat: String, second: String, third: String) -> String:
	if _solo(st) and seat == _my_view(st):
		return "ты " + second
	var who := "Соперник" if _solo(st) else MatchState.seat_name(st, seat)
	return "%s %s" % [who, third]

## Кто смотрит в экран: в хотсите — тот, кому он открыт, иначе своё сиденье.
func _my_view(st: Dictionary) -> String:
	if st.is_empty():
		return "p"
	if MatchState.shared_device(st):
		var shown := String(st["shown_to"])
		return shown if shown != "" else String(st.get("turn", "p"))
	return my_seat

## Имя в именительном падеже для заголовков: «ТЫ», «СОПЕРНИК», «ИГРОК 2».
func _who_name(st: Dictionary, seat: String) -> String:
	if _solo(st):
		return "ТЫ" if seat == _my_view(st) else "СОПЕРНИК"
	return MatchState.seat_name(st, seat).to_upper()

## Исход раунда до появления окна: свой раунд — золотая вспышка и баннер, чужой —
## красная и тряска. Раньше раунд просто заканчивался диалогом, и было непонятно,
## случилось хорошее или плохое.
func _round_fanfare(winner: String, detail: String) -> void:
	var mine := _my_view(state)
	# счёт идёт прямо в баннере: «раунд за соперником» без числа не говорит,
	# насколько всё плохо
	if winner == "":
		banner("НИЧЬЯ В РАУНДЕ
%s" % detail)
		_flash_screen(Color(0.6, 0.6, 0.7, 0.22), 0.35)
	elif winner == mine:
		buzz(70)
		var head := "РАУНД ТВОЙ!" if _solo(state) else MatchState.seat_name(state, winner).to_upper() + "!"
		banner("%s
%s" % [head, detail])
		_flash_screen(Color(1, 0.82, 0.35, 0.3), 0.45)
	else:
		buzz(160)
		var head2 := "РАУНД ЗА СОПЕРНИКОМ" if _solo(state) else MatchState.seat_name(state, winner).to_upper() + "!"
		banner("%s
%s" % [head2, detail])
		_flash_screen(Color(0.9, 0.2, 0.2, 0.32), 0.45)
		_shake(10.0, 0.4)
	# окно исхода ждёт, пока баннер отыграет: иначе он ляжет поверх кнопок
	await get_tree().create_timer(1.1).timeout

## Фразы исхода раунда: всегда говорим, что именно произошло, а не только счёт.
func _round_phrases(winner: String, detail: String) -> Dictionary:
	if winner == "":
		return {"title": "НИЧЬЯ В РАУНДЕ", "text": detail + " — никто не теряет ♥"}
	var loser := MatchState.other_seat(state, winner)
	var mine := _my_view(state)
	var title := ""
	if _solo(state):
		title = "РАУНД ТВОЙ!" if winner == mine else "РАУНД ЗА СОПЕРНИКОМ"
	else:
		title = MatchState.seat_name(state, winner).to_upper() + " БЕРЁТ РАУНД"
	var text := detail
	if String(state["cfg"]["kind"]) == "lives":
		text = "%s — %s ♥" % [detail, _says(state, loser, "теряешь", "теряет")]
	elif String(state["cfg"]["kind"]) == "bo3":
		text = "%s · победы %d : %d" % [detail,
			int(state["players"]["p"]["wins"]), int(state["players"]["e"]["wins"])]
	return {"title": title, "text": text}

## Фразы конца матча. «Победа / Жизни 3:0» звучало как отчёт судьи, поэтому
## говорим человеческим языком: кто и почему выиграл.
func _match_phrases(winner: String) -> Dictionary:
	var kind := String(state["cfg"]["kind"])
	var mine := _my_view(state)
	var solo := _solo(state)
	var vs_bot := MatchState.seat_kind(state, MatchState.other_seat(state, mine)) == "bot"
	var title := "НИЧЬЯ"
	if winner != "":
		if solo:
			title = "ПОБЕДА!" if winner == mine else "ПОРАЖЕНИЕ"
		else:
			title = MatchState.seat_name(state, winner).to_upper() + " ПОБЕДИЛ!"
	var text := ""
	match kind:
		"lives":
			var loser := MatchState.other_seat(state, winner) if winner != "" else ""
			if winner == "":
				text = "Жизни кончились у обоих одновременно."
			elif solo and winner == mine:
				text = "Враг повержен!" if vs_bot else "Соперник остался без жизней!"
			elif solo:
				text = "Подземелье забрало твои кости." if vs_bot else "Ты остался без жизней."
			else:
				text = "%s остался без жизней." % MatchState.seat_name(state, loser)
		"race":
			var target := int(state["cfg"]["target"])
			var sp := int(state["players"]["p"]["score"])
			var se := int(state["players"]["e"]["score"])
			if winner == "":
				text = "Ничья: %d : %d" % [sp, se]
			else:
				text = "%s до %d! Итог %d : %d" % [_cap(_says(state, winner, "добежал", "добежал")),
					target, sp, se]
		_:
			var wp := int(state["players"]["p"]["wins"])
			var we := int(state["players"]["e"]["wins"])
			if wp != we and winner != "":
				var w := maxi(wp, we)
				text = "%s %d %s из 3." % [_cap(_says(state, winner, "взял", "взял")),
					w, _plural(w, "раунд", "раунда", "раундов")]
			else:
				text = "Раунды поделили %d : %d, решили очки за матч: %d : %d" % [wp, we,
					int(state["players"]["p"]["total"]), int(state["players"]["e"]["total"])]
	return {"title": title, "text": text}

## Первая буква заглавной. `String.capitalize()` не годится: он поднимает каждое
## слово — «Ты Добежал».
func _cap(s: String) -> String:
	return s.substr(0, 1).to_upper() + s.substr(1) if s != "" else s

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

## Шапка карточки: «ТВОЙ ХОД 3» своему ходу, «СОПЕРНИК · ХОД 3» чужому. В хотсите
## вместо этого имена сидений.
func _card_head(seat: String, n: int) -> String:
	if _solo(state) and seat == _my_view(state):
		return "ТВОЙ ХОД %d" % n
	return "%s · ХОД %d" % [_who_name(state, seat), n]

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
	var htext := _card_head(seat, int(record["n"]))
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
	var head_text := _card_head(seat, state["history"].size())
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
	_pop_in(total, 1.45)
	# крупный итог хода — главное число карточки, поэтому он ещё и светится
	var glow := total.get_theme_color("font_color")
	var tw2 := create_tween()
	tw2.tween_property(total, "modulate", Color(1.6, 1.5, 1.2), 0.12)
	tw2.tween_property(total, "modulate", Color.WHITE, 0.3)
	if absi(pts) >= 40:
		buzz(50)
		_shake(3.0, 0.18)

## Короткое сообщение под зоной соперника: пас, взрыв, исход кона.
func toast(text: String, foe: bool = false) -> void:
	toast_label.text = text
	toast_label.add_theme_color_override("font_color", Palette.NEG if foe else Palette.GOLD_LIGHT)

## Баннер по центру: «РАУНД 2», «500!». Живёт полторы секунды и гаснет.
func banner(text: String) -> void:
	banner_label.text = text
	var panel: Control = banner_panel
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
	# только на телефоне: на Android вызов без разрешения VIBRATE валит процесс
	# нативным исключением, а на компьютере он просто ни к чему
	var os_name := OS.get_name()
	if os_name == "Android" or os_name == "iOS":
		Input.vibrate_handheld(pattern_ms)

## Взрыв мины: вспышка клетки и знак поверх неё.
func _boom(cells: Array) -> void:
	await get_tree().process_frame
	buzz(220)
	# взрыв должен быть событием, а не тихим исчезновением куба: вспышка на весь
	# экран, тряска, осколки и кольцо от каждой воронки
	_flash_screen(Color(1, 0.55, 0.2, 0.5), 0.4)
	_shake(12.0, 0.45)
	for ci2 in cells:
		_ring(int(ci2), Color(1, 0.66, 0.24), 3.0, 0.55)
		_shards(int(ci2), Color(1, 0.6, 0.25), 12)
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

# ------------------------------------------------------------------ эффекты
#
# Способности раньше были заметны только надписью в карточке хода: куб тихо
# исчезал, и «за что минус десять» игрок не понимал. Поэтому у каждого события
# теперь свой знак на самой доске — кольцо, тряска, всплывающее число.

## Центр клетки в координатах экрана — от него отталкиваются все эффекты.
func _cell_center(idx: int) -> Vector2:
	if idx < 0 or idx >= board_grid.get_child_count():
		return get_viewport_rect().size * 0.5
	var slot: Control = board_grid.get_child(idx)
	return slot.global_position + slot.size * 0.5

## Тряска экрана. Дёргаем корневой контейнер, а не камеру: интерфейс её не знает.
## Истинное положение экрана, к которому тряска обязана вернуться. Хранится
## отдельно: если два толчка наложатся, второй запомнил бы уже сдвинутое
## положение — и после серии экран так и остался бы съехавшим за край.
var _shake_tween: Tween

## Тряска сдвигает весь холст, а не контейнер экрана.
##
## Двигать контейнер нельзя: он привязан к краям экрана, и сдвиг сохраняется в
## его отступах. Стоило двум толчкам наложиться или анимации оборваться — и
## интерфейс залипал съехавшим за край, играть было нечем. У холста же нет
## никакого «своего» положения: сброс в единицу возвращает всё точно на место,
## что бы до этого ни случилось.
func _shake(power: float = 7.0, time: float = 0.28) -> void:
	if _shake_tween != null and _shake_tween.is_valid():
		_shake_tween.kill()
	_set_shake_offset(Vector2.ZERO)
	var tw := create_tween()
	_shake_tween = tw
	var steps := 6
	for i in steps:
		var k := 1.0 - float(i) / float(steps)
		var off := Vector2(rng.randf_range(-power, power), rng.randf_range(-power, power)) * k
		tw.tween_method(_set_shake_offset, _shake_offset_of(i, steps, power), off, time / float(steps))
	tw.tween_method(_set_shake_offset, Vector2.ZERO, Vector2.ZERO, 0.01)
	tw.tween_callback(func():
		_set_shake_offset(Vector2.ZERO)
		_shake_tween = null
	)

## Промежуточное смещение шага: начинаем с текущего, чтобы не было рывка.
func _shake_offset_of(i: int, steps: int, power: float) -> Vector2:
	if i == 0:
		return Vector2.ZERO
	var k := 1.0 - float(i - 1) / float(steps)
	return Vector2(rng.randf_range(-power, power), rng.randf_range(-power, power)) * k

func _set_shake_offset(off: Vector2) -> void:
	var vp := get_viewport()
	if vp != null:
		vp.canvas_transform = Transform2D(0.0, off)

## Короткая вспышка на весь экран — для взрыва и крупных событий.
func _flash_screen(col: Color, time: float = 0.3) -> void:
	var f := ColorRect.new()
	f.color = col
	f.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	f.mouse_filter = Control.MOUSE_FILTER_IGNORE
	f.z_index = 130
	add_child(f)
	var tw := create_tween()
	tw.tween_property(f, "color", Color(col.r, col.g, col.b, 0.0), time)
	tw.tween_callback(f.queue_free)

## Расширяющееся кольцо из клетки: «здесь что-то произошло».
func _ring(idx: int, col: Color, to_scale: float = 2.4, time: float = 0.45) -> void:
	await get_tree().process_frame
	var start := 46.0
	var ring := Panel.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0)
	sb.border_color = col
	sb.set_border_width_all(4)
	sb.set_corner_radius_all(int(start * 0.5))
	ring.add_theme_stylebox_override("panel", sb)
	ring.custom_minimum_size = Vector2(start, start)
	ring.size = Vector2(start, start)
	ring.pivot_offset = Vector2(start, start) * 0.5
	ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ring.z_index = 120
	add_child(ring)
	ring.global_position = _cell_center(idx) - Vector2(start, start) * 0.5
	var tw := create_tween().set_parallel(true)
	tw.tween_property(ring, "scale", Vector2(to_scale, to_scale), time).set_ease(Tween.EASE_OUT)
	tw.tween_property(ring, "modulate:a", 0.0, time)
	tw.chain().tween_callback(ring.queue_free)

## Всплывающая надпись над клеткой: значок способности и число.
func _float_text(idx: int, text: String, col: Color, size_px: int = 26) -> void:
	var box := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.02, 0.07, 0.82)
	sb.set_corner_radius_all(9)
	sb.border_color = Color(col.r, col.g, col.b, 0.55)
	sb.set_border_width_all(1)
	sb.content_margin_left = 9
	sb.content_margin_right = 9
	sb.content_margin_top = 2
	sb.content_margin_bottom = 2
	box.add_theme_stylebox_override("panel", sb)
	box.z_index = 125
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(_label(text, size_px, col, Palette.FONT_UI))
	add_child(box)
	await get_tree().process_frame
	await get_tree().process_frame
	# ставим над клеткой, а не по центру: иначе надпись ложится на цифру куба
	box.global_position = _cell_center(idx) - Vector2(box.size.x * 0.5, box.size.y + 6.0)
	box.pivot_offset = box.size * 0.5
	box.scale = Vector2(0.6, 0.6)
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(box, "scale", Vector2(1.1, 1.1), 0.16).set_ease(Tween.EASE_OUT)
	tw.tween_property(box, "global_position:y", box.global_position.y - 52.0, 0.9)
	tw.chain().tween_property(box, "modulate:a", 0.0, 0.32)
	tw.chain().tween_callback(box.queue_free)

## Осколки: разлетаются от клетки. Взрыв мины без них читался как простое
## исчезновение куба.
func _shards(idx: int, col: Color, count: int = 10) -> void:
	await get_tree().process_frame
	var from := _cell_center(idx)
	for i in count:
		var p := ColorRect.new()
		var s := rng.randf_range(5.0, 11.0)
		p.color = col
		p.custom_minimum_size = Vector2(s, s)
		p.size = Vector2(s, s)
		p.mouse_filter = Control.MOUSE_FILTER_IGNORE
		p.z_index = 124
		add_child(p)
		p.global_position = from
		var dir := Vector2(rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, -0.2)).normalized()
		var dist := rng.randf_range(60.0, 130.0)
		var tw := create_tween().set_parallel(true)
		tw.tween_property(p, "global_position", from + dir * dist + Vector2(0, 40), 0.6)
		tw.tween_property(p, "modulate:a", 0.0, 0.6)
		tw.tween_property(p, "rotation", rng.randf_range(-3.0, 3.0), 0.6)
		tw.chain().tween_callback(p.queue_free)

## Разбор жетонов хода: у каждой способности свой знак на доске. Определяем по
## значку жетона — он уже приходит из логики и однозначен.
func _play_effects(res: Dictionary) -> void:
	await get_tree().process_frame
	var cell := int(res["cell"])
	for p in res["parts"]:
		var icon := String(p.get("icon", ""))
		match icon:
			"🦔":
				# укол шипами: красное кольцо, тряска и крупный минус
				buzz(90)
				_ring(cell, Palette.DANGER, 2.6, 0.5)
				_shake(8.0, 0.3)
				_float_text(cell, "−%d" % int(p["v"]), Palette.NEG, 30)
			"🔮":
				# превращение колдуна: волна и новое значение
				buzz(40)
				_ring(cell, Palette.CYAN, 2.2, 0.5)
				_float_text(cell, "🔮 %d" % int(p["v"]), Palette.CYAN, 26)
			"🦷":
				# челюсть доедает соседа справа: знак над съеденной клеткой
				buzz(60)
				var eaten: int = cell + 1
				_ring(eaten, Palette.GOLD_LIGHT, 2.0, 0.4)
				_shards(eaten, Palette.BLOOD_HI, 8)
				_float_text(eaten, "🦷 +%d" % int(p["v"]), Palette.GOLD_LIGHT, 26)
				_shake(5.0, 0.2)
			"🤝":
				_ring(cell, Palette.GOLD, 1.8, 0.4)
				_float_text(cell, "🤝 +%d" % int(p["v"]), Palette.GOLD_LIGHT, 24)

## Выкрик комбинации по центру поля: «ПАРА +5», «КАРЕ +40». Чем крупнее комбо,
## тем крупнее буквы — пара не должна выглядеть как шестёрка.
func _combo_call(name_of_combo: String, bonus: int) -> void:
	if name_of_combo == "":
		return
	# баннер раунда живёт по центру экрана и мог столкнуться с выкриком в первом
	# же ходу; раунд к этому моменту всё равно начался
	_hide_banner()
	await get_tree().process_frame
	var size_px := 22
	if bonus >= 100:
		size_px = 40
	elif bonus >= 60:
		size_px = 36
	elif bonus >= 40:
		size_px = 32
	elif bonus >= 25:
		size_px = 28
	elif bonus >= 10:
		size_px = 25
	var text := "%s +%d" % [name_of_combo.replace("!", ""), bonus]
	var box := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.02, 0.07, 0.86)
	sb.set_corner_radius_all(12)
	sb.border_color = Color(Palette.GOLD.r, Palette.GOLD.g, Palette.GOLD.b, 0.75)
	sb.set_border_width_all(2)
	sb.content_margin_left = 16
	sb.content_margin_right = 16
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	box.add_theme_stylebox_override("panel", sb)
	box.z_index = 126
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var l := _label(text, size_px, Palette.GOLD_LIGHT, Palette.FONT_TITLE)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(l)
	add_child(box)
	await get_tree().process_frame
	await get_tree().process_frame
	# по центру самого поля, а не экрана: комбинация про кубы на доске
	var board_mid: Vector2 = board_grid.global_position + board_grid.size * 0.5
	box.global_position = board_mid - box.size * 0.5
	box.pivot_offset = box.size * 0.5
	box.scale = Vector2(0.5, 0.5)
	box.modulate.a = 0.0
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(box, "scale", Vector2(1.12, 1.12), 0.18).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
	tw.tween_property(box, "modulate:a", 1.0, 0.14)
	tw.chain().tween_property(box, "scale", Vector2.ONE, 0.1)
	tw.chain().tween_interval(0.5)
	tw.chain().tween_property(box, "global_position:y", box.global_position.y - 34.0, 0.4)
	tw.parallel().tween_property(box, "modulate:a", 0.0, 0.4)
	tw.chain().tween_callback(box.queue_free)

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
	# число крупное и с замахом: сперва подскакивает над клеткой, потом летит в
	# свой жетон. Мелкая цифра, тихо уезжавшая вниз, читалась как случайный мусор.
	var fly := _label("%s%d" % ["−" if neg else "+", int(part["v"])], 24, col, Palette.FONT_UI)
	fly.z_index = 100
	fly.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(fly)
	await get_tree().process_frame
	fly.global_position = src - fly.size * 0.5
	fly.pivot_offset = fly.size * 0.5
	fly.scale = Vector2(0.5, 0.5)
	var dst: Vector2 = chip.global_position + chip.size * 0.5 - fly.size * 0.5
	var jump := fly.global_position + Vector2(0, -26)
	var up := create_tween().set_parallel(true)
	up.tween_property(fly, "scale", Vector2(1.25, 1.25), 0.16).set_ease(Tween.EASE_OUT)
	up.tween_property(fly, "global_position", jump, 0.16).set_ease(Tween.EASE_OUT)
	await up.finished
	var tw := create_tween().set_parallel(true)
	tw.tween_property(fly, "global_position", dst, 0.34).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_CUBIC)
	tw.tween_property(fly, "scale", Vector2(0.65, 0.65), 0.34)
	tw.tween_property(fly, "modulate:a", 0.2, 0.34)
	await tw.finished
	fly.queue_free()
	# удар по жетону: он вспыхивает от прилетевшего числа
	chip.pivot_offset = chip.size * 0.5
	var hit := create_tween()
	hit.tween_property(chip, "scale", Vector2(1.18, 1.18), 0.08).set_ease(Tween.EASE_OUT)
	hit.tween_property(chip, "scale", Vector2.ONE, 0.12)

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
			_show_rules()
		"lobby":
			_show_lobby()
		"durak":
			# кон в разгаре: на столе отбитая пара и неотбитая атака
			opponent = "bot"
			_start_durak()
			d_state["trump"] = 2
			d_state["attacker"] = "e"
			d_state["phase"] = "defend"
			d_state["max_att"] = 4
			d_state["table"] = [
				{"a": {"value": 4, "suit": 1}, "d": {"value": 6, "suit": 1}},
				{"a": {"value": 4, "suit": 3}, "d": null},
			]
			Durak.hand_of(d_state, "p").assign([
				{"value": 5, "suit": 3}, {"value": 2, "suit": 2},
				{"value": 1, "suit": 0}, {"value": 6, "suit": 0},
			])
			d_state["shown_to"] = "p"
			d_frozen = []
			busy = false
			_d_refresh()
			await get_tree().process_frame
		"durak_veil":
			opponent = "human"
			_start_durak()
			d_state["shown_to"] = "e"
			_show_veil("p")
			await get_tree().process_frame
		"durak_rules":
			opponent = "bot"
			_start_durak()
			in_durak = true
			_show_rules()
			await get_tree().process_frame
		"big":
			# большая доска и карточка с четырьмя жетонами: проверяем, что рука
			# осталась на экране, а не уехала под нижний край
			opponent = "bot"
			_start_mode("big")
			state["board"][0] = {"v": 2, "type": "basic", "owner": "e", "shield": 0}
			state["board"][1] = {"v": 3, "type": "basic", "owner": "e", "shield": 0}
			state["board"][3] = {"v": 4, "type": "basic", "owner": "p", "shield": 0}
			state["board"][4] = {"v": 4, "type": "basic", "owner": "p", "shield": 0}
			state["players"]["p"]["hand"][0] = {"value": 4, "type": "jaw"}
			state["shown_to"] = "p"
			_refresh()
			var res_big := MatchState.play(state, "p", 0, 0)
			_refresh()
			await _play_card(res_big)
		"name_ask":
			# первый запуск: спрашиваем имя, отменить нельзя
			_show_name_screen(true)
			await get_tree().process_frame
		"modes":
			# второй шаг меню: выбор режима после выбора вида игры
			_show_modes()
			await get_tree().process_frame
		"combo":
			opponent = "bot"
			_start_mode("classic")
			state["board"][3] = {"v": 4, "type": "basic", "owner": "p", "shield": 0}
			state["board"][4] = {"v": 4, "type": "basic", "owner": "p", "shield": 0}
			state["players"]["p"]["hand"][0] = {"value": 4, "type": "basic"}
			state["shown_to"] = "p"
			_refresh()
			var res_cmb := MatchState.play(state, "p", 0, 1)
			_refresh()
			_combo_call(String(res_cmb["combo"]["name"]), int(res_cmb["combo"]["bonus"]))
			await get_tree().create_timer(0.45).timeout
		"shake":
			# три толчка подряд, как при взрыве вместе с итогом хода: экран обязан
			# вернуться ровно на место, иначе им нельзя управлять
			opponent = "bot"
			_start_mode("classic")
			_shake(12.0, 0.45)
			_shake(7.0, 0.3)
			await get_tree().create_timer(0.15).timeout
			_shake(4.0, 0.2)
			await get_tree().create_timer(1.2).timeout
			print("смещение холста после тряски: ", get_viewport().canvas_transform.origin)
		"fx":
			# челюсть жуёт куб с шипами: за один ход и укол, и «пережевал» — видно
			# сразу оба новых знака на доске
			opponent = "bot"
			_start_mode("classic")
			state["board"][1] = {"v": 3, "type": "spikes", "owner": "e", "shield": 0}
			state["board"][3] = {"v": 5, "type": "basic", "owner": "p", "shield": 0}
			state["board"][4] = {"v": 5, "type": "basic", "owner": "p", "shield": 0}
			state["players"]["p"]["hand"][0] = {"value": 5, "type": "jaw"}
			state["shown_to"] = "p"
			_refresh()
			var res_fx := MatchState.play(state, "p", 0, 0)
			_refresh()
			_animate_place(int(res_fx["placed"]))
			_play_effects(res_fx)
			await get_tree().create_timer(0.35).timeout
		"shield":
			# щиты крупно и мелко: обводка обязана идти по краю всего куба, включая
			# нижнюю фаску, иначе она читается как «рамка не по размеру»
			opponent = "bot"
			_start_mode("classic")
			state["board"][0] = {"v": 6, "type": "shield", "owner": "e", "shield": 2}
			state["board"][1] = {"v": 4, "type": "shield", "owner": "p", "shield": 1}
			state["board"][4] = {"v": 3, "type": "basic", "owner": "p", "shield": 0}
			state["players"]["p"]["hand"][0] = {"value": 5, "type": "shield"}
			state["shown_to"] = "p"
			busy = false
			_refresh()
			await get_tree().process_frame
		"net_client":
			# глазами не-хоста: его кубы второго сиденья должны быть красными и в
			# руке, и на доске
			opponent = "remote"
			my_seat = "e"
			_start_mode("classic")
			state["board"][0] = {"v": 5, "type": "basic", "owner": "e", "shield": 0}
			state["board"][4] = {"v": 3, "type": "basic", "owner": "p", "shield": 0}
			state["turn"] = "e"
			selected = 0
			_refresh()
			await get_tree().process_frame
		"net_rematch":
			# клиент на оверлее поражения получает объявление новой партии от
			# хоста: оверлей обязан погаснуть — на кадре свежая доска раунда 1,
			# а не «Ждём хоста…» поверх уже идущей игры
			opponent = "remote"
			my_seat = "e"
			_start_mode("classic")
			busy = true
			_show_result("ПОРАЖЕНИЕ", "Ты остался без жизней.", "Ещё раз", func(): pass)
			_on_lan_match_started("classic", 999)
			print("оверлей исхода после рестарта: ", over_layer.visible)
			await get_tree().process_frame
		"net_round":
			# исход раунда по сети: раньше выходило «Ты теряет ♥»
			opponent = "remote"
			my_seat = "p"
			_start_mode("classic")
			state["players"]["p"]["score"] = 12
			state["players"]["e"]["score"] = 34
			for seat2 in state["order"]:
				state["players"][seat2]["moves"] = int(state["cfg"]["moves"])
			_after_move()
			await get_tree().process_frame
		"durak_take":
			# рука после «Взять»: много кубов, два ряда, крупное уведомление
			opponent = "bot"
			_start_durak(4242)
			var big_hand := []
			for s in 4:
				for v in [1, 3, 5]:
					big_hand.append({"value": v, "suit": s})
			Durak.hand_of(d_state, "p").assign(big_hand)
			d_state["trump"] = 1
			d_state["shown_to"] = "p"
			d_notice = "ЗАБИРАЕШЬ СТОЛ · +4 куба в руку"
			busy = false
			_d_refresh()
			await get_tree().process_frame
		"durak_lose":
			opponent = "bot"
			_start_durak(1)
			d_state["over"] = true
			d_state["phase"] = "over"
			d_state["outcome"] = {"loser": "p", "detail": "Остался с кубами"}
			await _d_finish()
			await get_tree().process_frame
		"durak_net":
			# сетевая партия: за вторым сиденьем чужое устройство, ждём его действия
			opponent = "remote"
			my_seat = "p"
			_start_durak(777)
			d_state["attacker"] = "e"
			d_state["phase"] = "attack"
			await _durak_next(0.2)
			await get_tree().process_frame
		"durak_bot":
			# бот атакует, роль уходит игроку: проверяем, что цепочка не залипает
			opponent = "bot"
			_start_durak()
			d_state["attacker"] = "e"
			d_state["phase"] = "attack"
			d_state["max_att"] = 6
			d_state["shown_to"] = "p"
			await _durak_next(0.2)
			await get_tree().process_frame
		"round", "win", "hotseat_round":
			# доигрываем раунд до исхода, чтобы на кадр попали сами фразы
			opponent = "human" if _shot_mode == "hotseat_round" else "bot"
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
			opponent = "human"
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
	# фон грузится в фоновом потоке — на снимке он должен успеть появиться,
	# иначе кадр врёт про оформление
	var waited := 0
	while _wall_rect != null and waited < 60:
		waited += 1
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
	# 44 и 40: пальцем в 32 px попадать неудобно, а промах по «Меню» уводит из партии
	b.custom_minimum_size.y = 44 if not ghost else 40
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
	sb.content_margin_left = 12
	sb.content_margin_right = 12      # без него подпись упиралась в рамку буква в букву
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	return sb

func _cell_box(valid: bool, has_die: bool, hinted: bool = false) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Palette.CELL
	sb.set_corner_radius_all(12)
	# тонкая рамка у свободной клетки и толстая у подсвеченной: раньше все клетки
	# были обведены одинаково жирно и доска читалась как сетка, а не как поле
	sb.set_border_width_all(2)
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
