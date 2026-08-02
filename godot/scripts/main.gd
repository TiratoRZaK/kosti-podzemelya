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
var foe_left := false          # соперник вышел сам — гасит «СВЯЗЬ ПОТЕРЯНА» вдогонку
var reconnecting := false      # идёт цикл возврата в партию
var _announced_out := {}       # о ком уже объявили «выбывает»
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

var foes_box: VBoxContainer
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
var draft_layer: Control
var draft_grid: GridContainer
var draft_note: Label
var draft_go: Button
var draft_offer: Array = []
var draft_picked: Array = []
var draft_mode := "draft"
var draft_seed := 0
var roster_layer: Control
var roster_box: VBoxContainer
var roster_kinds: Array = []   # типы мест со второго: bot | human | off
var roster_scope := "solo"     # solo (только боты) | local (люди рядом и боты)
var modes_from := "kinds"      # куда вернёт «Назад» с экрана режимов
var roster_for_run: Array = [] # состав, с которым запущена текущая партия
var duel_layer: Control
var duel_row: HBoxContainer
var duel_note: Label
var duel_hand: Control          # площадка, откуда игрок бросает свой куб
var duel_input: Control         # прозрачный слой поверх битвы: ловит свайп
var event_layer: Control        # экран предложения между раундами
var event_box: VBoxContainer
var event_done := false
var duel_hint: Label
var duel_throw_from := Vector2.ZERO   # откуда полетел куб после свайпа
# состояние броска свайпом: только поля, лямбды копируют локальные переменные
var _throw_die_node: DieView
var _throw_idle: Tween
var _throw_dragging := false
var _throw_done := false
var _throw_speed := Vector2.ZERO
var _throw_last_at := Vector2.ZERO
var _throw_last_ms := 0

func _ready() -> void:
	_parse_args()
	rng.seed = 20260731
	_boot_ms = Time.get_ticks_msec()      # столько прошло от инициализации движка
	_build_ui()
	_apply_safe_area()
	get_viewport().size_changed.connect(_apply_safe_area)
	# после первой раскладки пересчитываем доску: до неё узлы не знают своих
	# размеров, и клетка вышла бы по запасному значению
	_relayout_soon()
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

## Системная кнопка «Назад» на Android.
##
## По умолчанию Godot на неё просто закрывает приложение (`quit_on_go_back`), а
## на Magic UI это ещё и свайп от бокового края — случайное движение выбрасывало
## из партии, а по Wi-Fi рвало игру и соперникам. Теперь кнопка закрывает верхний
## слой, из партии ведёт в меню, и только из меню верхнего уровня выходит из игры.
func _notification(what: int) -> void:
	if what != NOTIFICATION_WM_GO_BACK_REQUEST:
		return
	if rules_layer != null and rules_layer.visible:
		rules_layer.visible = false
	elif over_layer != null and over_layer.visible:
		over_layer.visible = false
		_show_menu()
	elif draft_layer != null and draft_layer.visible:
		draft_layer.visible = false
		_show_menu()
	elif roster_layer != null and roster_layer.visible:
		roster_layer.visible = false
		_show_menu()
	elif lobby_layer != null and lobby_layer.visible:
		lobby_layer.visible = false
		_show_menu()
	elif duel_layer != null and duel_layer.visible:
		pass                      # битва идёт секунды, прерывать её нечем
	elif menu_layer != null and menu_layer.visible:
		if modes_box != null and modes_box.visible:
			_modes_back()         # с режимов — назад по шагам, а не из игры
		else:
			get_tree().quit()
	else:
		_show_menu()              # из партии — в меню, партия не теряется

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

## Перерисовать через два кадра, когда контейнеры уже знают свои размеры.
func _relayout_soon() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	_refresh_screen()
	_fit_battle()
	await get_tree().process_frame
	# второй проход: после перерисовки у панелей другие минимумы (жетоны карточки,
	# число соперников), и коэффициент, посчитанный до неё, уже не тот
	_fit_battle()

## Вписать игровой экран в телефон.
##
## Замечание с живого устройства было прямым: «в эмуляторе всё умещается, а на
## телефонах вылезает за нижнюю границу». Причина в том, что VBoxContainer не
## умеет сжимать детей ниже их минимальной высоты — если сумма минимумов больше
## экрана, он просто рисует хвост за краем, и кнопки «Правила» и «Меню» уходят
## под жестовую полосу. Считать «сколько занимает всё кроме доски» и вычитать
## это из высоты недостаточно: минимум самой руки, карточки и шапки тоже может
## не поместиться.
##
## Поэтому здесь два рубежа. Сперва честное сжатие — карточка хода и рука на
## низком экране становятся ниже (`_apply_safe_area`). Если и этого мало,
## колонка получает размер БОЛЬШЕ окна и масштаб меньше единицы: содержимое
## уменьшается целиком, ничего не обрезая. Масштаб ниже 0.7 не опускаем — там
## уже нечитаемо, лучше остаток прокрутить.
func _fit_battle() -> void:
	for pair in [[battle_fit, battle_col], [durak_fit, durak_col]]:
		var holder: Control = pair[0]
		var col: Control = pair[1]
		if holder == null or col == null:
			continue
		var avail := holder.size
		if avail.x <= 1.0 or avail.y <= 1.0:
			continue
		if not is_equal_approx(col.scale.x, 1.0):
			# меряем всегда в натуральную величину, иначе прошлый масштаб копится
			col.scale = Vector2.ONE
			col.size = avail
		var need: float = col.get_combined_minimum_size().y
		var k := 1.0
		if need > avail.y and need > 1.0:
			k = clampf(avail.y / need, 0.7, 1.0)
		# мелкую разницу пропускаем: у надписей с переносом высота зависит от
		# ширины, и погоня за точным коэффициентом заставила бы экран дышать
		var want := avail / k
		if absf(k - col.scale.x) < 0.02 and col.size.distance_to(want) < 1.0:
			continue
		if absf(k - col.scale.x) < 0.02:
			k = col.scale.x
			want = avail / k
		col.scale = Vector2(k, k)
		col.position = Vector2.ZERO
		col.size = want

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
		# 26 не хватало: на Honor с Magic UI полоса навигации в логических единицах
		# выходит около 48, и кнопки под ней оказывались наполовину
		b = maxf(b, 34.0)
		t = maxf(t, 18.0)
	_safe = Vector4(l, t, r, b)
	# на невысоких экранах ужимаем карточку хода и руку, иначе низ не влезает
	var avail := vp.y - t - b
	var compact: bool = avail < 800.0
	hand_px = 62 if compact else HAND_PX
	if hand_row != null:
		hand_row.custom_minimum_size.y = hand_px
	if hist_strip != null:
		hist_strip.custom_minimum_size.y = _touch(40.0)
	if card_scroll != null:
		# Резервы держим скупее, чем раньше: всё, что забрано впустую, потом
		# отбирает `_fit_battle` масштабом у всего экрана разом — а он уменьшает и
		# кнопки, и таблетки ленты ниже 40 px, за которые велась отдельная борьба.
		# два ряда жетонов плюс заголовок — 122; при 96 нижний ряд срезался ровно
		# посередине, и видимая сумма не сходилась с итогом хода
		card_scroll.custom_minimum_size.y = 96 if compact else 122
	_fit_battle()
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
		elif a == "--shot-draft":
			_shot_mode = "draft"
		elif a == "--shot-roster":
			_shot_mode = "roster"
		elif a == "--shot-duel":
			_shot_mode = "duel"
		elif a == "--shot-duel-open":
			_shot_mode = "duel_open"
		elif a == "--shot-duel-hand":
			_shot_mode = "duel_hand"
		elif a == "--shot-duel-swipe":
			_shot_mode = "duel_swipe"
		elif a == "--shot-event":
			_shot_mode = "event"
		elif a == "--shot-event-buy":
			_shot_mode = "event_buy"
		elif a == "--shot-three":
			_shot_mode = "three"
		elif a == "--shot-durak3":
			_shot_mode = "durak3"
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
	# Между отступами и столбцом стоит пустая обёртка: столбец лежит в ней не как
	# в контейнере, а с размером и масштабом, которые ставит `_fit_battle`. Иначе
	# вписать содержимое в низкий экран нечем — VBoxContainer не сжимает детей
	# ниже их минимума, он просто вылезает за нижний край.
	battle_fit = Control.new()
	battle_fit.clip_contents = false
	battle_fit.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pad.add_child(battle_fit)
	battle_fit.resized.connect(_fit_battle)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 8)
	battle_fit.add_child(root)
	battle_col = root

	root.add_child(_title_block())
	root.add_child(_foe_zone())
	toast_label = _label("", 12, Palette.GOLD_LIGHT)
	toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toast_label.custom_minimum_size.y = 16
	root.add_child(toast_label)
	root.add_child(_turn_bar())
	board_grid = GridContainer.new()
	board_grid.columns = 3
	board_grid.add_theme_constant_override("h_separation", CELL_GAP)
	board_grid.add_theme_constant_override("v_separation", CELL_GAP)
	# по центру: на 3×3 клетка мельче ширины экрана, и доска прижималась влево
	var board_wrap := CenterContainer.new()
	board_wrap.add_child(board_grid)
	board_wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(board_wrap)
	board_holder = board_wrap
	sel_info = _label("", 12, Palette.MUTED)
	sel_info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sel_info.custom_minimum_size.y = 22
	sel_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(sel_info)
	# лента ходов: таблетки с номером и итогом, тап раскрывает нужную карточку
	hist_strip = HBoxContainer.new()
	hist_strip.add_theme_constant_override("separation", 6)
	hist_strip.custom_minimum_size.y = 40   # пересчитывается в _apply_safe_area
	var strip_scroll := ScrollContainer.new()
	strip_scroll.custom_minimum_size.y = 40
	strip_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	strip_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	strip_scroll.add_child(hist_strip)
	_hide_scrollbar(strip_scroll)
	root.add_child(strip_scroll)
	# Место под карточку хода держим всегда, иначе доска и рука прыгают. И держим
	# его ЖЁСТКО: на большой доске жетонов бывает три ряда, карточка вырастала и
	# выдавливала руку за нижний край экрана. Теперь лишнее прокручивается внутри
	# карточки, а рука остаётся на месте.
	card_box = VBoxContainer.new()
	card_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card_scroll = ScrollContainer.new()
	card_scroll.custom_minimum_size.y = 122
	card_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	card_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	card_scroll.add_child(card_box)
	_hide_scrollbar(card_scroll)
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
	# без переноса панель уезжала за правый край уже на двух именах, а на четырёх
	# теряла половину строки
	banner_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	banner_label.custom_minimum_size.x = 210
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
	# Баннер центрируется по экрану, а доска занимает верхние две трети — «РАУНД 2»
	# ложился ровно на её нижний ряд и полторы секунды прятал кубы. Поднимаем.
	bcenter.offset_bottom = -180
	bcenter.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bcenter.z_index = 119
	bcenter.add_child(bpanel)
	add_child(bcenter)
	bpanel.modulate.a = 0.0

## Имя игрока. У выбывшего перечёркнуто — обычный Label так не умеет, поэтому
## для него берём RichTextLabel с `[s]`.
func _name_label(text: String, col: Color, dead: bool) -> Control:
	if not dead:
		return _label(text, 12, col)
	var rt := RichTextLabel.new()
	rt.bbcode_enabled = true
	rt.fit_content = true
	rt.scroll_active = false
	rt.autowrap_mode = TextServer.AUTOWRAP_OFF
	rt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rt.add_theme_font_size_override("normal_font_size", 12)
	rt.text = "[s][color=#%s]%s[/color][/s]" % [col.to_html(false), text]
	return rt

## Спрятать ручку прокрутки, оставив саму прокрутку.
##
## Серая полоса под лентой ходов и в карточке занимала место и выглядела как
## деталь не отсюда. Просто спрятать узел мало — ScrollContainer возвращает его
## видимость при пересчёте, поэтому гасим оформление (пустые стили) и обнуляем
## минимальный размер: полоса остаётся, но не рисуется и не ест высоту.
func _hide_scrollbar(sc: ScrollContainer) -> void:
	for bar in [sc.get_h_scroll_bar(), sc.get_v_scroll_bar()]:
		if bar == null:
			continue
		var empty := StyleBoxEmpty.new()
		for part in ["scroll", "scroll_focus", "grabber", "grabber_highlight", "grabber_pressed"]:
			bar.add_theme_stylebox_override(part, empty)
		bar.custom_minimum_size = Vector2.ZERO
		bar.modulate.a = 0.0

func _title_block() -> Control:
	var box := VBoxContainer.new()
	var t := _label("КОСТИ ПОДЗЕМЕЛЬЯ", 25, Palette.GOLD, Palette.FONT_TITLE)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(t)
	mode_tag = _label("", 10, Palette.MUTED)
	mode_tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(mode_tag)
	return box

## Зона соперников. Раньше сверху была одна панель на одного противника; теперь
## это список: по строке на каждого, чтобы в игру влезали трое и четверо. При двух
## игроках выглядит почти как прежде.
func _foe_zone() -> Control:
	var panel := _panel()
	foes_box = VBoxContainer.new()
	foes_box.add_theme_constant_override("separation", 6)
	panel.add_child(foes_box)
	return panel

## Строка соперника: имя, жизни, счёт, рубашки руки и колода.
func _foe_row(seat: String, compact: bool) -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 3)
	# Строка делится на три равные доли: слева имя, ровно посередине сердца,
	# справа счёт. Раньше это был поток из имени, распорок и счёта — и стоило
	# появиться маркеру хода, как имя удлинялось, а сердца и звёзды уезжали в
	# сторону. Строка дёргалась каждый ход.
	var row := HBoxContainer.new()
	v.add_child(row)
	var left := HBoxContainer.new()
	left.add_theme_constant_override("separation", 2)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(left)
	var dead: bool = MatchState.is_out(state, seat)
	# место под маркер занято всегда, даже когда маркера нет
	var mark := _label("💀" if dead else ("▶" if String(state["turn"]) == seat else " "),
		11, Palette.GOLD_LIGHT)
	mark.custom_minimum_size.x = 14
	left.add_child(mark)
	# имя в цвете лица его кубов: с тремя игроками иначе не понять, кто где.
	# У выбывшего оно перечёркнуто — он в этой партии больше не ходит
	var nm := _name_label(_who_name(state, seat),
		Palette.name_of(int(state["order"].find(seat))), dead)
	left.add_child(nm)
	if dead:
		v.modulate.a = 0.85
	left.add_child(_grow())
	var kind := String(state["cfg"]["kind"])
	var mid := CenterContainer.new()
	mid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(mid)
	if kind == "lives" or kind == "bo3":
		var pips := LifeRow.new()
		if kind == "lives":
			pips.setup(Rules.LIVES_MAX, int(state["players"][seat]["lives"]))
		else:
			pips.setup(2, int(state["players"][seat]["wins"]), LifeRow.KIND_STAR, Palette.GOLD)
		mid.add_child(pips)
	var right := HBoxContainer.new()
	right.alignment = BoxContainer.ALIGNMENT_END
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(right)
	var sc := _label(_score_text(seat, kind, state["cfg"]), 20 if not compact else 16,
		Palette.GOLD_LIGHT, Palette.FONT_UI)
	right.add_child(sc)
	# рубашки руки показываем, только когда соперник один: втроём места нет
	if not compact:
		var row2 := HBoxContainer.new()
		v.add_child(row2)
		var backs := HBoxContainer.new()
		backs.add_theme_constant_override("separation", 6)
		for i in state["players"][seat]["hand"].size():
			var back := Panel.new()
			back.custom_minimum_size = Vector2(22, 22)
			back.add_theme_stylebox_override("panel", _mini_box())
			backs.add_child(back)
		row2.add_child(backs)
		row2.add_child(_grow())
		row2.add_child(_label("Колода: %d" % state["players"][seat]["deck"].size(), 11, Palette.MUTED))
	else:
		right.add_child(_label("  %d в руке" % state["players"][seat]["hand"].size(), 11, Palette.MUTED))
	# чей сейчас ход — видно по маркеру слева; имя цвет не меняет, он значит
	# принадлежность кубов, а не очередь
	return v

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
	durak_fit = Control.new()
	durak_fit.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pad.add_child(durak_fit)
	durak_fit.resized.connect(_fit_battle)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 8)
	durak_fit.add_child(root)
	durak_col = root

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
	durak_table_holder = d_table

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
	# Козырь обводим золотом, но бубновая грань сама золотая (1.12:1 — рамки не
	# видно вовсе, а козырь бубён выпадает в каждой четвёртой партии). На светлых
	# гранях берём тёмную обводку.
	var light_face: bool = face["bg"].get_luminance() > 0.45
	sb.border_color = (Palette.BONE_INK if light_face else Palette.GOLD) if is_trump else face["edge"]
	sb.set_border_width_all(3 if is_trump else 2)
	slot.add_theme_stylebox_override("panel", sb)
	if dim:
		slot.modulate = Color(1, 1, 1, 0.62)
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
	d_my_count.text = "%d %s" % [my_hand.size(), _plural(my_hand.size(), "куб", "куба", "кубов")]
	# соперников может быть двое-трое: имя, сколько кубов и кто сейчас действует
	var foes := []
	for seat in d_state["order"]:
		if String(seat) != me:
			foes.append(String(seat))
	var lines := []
	for seat in foes:
		var n: int = Durak.hand_of(d_state, seat).size()
		var mark := "▶ " if Durak.actor(d_state) == seat else ""
		lines.append("%s%s — %d %s" % [mark, MatchState.seat_name(d_state, String(seat)).to_upper(),
			n, _plural(n, "куб", "куба", "кубов")])
	d_foe_name.text = "
".join(lines)
	d_foe_count.text = "" if foes.size() > 1 else "%d %s" % [foe_hand.size(),
		_plural(foe_hand.size(), "куб", "куба", "кубов")]
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
	for i in (foe_hand.size() if foes.size() == 1 else 0):
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
	# Место высотой в 1.12 ширины, поэтому по высоте делим на коэффициент. Остаток
	# высоты спрашиваем у самих панелей, как на боевом экране: константа со снимка
	# врала на телефонах с другой высотой строк.
	var by_width: float = (390.0 - _safe.x - _safe.z - CELL_GAP * 2) / 3.0
	var by_height := by_width
	if durak_col != null and durak_table_holder != null:
		var sep: float = float(durak_col.get_theme_constant("separation"))
		var need := 0.0
		var n := 0
		for c in durak_col.get_children():
			if c is Control and c.visible:
				n += 1
				if c != durak_table_holder:
					need += (c as Control).get_combined_minimum_size().y
		if n > 1:
			need += sep * float(n - 1)
		var avail: float = get_viewport_rect().size.y - _safe.y - _safe.w - need
		by_height = (avail - CELL_GAP) / 2.0 / 1.12
	var cell_w: float = maxf(minf(by_width, by_height), 52.0)
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
		# защитник, а не сосед по кругу: `other_seat` берёт следующее сиденье как
		# есть, `defender_of` пропускает вышедших. Ту же ошибку уже чинили в
		# `Durak.forced_action`, в интерфейсе она осталась — и втроём в 13% партий,
		# вчетвером в 22% экран вставал намертво: ни одного доступного куба, ни
		# кнопки «Бито», ни принудительного действия
		if Durak.hand_of(d_state, Durak.defender_of(d_state, String(d_state["attacker"]))).is_empty():
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
	# по сети состав задаёт стол, а не то, что осталось от прошлой местной партии
	if opponent == "remote" and (lan == null or lan.table_seats <= 2):
		roster_for_run = []
	var party: Array = roster_for_run if not roster_for_run.is_empty() else []
	if seed_value < 0 and opponent == "roster":
		party = _roster_for_match()
		roster_for_run = party
	if seed_value < 0 and opponent == "remote" and lan != null and lan.is_host:
		if lan.table_seats > 2:
			# стол на троих: раздаём сиденья и рассылаем состав, как в боевых режимах
			var plain := [{"kind": "human", "name": Profile.display_name()}]
			var seat_by_peer := {}
			var ids := MatchState.seat_ids(lan.table_seats)
			var at := 1
			for p in lan.lobby:
				plain.append({"kind": "human", "name": String(p["name"])})
				seat_by_peer[int(p["id"])] = String(ids[at])
				at += 1
			var bots := 0
			while plain.size() < lan.table_seats:
				plain.append({"kind": "bot", "name": MatchState.BOT_NAMES[mini(bots, 3)]})
				bots += 1
			my_seat = "p"
			lan.send_party("durak", sd, plain, seat_by_peer)
			party = []
			for i in plain.size():
				var d: Dictionary = plain[i]
				party.append({"kind": String(d["kind"]), "local": String(ids[i]) == my_seat,
					"name": String(d["name"])})
			roster_for_run = party
		else:
			lan.send_start("durak", sd)
	d_state = Durak.new_game(sd, opponent, my_seat, foe_player, Profile.display_name(), party)
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
		if lan.table_seats > 2 or not lan.is_host:
			lan.send_durak_party(seat, act, idx)
		else:
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
	# «Бито» от подкидывающего — это ещё не конец кона: пока есть кому добавить,
	# слово идёт по кругу, и стол остаётся на месте
	var passed_on: bool = String(res.get("act", "")) == "pass"
	if passed_on:
		d_frozen = []
		d_toast("%s пасует" % MatchState.seat_name(d_state, seat), seat != _d_viewer())
		_d_refresh()
		await get_tree().create_timer(0.4).timeout
		if d_state.is_empty() or not in_durak:
			return
		await _durak_next(0.6)
		return
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
		# первый вышедший, а не сосед по кругу
		var went: Array = d_state.get("went_out", [])
		var winner := String(went[0]) if not went.is_empty() 			else MatchState.other_seat(d_state, loser)
		if _solo(d_state) and loser == mine:
			# та самая фраза, из-за которой в это вообще играют
			title = "ТЫ ДУРАКУБ!"
			text = "Кубы остались у тебя. Позор на все подземелья."
		elif _solo(d_state) and d_state["order"].size() == 2:
			title = "ПОБЕДА!"
			text = "Соперник остался с кубами — дуракуб он."
		else:
			title = MatchState.seat_name(d_state, loser).to_upper() + " — ДУРАКУБ!"
			text = "%s вышел первым, кубы остались у игрока %s." % [
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
	kind_box.add_child(_kind_button("Одиночная", "ты и боты, от одного до трёх", func():
		_open_roster("solo")
	))
	kind_box.add_child(_kind_button("На одном телефоне", "люди по очереди, с ширмой при передаче", func():
		_open_roster("local")
	))
	kind_box.add_child(_kind_button("По Wi-Fi", "с друзьями рядом, в одной сети Wi-Fi", func():
		_show_lobby()
	))
	kind_box.add_child(_kind_button("По сети", "пока недоступно", Callable(), true))
	var rules_btn := _button("Как играть", true)
	rules_btn.pressed.connect(_show_rules)
	kind_box.add_child(rules_btn)
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
	# Назад — ровно на тот экран, откуда пришли. Раньше кнопка всегда звала
	# `_show_kinds` и с экрана состава выкидывала в самое начало.
	back_btn.pressed.connect(_modes_back)
	modes_box.add_child(back_btn)
	return layer

## Возврат с экрана режимов: к составу, если состав выбирали, иначе к видам игры.
func _modes_back() -> void:
	if modes_from == "roster":
		_show_roster()
	else:
		_show_kinds()

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

## Экран состава: кто сидит за столом. Первое сиденье всегда моё, остальные
## переключаются между ботом, человеком рядом и пустым местом. Так собирается
## партия на троих и четверых — механика это умела давно, не хватало только
## способа задать состав.
## В одиночной за столом только боты, на одном телефоне — ещё и люди рядом.
## Набор задаёт вид игры, выбранный на первом экране (`roster_scope`).
const SEAT_KINDS := {
	"solo": ["bot", "off"],
	"local": ["human", "bot", "off"],
}
const SEAT_KIND_NAMES := {"bot": "бот", "human": "человек рядом", "off": "пусто"}

func _build_roster() -> Control:
	var layer := _full_dim(0.96)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(center)
	var panel := _panel(Palette.PANEL_2)
	center.add_child(panel)
	roster_box = VBoxContainer.new()
	roster_box.add_theme_constant_override("separation", 8)
	roster_box.custom_minimum_size.x = 310
	panel.add_child(roster_box)
	return layer

## Вход в состав с первого экрана: вид игры задаёт, кем можно занимать места.
func _open_roster(scope: String) -> void:
	if roster_scope != scope:
		roster_scope = scope
		# состав от прошлого вида игры не переносим: в одиночной людей рядом нет
		roster_kinds = ["bot", "off", "off"] if scope == "solo" else ["human", "off", "off"]
	_show_roster()

func _show_roster() -> void:
	if roster_layer == null:
		roster_layer = _build_roster()
		add_child(roster_layer)
	if roster_kinds.is_empty():
		roster_kinds = ["bot", "off", "off"]     # по умолчанию — один бот
	opponent = "roster"
	menu_layer.visible = false
	roster_layer.visible = true
	_roster_refresh()

func _roster_refresh() -> void:
	for c in roster_box.get_children():
		c.queue_free()
	var t := _label("КТО ИГРАЕТ", 20, Palette.GOLD, Palette.FONT_TITLE)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	roster_box.add_child(t)
	var count := 1
	for k in roster_kinds:
		if String(k) != "off":
			count += 1
	var hint := _label("За столом %d — нажми на место, чтобы поменять" % count, 12, Palette.MUTED)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size.x = 300
	roster_box.add_child(hint)

	roster_box.add_child(_roster_row(0, "%s — это ты" % Profile.display_name(), ""))
	for i in roster_kinds.size():
		var kind := String(roster_kinds[i])
		roster_box.add_child(_roster_row(i + 1, "Место %d" % (i + 2), kind))

	var go := _button("Дальше")
	go.disabled = count < 2
	go.modulate = Color(1, 1, 1, 1.0 if count >= 2 else 0.5)
	go.pressed.connect(func():
		roster_layer.visible = false
		modes_from = "roster"
		_show_modes()
		menu_layer.visible = true
	)
	roster_box.add_child(go)
	var back := _button("Назад", true)
	back.pressed.connect(func():
		roster_layer.visible = false
		_show_menu()
	)
	roster_box.add_child(back)

## Строка состава: нажатие перебирает бот → человек рядом → пусто.
func _roster_row(idx: int, title: String, kind: String) -> Control:
	var box := PanelContainer.new()
	box.add_theme_stylebox_override("panel", _mode_box())
	box.custom_minimum_size.x = 290
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(row)
	row.add_child(_label(title, 13, Palette.GOLD_LIGHT if kind != "off" or idx == 0 else Palette.MUTED))
	row.add_child(_grow())
	if idx > 0:
		row.add_child(_label(String(SEAT_KIND_NAMES.get(kind, kind)), 12, Palette.TEXT))
		box.mouse_filter = Control.MOUSE_FILTER_STOP
		box.gui_input.connect(func(e: InputEvent):
			if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
				var ring: Array = SEAT_KINDS.get(roster_scope, SEAT_KINDS["local"])
				var at := ring.find(kind)
				roster_kinds[idx - 1] = String(ring[(at + 1) % ring.size()])
				# пустое место не может стоять перед занятым: сдвигаем хвост
				_roster_compact()
				buzz(15)
				_roster_refresh()
		)
	else:
		row.add_child(_label("человек", 12, Palette.TEXT))
	return box

## Занятые места идут подряд: «пусто» уезжает в конец, иначе состав получается с
## дырой и сиденья в партии перестают соответствовать строкам экрана.
func _roster_compact() -> void:
	var busy_kinds := []
	for k in roster_kinds:
		if String(k) != "off":
			busy_kinds.append(String(k))
	while busy_kinds.size() < roster_kinds.size():
		busy_kinds.append("off")
	roster_kinds = busy_kinds

## Состав для MatchState: описания сидений по порядку.
func _roster_for_match() -> Array:
	var out := [{"kind": "human", "local": true, "name": Profile.display_name()}]
	var bots := 0
	var humans := 0
	for k in roster_kinds:
		var kind := String(k)
		if kind == "off":
			continue
		if kind == "bot":
			out.append({"kind": "bot", "local": false,
				"name": MatchState.BOT_NAMES[mini(bots, MatchState.BOT_NAMES.size() - 1)]})
			bots += 1
		else:
			humans += 1
			out.append({"kind": "human", "local": true,
				"name": "Игрок %d" % (humans + 1)})
	return out

## Битва за первый ход.
##
## Все бросают по кубу и накрывают стаканчиком, потом идёт отсчёт и стаканчики
## поднимаются разом: у кого больше — тот и начинает. При ничьей переброс.
##
## Броски приходят из логики (`MatchState.roll_duel`) и считаются от сида матча,
## поэтому по сети у всех устройств выпадает одно и то же — обмениваться
## результатами не нужно, а партия остаётся воспроизводимой.
func _build_duel() -> Control:
	var layer := _full_dim(0.97)
	var v := VBoxContainer.new()
	v.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_theme_constant_override("separation", 16)
	layer.add_child(v)
	var t := _label("БИТВА ЗА ПЕРВЫЙ ХОД", 22, Palette.GOLD, Palette.FONT_TITLE)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(t)
	duel_note = _label("Бросайте кубы", 13, Palette.MUTED)
	duel_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(duel_note)
	duel_row = HBoxContainer.new()
	duel_row.alignment = BoxContainer.ALIGNMENT_CENTER
	duel_row.add_theme_constant_override("separation", 18)
	v.add_child(duel_row)
	# Стаканчики и отсчёт «три-два-один» убраны по просьбе владельца: бросил —
	# сразу видишь, что выпало. Метка отсчёта тоже убрана — пустая, она держала
	# 46 px плюс два отступа и разводила гнёзда с кубом в руке на 107 px.
	# Место, откуда игрок бросает свой куб. Держим его отдельным узлом внизу: куб
	# на время броска уходит из ряда и летит поверх всего слоя.
	duel_hand = Control.new()
	duel_hand.custom_minimum_size.y = 110
	duel_hand.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(duel_hand)
	duel_hint = _label("", 12, Palette.GOLD_LIGHT)
	duel_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(duel_hint)
	# Ввод битвы ловит отдельный прозрачный слой поверх всего.
	#
	# Вешать его на сам куб нельзя, и это была ровно та причина, по которой «свайп
	# нихуя не работал»: палец за первые же миллисекунды уходит с куба 64×64, а
	# события ниже по дереву к нему больше не приходят. Плюс на телефоне идут
	# InputEventScreenTouch/Drag, а не мышиные, — их надо разбирать отдельно.
	duel_input = Control.new()
	duel_input.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	duel_input.mouse_filter = Control.MOUSE_FILTER_STOP
	layer.add_child(duel_input)
	return layer

func _start_duel(after: Callable) -> void:
	if duel_layer == null:
		duel_layer = _build_duel()
		add_child(duel_layer)
	# Повторный вход недопустим: состояние броска лежит в полях, вторая копия
	# затрёт первой куб и дважды подпишется на ввод.
	if duel_layer.visible:
		return
	var res := MatchState.roll_duel(state)
	# снимкам боевых экранов битва не нужна: она длится несколько секунд и все
	# кадры уходили бы в неё. Для самой битвы есть отдельные сценарии.
	if _shot_path != "" and not _shot_mode.begins_with("duel"):
		MatchState.apply_duel(state, String(res["winner"]))
		_refresh()
		if after.is_valid():
			after.call()
		return
	duel_layer.visible = true
	# Битва — самый длинный await боевого потока: свайпа можно ждать до восьми
	# секунд. За это время партия могла смениться (обрыв связи, возврат в меню,
	# присланная заново партия), и `apply_duel` затёрла бы уже другое состояние —
	# вместе с журналом ходов, по которому её восстанавливают.
	var tok := flow_token
	await _play_duel(res)
	if tok != flow_token or state.is_empty():
		duel_layer.visible = false
		return
	MatchState.apply_duel(state, String(res["winner"]))
	duel_layer.visible = false
	_refresh()
	if after.is_valid():
		after.call()

## Показ битвы: раунд за раундом, пока не определится победитель.
func _play_duel(res: Dictionary) -> void:
	var rounds: Array = res["rounds"]
	for i in rounds.size():
		var rolls: Dictionary = rounds[i]
		duel_note.text = "Бросайте кубы" if i == 0 else "НИЧЬЯ — БРОСАЮТ ЗАНОВО!"
		if i > 0:
			buzz(80)
			_shake(6.0, 0.25)
		await _duel_round(rolls, i == rounds.size() - 1, String(res["winner"]))

func _duel_round(rolls: Dictionary, last: bool, winner: String) -> void:
	for c in duel_row.get_children():
		c.queue_free()
	for c in duel_hand.get_children():
		c.queue_free()
	await get_tree().process_frame
	var dice := []
	var slots := []
	var me := viewer()
	# только те, кто бросает в этом заходе: при перебросе проигравшие уходят
	var seats: Array = rolls.keys()
	seats.sort_custom(func(a, b): return state["order"].find(a) < state["order"].find(b))
	for seat in seats:
		var col := VBoxContainer.new()
		col.add_theme_constant_override("separation", 6)
		duel_row.add_child(col)
		# имя и площадка в цвете кубов игрока: за столом на четверых иначе не
		# разобрать, где чей стаканчик
		var seat_no := int(state["order"].find(String(seat)))
		var face: Dictionary = Palette.face_of(seat_no)
		var nm := _label(_who_name(state, String(seat)), 11, Palette.name_of(seat_no))
		nm.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		col.add_child(nm)
		# куб и стаканчик лежат в одной ячейке: стакан просто выше по слою
		var slot := Control.new()
		slot.custom_minimum_size = Vector2(84, 96)
		col.add_child(slot)
		slots.append(slot)
		# площадка под куб: без неё до броска на месте игрока пустота и непонятно,
		# куда он полетит
		var pad_rect := Panel.new()
		var pad_sb := StyleBoxFlat.new()
		pad_sb.bg_color = Color(0, 0, 0, 0.28)
		pad_sb.set_corner_radius_all(12)
		# рамка гнезда — по цвету имени: грань куба на тёмном слое давала 1.49:1,
		# и гнездо просто не читалось
		pad_sb.border_color = Color(Palette.name_of(seat_no), 0.7)
		pad_sb.set_border_width_all(2)
		pad_rect.add_theme_stylebox_override("panel", pad_sb)
		pad_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		pad_rect.offset_top = 24
		pad_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(pad_rect)
		var d := DieView.new()
		# куб должен целиком уместиться под стаканом, иначе значение видно заранее
		d.position = Vector2(18, 30)
		d.size = Vector2(48, 48)
		d.custom_minimum_size = Vector2(48, 48)
		d.mouse_filter = Control.MOUSE_FILTER_IGNORE
		d.visible = false          # появится, когда куб долетит до места
		slot.add_child(d)
		d.setup(int(rolls[seat]), "basic", String(seat) == "p", false, 0, seat_no)
		dice.append(d)
	await get_tree().process_frame

	# Бросают все, но свой куб игрок кидает сам — свайпом. Без этого битва была
	# «нажми и посмотри, что выпало»: результат тот же, а ощущение — что игру
	# разыграли за тебя.
	for i in seats.size():
		var seat := String(seats[i])
		var value := int(rolls[seat])
		var mine: bool = seat == me and MatchState.seat_is_human(state, seat) \
			and MatchState.seat_local(state, seat)
		var power := 0.45 + rng.randf() * 0.35
		if mine:
			duel_hint.text = "Тяни куб и брось — как настоящий"
			power = await _await_throw(value, i, slots[i])
			duel_hint.text = ""
		await _fly_die(value, i, slots[i], dice[i], power, mine)
		await get_tree().create_timer(0.12).timeout
	await get_tree().create_timer(0.35).timeout
	if last:
		# «ТЫ ходит первым» — та же ошибка, что когда-то с «Ты теряет ♥»: фраза
		# строилась в третьем лице, а имя своего сиденья «Ты»
		var says := _says(state, winner, "ходишь первым!", "ходит первым!")
		duel_note.text = says.substr(0, 1).to_upper() + says.substr(1)
		# выигравшее гнездо обводим золотом: по одним цифрам не сразу видно, чей верх
		var wi := seats.find(winner)
		if wi >= 0 and wi < slots.size():
			var win_sb := StyleBoxFlat.new()
			win_sb.bg_color = Color(Palette.GOLD, 0.12)
			win_sb.set_corner_radius_all(12)
			win_sb.border_color = Palette.GOLD
			win_sb.set_border_width_all(3)
			var pad_node: Panel = slots[wi].get_child(0)
			pad_node.add_theme_stylebox_override("panel", win_sb)
		_flash_screen(Color(1, 0.82, 0.35, 0.25), 0.4)
		buzz(120)
	await get_tree().create_timer(0.9 if last else 0.5).timeout

## Ждём, пока игрок бросит свой куб, и возвращаем силу броска (0..1).
##
## Куб лежит внизу экрана и таскается пальцем; на отпускании берём скорость
## движения. Сила меняет только полёт — высоту дуги, число кувырков и время до
## приземления. Само значение пришло из `roll_duel` и посчитано от сида матча:
## в сетевой партии оба устройства обязаны увидеть одно и то же, а свайп у
## каждого свой. Игрок при этом бросает по-настоящему — просто исход броска
## решён раньше, как у кубика, который уже летит.
##
## Тап без движения тоже засчитывается слабым броском: не у всех выходит свайп,
## и вставать из-за этого игра не должна. Через восемь секунд бросаем сами.
func _await_throw(value: int, idx: int, slot: Control = null) -> float:
	var d := DieView.new()
	d.size = Vector2(64, 64)
	d.custom_minimum_size = Vector2(64, 64)
	d.mouse_filter = Control.MOUSE_FILTER_STOP
	d.setup(value, "basic", idx == 0, false, 0, idx)
	# куб живёт в том же узле, что ловит ввод: тогда координаты касания и позиция
	# куба — одна система, и он точно идёт за пальцем
	duel_input.add_child(d)
	await get_tree().process_frame
	# Куб лежит ПОД своим гнездом, а не по центру экрана: иначе непонятно, куда он
	# полетит — гнездо «ТЫ» слева, а куб посередине.
	var mid_x: float = duel_hand.global_position.x + duel_hand.size.x * 0.5 - 32.0
	if slot != null and slot.size.x > 1.0:
		mid_x = slot.global_position.x + slot.size.x * 0.5 - 32.0
	var home: Vector2 = Vector2(mid_x,
		duel_hand.global_position.y + duel_hand.size.y - 76.0) - duel_input.global_position
	d.position = home
	d.pivot_offset = d.size * 0.5
	# лёгкое «дыхание»: куб выглядит взятым в руку, а не забытым на столе
	var idle := create_tween().set_loops()
	idle.tween_property(d, "position:y", home.y - 6.0, 0.7).set_trans(Tween.TRANS_SINE)
	idle.tween_property(d, "position:y", home.y, 0.7).set_trans(Tween.TRANS_SINE)

	# Состояние броска лежит в полях класса, а не в локальных переменных.
	#
	# Это и была причина «свайп нихуя не работает»: в GDScript лямбда захватывает
	# локальные переменные КОПИЕЙ, поэтому `thrown = true` внутри обработчика
	# ввода не видел цикл ожидания снаружи. Куб послушно ходил за пальцем, а
	# бросок не засчитывался никогда — до автоброска через восемь секунд.
	_throw_die_node = d
	_throw_idle = idle
	_throw_dragging = false
	_throw_done = false
	_throw_speed = Vector2.ZERO
	_throw_last_at = Vector2.ZERO
	_throw_last_ms = 0
	var waited := 0.0
	if _shot_path != "" and _shot_mode != "duel_hand" and _shot_mode != "duel_swipe":
		# снимок экрана свайпнуть некому: бросаем сразу, средней силой.
		# Отдельный сценарий `duel_hand` наоборот ждёт — им проверяется вид
		# экрана в момент, когда куб лежит в руке
		_throw_done = true
		_throw_speed = Vector2(0, -1400)
	duel_input.gui_input.connect(_on_throw_input)

	# Пока куб в руке, значения на нём мельтешат. Настоящее он покажет только
	# когда поднимут стаканчик: иначе игрок читает исход битвы заранее.
	var tick := 0.0
	while not _throw_done and waited < 8.0:
		var dt := get_process_delta_time()
		waited += dt
		tick += dt
		if tick > 0.09:
			tick = 0.0
			d.setup(rng.randi_range(1, 6), "basic", idx == 0, false, 0, idx)
		await get_tree().process_frame
	duel_input.gui_input.disconnect(_on_throw_input)
	if idle.is_valid():
		idle.kill()
	duel_throw_from = d.global_position - duel_layer.global_position
	d.queue_free()
	_throw_die_node = null
	var power := clampf(_throw_speed.length() / 2500.0, 0.0, 1.0)
	if _shot_mode == "duel_swipe":
		print("[свайп] скорость=%.0f px/с сила=%.2f ждали=%.1f с" % [
			_throw_speed.length(), power, waited])
	# 2500 px/с — уверенный резкий свайп; всё, что выше, уже одинаково «сильно»
	return power

## Ввод во время броска. Отдельным методом, а не лямбдой: состояние обязано
## жить в полях объекта, иначе цикл ожидания не узнает, что бросок случился.
func _on_throw_input(e: InputEvent) -> void:
	if _throw_done or _throw_die_node == null or not is_instance_valid(_throw_die_node):
		return
	var press := -1        # 1 нажали, 0 отпустили, -1 не кнопка
	var at := Vector2.ZERO
	if e is InputEventScreenTouch:
		press = 1 if e.pressed else 0
		at = e.position
	elif e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
		press = 1 if e.pressed else 0
		at = e.position
	elif e is InputEventScreenDrag or e is InputEventMouseMotion:
		at = e.position
	else:
		return
	var d: DieView = _throw_die_node
	if press == 1:
		_throw_dragging = true
		_throw_speed = Vector2.ZERO
		_throw_last_ms = 0
		if _throw_idle != null and _throw_idle.is_valid():
			_throw_idle.kill()
		d.position = at - d.size * 0.5
		_throw_track(at)
		buzz(10)
	elif press == 0:
		if _throw_dragging:
			_throw_track(at)
			_throw_done = true
	elif _throw_dragging:
		# куб держится центром под пальцем: так он не убегает от касания и
		# бросок ощущается как настоящий замах
		d.position = at - d.size * 0.5
		_throw_track(at)

## Скорость свайпа считаем сами по двум последним точкам: `velocity` у события
## на Android приходит нулевой чаще, чем хотелось бы, и бросок выходил вялым.
func _throw_track(at: Vector2) -> void:
	var now := Time.get_ticks_msec()
	var dt := float(now - _throw_last_ms) / 1000.0
	if _throw_last_ms > 0 and dt > 0.004:
		# сглаживаем: одиночный рывок пальца не должен решать всё
		_throw_speed = _throw_speed * 0.35 + ((at - _throw_last_at) / dt) * 0.65
	_throw_last_at = at
	_throw_last_ms = now

## Полёт куба в свой слот: дуга, кувырки и мельтешение значений.
##
## Чем сильнее бросок, тем выше дуга и больше оборотов. Значение по дороге
## меняется случайно и садится на настоящее ровно в момент приземления — иначе
## по летящему кубу можно прочитать исход заранее.
func _fly_die(value: int, idx: int, slot: Control, target: DieView, power: float, mine: bool) -> void:
	var to: Vector2 = slot.global_position - duel_layer.global_position + Vector2(18, 30)
	var from: Vector2 = duel_throw_from
	if not mine or from == Vector2.ZERO:
		# соперники бросают из-за нижнего края экрана
		from = Vector2(to.x + (rng.randf() - 0.5) * 120.0, duel_layer.size.y + 40.0)
	var d := DieView.new()
	d.size = Vector2(48, 48)
	d.custom_minimum_size = Vector2(48, 48)
	d.mouse_filter = Control.MOUSE_FILTER_IGNORE
	d.pivot_offset = Vector2(24, 24)
	d.position = from
	# Куб летит уже правильной стороной вверх: прятать значение до приземления
	# было нужно ради стаканчиков, а их больше нет.
	d.setup(value, "basic", idx == 0, false, 0, idx)
	duel_layer.add_child(d)
	var dur := clampf(0.78 - power * 0.26, 0.44, 0.86)
	var arc := clampf(70.0 + power * 190.0, 70.0, 260.0)
	# Оборотов ЦЕЛОЕ число, иначе куб садится наклонённым — «упал неправильной
	# стороной». Сила броска решает, сколько их будет.
	var spins := float(roundi(clampf(1.0 + power * 3.0, 1.0, 4.0))) 		* (1.0 if rng.randf() < 0.5 else -1.0)
	var tw := create_tween().set_parallel(true)
	tw.tween_method(func(t: float):
		if is_instance_valid(d):
			d.position = from.lerp(to, t) - Vector2(0, arc * sin(t * PI))
	, 0.0, 1.0, dur)
	tw.tween_property(d, "rotation", TAU * spins, dur).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	buzz(20 if not mine else 35)
	await get_tree().create_timer(dur).timeout
	if is_instance_valid(d):
		d.queue_free()
	# ряд битвы мог пересобраться (переброс, новая партия) — тогда лететь некуда
	if not is_instance_valid(target):
		return
	target.visible = true
	target.play_place()
	_shake(3.0, 0.12)
	buzz(25)
	await get_tree().create_timer(0.12).timeout

## Экран драфта: из тридцати предложенных кубов игрок набирает восемнадцать.
##
## Без него режим «Своя колода» обманывал названием: колода набиралась случайно,
## и два режима из пяти отличались от классики только условием победы. Соперник
## получает ту же колоду — состязание в том, как ты ей играешь, а не в раздаче.
func _build_draft() -> Control:
	var layer := _full_dim(0.96)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(center)
	var panel := _panel(Palette.PANEL_2)
	center.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	v.custom_minimum_size.x = 330
	panel.add_child(v)
	var t := _label("СВОЯ КОЛОДА", 20, Palette.GOLD, Palette.FONT_TITLE)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(t)
	var about := _label("Собери 18 кубов из 30. У соперника будет ТА ЖЕ колода — состязание в том, как ты ей сыграешь.", 11, Palette.MUTED)
	about.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	about.custom_minimum_size.x = 320
	about.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(about)
	draft_note = _label("", 12, Palette.MUTED)
	draft_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(draft_note)
	var rules_btn := _button("Что умеют кубы", true)
	rules_btn.pressed.connect(_show_rules)
	v.add_child(rules_btn)
	draft_grid = GridContainer.new()
	draft_grid.columns = 5
	draft_grid.add_theme_constant_override("h_separation", 5)
	draft_grid.add_theme_constant_override("v_separation", 5)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(330, 330)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.add_child(draft_grid)
	_hide_scrollbar(scroll)
	v.add_child(scroll)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	v.add_child(row)
	draft_go = _button("В бой")
	draft_go.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	draft_go.pressed.connect(_draft_start)
	row.add_child(draft_go)
	var rnd := _button("Добрать случайно", true)
	rnd.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rnd.pressed.connect(_draft_fill_random)
	row.add_child(rnd)
	var back := _button("Назад", true)
	back.pressed.connect(func():
		draft_layer.visible = false
		_show_menu()
	)
	v.add_child(back)
	return layer

func _show_draft(mode_key: String) -> void:
	if draft_layer == null:
		draft_layer = _build_draft()
		add_child(draft_layer)
	draft_mode = mode_key
	draft_seed = int(Time.get_unix_time_from_system()) & 0x7fffffff
	# предложенные кубы берём тем же путём, что и сама партия: сид один, значит у
	# соперника по сети будет ровно тот же набор
	draft_offer = MatchState.make_deck(MatchState.make_rng(draft_seed), 30)
	draft_picked.clear()
	menu_layer.visible = false
	draft_layer.visible = true
	_draft_refresh()

func _draft_refresh() -> void:
	draft_note.text = "Выбрано %d из %d" % [draft_picked.size(), MatchState.DRAFT_PICK]
	draft_go.disabled = draft_picked.size() != MatchState.DRAFT_PICK
	draft_go.modulate = Color(1, 1, 1, 1.0 if not draft_go.disabled else 0.5)
	for c in draft_grid.get_children():
		c.queue_free()
	for i in draft_offer.size():
		var die: Dictionary = draft_offer[i]
		var chosen: bool = draft_picked.has(i)
		var slot := Panel.new()
		slot.custom_minimum_size = Vector2(60, 60)
		var sb := StyleBoxFlat.new()
		sb.bg_color = Palette.CELL
		sb.set_corner_radius_all(10)
		sb.set_border_width_all(3 if chosen else 2)
		sb.border_color = Palette.GOLD if chosen else Palette.CELL_EDGE
		slot.add_theme_stylebox_override("panel", sb)
		slot.mouse_filter = Control.MOUSE_FILTER_STOP
		slot.gui_input.connect(func(e: InputEvent):
			if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
				_draft_toggle(i)
		)
		draft_grid.add_child(slot)
		var d := DieView.new()
		d.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		d.offset_left = 4
		d.offset_top = 4
		d.offset_right = -4
		d.offset_bottom = -4
		d.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(d)
		d.setup(int(die["value"]), String(die["type"]), true, true)
		if not chosen:
			d.modulate = Color(1, 1, 1, 0.45)

func _draft_toggle(idx: int) -> void:
	if draft_picked.has(idx):
		draft_picked.erase(idx)
	elif draft_picked.size() < MatchState.DRAFT_PICK:
		draft_picked.append(idx)
	buzz(15)
	_draft_refresh()

## «Добрать случайно» — для тех, кто не хочет возиться: добивает выбор до
## восемнадцати, оставляя уже отмеченное.
func _draft_fill_random() -> void:
	var rest := []
	for i in draft_offer.size():
		if not draft_picked.has(i):
			rest.append(i)
	rest.shuffle()
	while draft_picked.size() < MatchState.DRAFT_PICK and not rest.is_empty():
		draft_picked.append(rest.pop_back())
	_draft_refresh()

func _draft_start() -> void:
	if draft_picked.size() != MatchState.DRAFT_PICK:
		return
	var deck := []
	for i in draft_picked:
		deck.append(draft_offer[int(i)])
	draft_layer.visible = false
	_start_mode(draft_mode, deck)

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
	var sub := _label("Имя будет стоять в игре, и его увидят соперники по Wi-Fi.", 11, Palette.MUTED)
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
	# Две каменные створки поверх заливки: они сходятся, закрывая экран, и
	# расходятся, когда следующий игрок готов. Раньше был просто чёрный кадр —
	# самый безрадостный экран в игре, а показывается он каждый второй ход.
	for side in [-1, 1]:
		var wing := Panel.new()
		var wsb := StyleBoxFlat.new()
		wsb.bg_color = Color("18122a")
		wsb.border_color = Color("2f2247")
		wsb.set_border_width_all(3)
		wsb.content_margin_left = 0
		wing.add_theme_stylebox_override("panel", wsb)
		# размеры и координаты задаём сами: с якорями «прижать к краю» твин по x
		# спорил с раскладкой, и правая створка уезжала в левый край
		wing.mouse_filter = Control.MOUSE_FILTER_IGNORE
		layer.add_child(wing)
		veil_wings.append(wing)
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
	var b := _button("Готово — мой ход")
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
	"shield": "Два чужих хода его нельзя съесть — даже колдуном и челюстью. Втроём это два хода двух разных соперников.",
	"spikes": "Скрыт от соперника. Съевший теряет 10 очков, но куб всё равно съеден.",
	"mine": "Скрыта. Уничтожает себя и атакующего, а ход сгорает целиком: ни ренты, ни комбо за него не начислят.",
	"jaw": "При выставлении съедает вражеский куб справа — любого значения, хоть шестёрку. В правом столбце бессильна.",
	"friendly": "Прибавляет к себе сумму значений соседей, и своих и чужих, максимум 12. Дороже шести его уже не съесть обычным кубом.",
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

	for seats in [2, 3, 4]:
		var b := _button("Создать игру на %d" % seats)
		b.pressed.connect(_lan_host.bind(seats))
		lobby_box.add_child(b)
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

func _lan_host(seats: int = 2) -> void:
	_ensure_lan()
	# представляемся именем профиля: соперник увидит «Рустам», а не IP или модель
	if not lan.start_host(Profile.display_name(), seats):
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
	lan.resync_received.connect(_on_lan_resync)
	lan.lobby_changed.connect(_on_lan_lobby)
	lan.party_started.connect(_on_lan_party)
	lan.party_resync_received.connect(_on_lan_party_resync)

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

## Партия пришла заново после переподключения: собираем от сида и повторяем ходы.
func _on_lan_resync(mode: String, seed_value: int, log: Array) -> void:
	_new_flow()
	over_layer.visible = false
	menu_layer.visible = false
	lobby_layer.visible = false
	in_durak = false
	d_state = {}
	durak_layer.visible = false
	battle_root.visible = true
	opponent = "remote"
	state = MatchState.replay(mode, seed_value, "remote", my_seat, foe_player,
		Profile.display_name(), [], log)
	board_grid.columns = int(state["cfg"]["cols"])
	hist_sel = -1
	mode_tag.text = String(state["cfg"]["title"]).to_upper()
	for c in card_box.get_children():
		c.queue_free()
	toast("Вернулись в партию")
	_refresh()
	_relayout_soon()
	_begin_turn(String(state["turn"]))

## Кто подключился последним: ему и отдаём место за столом.
func _last_peer_id() -> int:
	if lan == null or lan.lobby.is_empty():
		return 1
	return int(lan.lobby[lan.lobby.size() - 1]["id"])

## Место для вернувшегося: берём сиденье удалённого игрока по порядку подключения.
func _seat_for_peer(pid: int) -> String:
	var ids: Array = state["order"]
	var at := 1
	for p in lan.lobby:
		if int(p["id"]) == pid:
			return String(ids[mini(at, ids.size() - 1)])
		at += 1
	return String(ids[1])

## Вернулись в партию на троих: состав и место пришли от хозяина, состояние
## собираем повтором журнала.
func _on_lan_party_resync(mode: String, seed_value: int, roster: Array, seat_id: String,
		log: Array) -> void:
	_new_flow()
	my_seat = seat_id
	opponent = "remote"
	var ids := MatchState.seat_ids(roster.size())
	var mine := []
	for i in roster.size():
		var d: Dictionary = roster[i]
		var kind := String(d.get("kind", "bot"))
		var is_me: bool = String(ids[i]) == seat_id
		if kind == "human" and not is_me:
			kind = "remote"
		mine.append({"kind": kind, "local": is_me, "name": String(d.get("name", "Игрок"))})
	roster_for_run = mine
	over_layer.visible = false
	menu_layer.visible = false
	lobby_layer.visible = false
	in_durak = false
	d_state = {}
	durak_layer.visible = false
	battle_root.visible = true
	state = MatchState.replay(mode, seed_value, "remote", my_seat, foe_player,
		Profile.display_name(), [], log, mine)
	board_grid.columns = int(state["cfg"]["cols"])
	hist_sel = -1
	mode_tag.text = String(state["cfg"]["title"]).to_upper()
	for c in card_box.get_children():
		c.queue_free()
	toast("Вернулись в партию")
	_refresh()
	_relayout_soon()
	_begin_turn(String(state["turn"]))

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

## Список подключившихся у хозяина игры: он ждёт, пока стол наполнится, и решает,
## добить ли свободные места ботами.
func _on_lan_lobby(players: Array) -> void:
	if lan == null or not lan.is_host or not state.is_empty():
		return
	for c in lobby_box.get_children():
		c.queue_free()
	var t := _label("СТОЛ НА %d" % lan.table_seats, 18, Palette.GOLD, Palette.FONT_TITLE)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lobby_box.add_child(t)
	lobby_box.add_child(_label("1. %s — это ты" % Profile.display_name(), 12, Palette.TEXT))
	for i in players.size():
		lobby_box.add_child(_label("%d. %s" % [i + 2, String(players[i]["name"])], 12, Palette.TEXT))
	var free_seats: int = lan.table_seats - 1 - players.size()
	for i in free_seats:
		lobby_box.add_child(_label("%d. свободно — займёт бот" % (players.size() + 2 + i), 12, Palette.MUTED))
	var go := _button("Начать" if free_seats == 0 else "Начать, места добьём ботами")
	go.pressed.connect(func():
		lobby_layer.visible = false
		menu_layer.visible = true
		modes_from = "kinds"
		_show_modes()
		menu_note.text = "Стол собран — выбери режим."
	)
	lobby_box.add_child(go)
	var back := _button("Отмена", true)
	back.pressed.connect(func():
		if lan != null:
			lan.stop()
		_lobby_idle()
	)
	lobby_box.add_child(back)

## Партия по сети на троих и больше: состав пришёл от хозяина, своё сиденье тоже.
func _on_lan_party(mode: String, seed_value: int, roster: Array, seat_id: String) -> void:
	_new_flow()
	my_seat = seat_id
	opponent = "remote"
	var ids := MatchState.seat_ids(roster.size())
	var local_roster := []
	for i in roster.size():
		var d: Dictionary = roster[i]
		var kind := String(d.get("kind", "bot"))
		# своё сиденье местное, чужие человеческие — удалённые
		var mine: bool = String(ids[i]) == seat_id
		if kind == "human" and not mine:
			kind = "remote"
		local_roster.append({"kind": kind, "local": mine, "name": String(d.get("name", "Игрок"))})
	roster_for_run = local_roster
	if mode == "durak":
		await _start_durak(seed_value)
		return
	_launch_match(mode, seed_value, [], local_roster)

func _on_lan_connected() -> void:
	foe_left = false
	reconnecting = false
	lan.send_hello()          # обе стороны сразу представляются
	if lan.is_host:
		# Партия уже идёт — значит это вернувшийся, а не новый игрок: отдаём ему
		# партию целиком (сид + журнал), он соберёт её у себя. Раньше здесь
		# безусловно открывался экран режимов — поверх идущей игры, и хост мог
		# случайно начать вторую партию вместо того, чтобы вернуть соперника.
		if not state.is_empty() and not bool(state.get("over", false)):
			if lan.table_seats > 2:
				var pid := _last_peer_id()
				lan.send_party_resync(pid, String(state["mode"]), int(state["seed"]),
					roster_for_run, _seat_for_peer(pid), state["log"])
			else:
				lan.send_resync(String(state["mode"]), int(state["seed"]), state["log"])
			toast("%s вернулся в партию" % foe_player, true)
			return
		if not d_state.is_empty() and not bool(d_state.get("over", false)):
			# Дуракуб журнала не ведёт — партию не восстановить, честно скажем
			toast("%s вернулся, но кон Дуракуба уже не собрать" % foe_player, true)
			return
		# хост выбирает режим; клиент ждёт объявления партии
		lobby_layer.visible = false
		menu_layer.visible = true
		# сразу второй шаг: на первом хост выбрал бы «Одиночную» и порвал сетевую
		# партию, ведь тот экран переставляет opponent
		modes_from = "kinds"
		_show_modes()
		menu_note.text = "%s подключился — выбери режим." % foe_player
	else:
		# у клиента партия могла остаться на экране — тогда ждём resync молча
		if state.is_empty() and d_state.is_empty():
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
		return
	busy = true
	# Партию не хороним: связь на телефоне рвётся от любой мелочи, а состояние
	# восстанавливается из сида и журнала ходов. Клиент сам стучится к хосту,
	# хост просто ждёт — сервер уже слушает порт.
	if lan != null and not lan.is_host and lan.last_address != "":
		_show_result("СВЯЗЬ ПОТЕРЯНА", "Пробуем вернуться в партию…", "В меню", _show_menu)
		_try_reconnect()
	else:
		_show_result("СВЯЗЬ ПОТЕРЯНА", "Ждём соперника: партия сохранена, он может вернуться.",
			"В меню", _show_menu)

## Клиент возвращается к хосту: несколько попыток с паузой. Хост, увидев его,
## пришлёт партию заново (send_resync), и игра продолжится с того же места.
func _try_reconnect() -> void:
	# один цикл за раз: каждая неудачная попытка приводит к `connection_failed`, и
	# без флага она запускала ещё один цикл — за полминуты их набиралось восемь,
	# а `join()` начинается с `stop()`, поэтому они рвали связь друг другу
	if reconnecting:
		return
	reconnecting = true
	var attempts := 8
	for i in attempts:
		if lan == null or lan.connected:
			reconnecting = false
			return
		await get_tree().create_timer(2.0).timeout
		if lan == null or lan.connected or state.is_empty() and d_state.is_empty():
			reconnecting = false
			return
		lan.join(lan.last_address)
	reconnecting = false
	if lan != null and not lan.connected:
		_show_result("СВЯЗЬ ПОТЕРЯНА", "Вернуться не удалось. Соперник ушёл или сеть пропала.",
			"В меню", _show_menu)

func _on_lan_left() -> void:
	# сами уже вышли (встречное «вышел») или партия не сетевая — просто прибрать
	if not lan.connected or opponent != "remote":
		lan.stop.call_deferred()
		return
	# За столом на троих-четверых уход одного — не конец партии: сервер остаётся
	# поднятым для остальных, гасим его только когда ушёл последний.
	if lan.is_host and not lan.lobby.is_empty():
		toast("Игрок вышел из партии", true)
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
	# Состав от прошлой МЕСТНОЙ партии сюда попадать не должен: он чистится только
	# в `_start_mode`, которого у клиента не было. Иначе клиент собирал стол на
	# четверых против стола хоста на двоих — другая колода, другая компенсация,
	# и он ждал хода за сиденье, которого у хоста нет.
	if lan == null or lan.table_seats <= 2:
		roster_for_run = []
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
	_relayout_soon()
	banner("РАУНД %d" % int(state["round"]))
	await _events_phase()
	if state.is_empty():
		return
	_begin_turn(String(state["turn"]))

## Фаза ивентов: раз в несколько раундов игрокам выпадают предложения купить
## преимущество за накопленные очки.
##
## Идёт в начале раунда, когда руки уже розданы: три предложения из четырёх
## работают с рукой, а она каждый раунд новая. Боты решают сами и молча, живым
## показывается экран. По сети ивенты пока не идут: предложение выпадает от сида
## одинаково у всех, а вот ЧТО игрок с ним сделает, надо было бы пересылать.
func _events_phase() -> void:
	if state.is_empty() or opponent == "remote":
		return
	var offers := Events.roll(state)
	if offers.is_empty():
		return
	var tok := flow_token
	for seat in state["order"]:
		var key := String(seat)
		if not offers.has(key):
			continue
		var ev: Dictionary = offers[key]
		if MatchState.seat_is_human(state, key) and MatchState.seat_local(state, key):
			await _show_event(key, ev)
		else:
			var pick := Events.bot_choice(state, key, ev, state["rng"])
			if not pick.is_empty():
				_apply_event(key, ev, pick)
				toast("%s: %s" % [MatchState.seat_name(state, key),
					_event_done_text(String(ev["kind"]))], true)
				await get_tree().create_timer(0.8).timeout
		if tok != flow_token or state.is_empty():
			return
	_refresh()

## Применить выбор — общий хвост для человека и бота.
func _apply_event(seat: String, ev: Dictionary, pick: Dictionary) -> Dictionary:
	match String(pick.get("act", "")):
		"buy":
			return Events.apply_buy(state, seat, ev["offer"], int(pick["idx"]))
		"reroll":
			return Events.apply_reroll(state, seat, int(pick["idx"]), int(pick["value"]))
		"spy":
			return Events.apply_spy(state, seat, String(pick["target"]))
		"swap":
			return Events.apply_swap(state, seat, int(pick["idx"]),
				String(pick["target"]), int(pick["their"]))
		"ward":
			return Events.apply_ward(state, seat)
	return {}

func _build_event() -> Control:
	var layer := _full_dim(0.95)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(center)
	var panel := _panel(Palette.PANEL_2)
	center.add_child(panel)
	event_box = VBoxContainer.new()
	event_box.add_theme_constant_override("separation", 8)
	event_box.custom_minimum_size.x = 320
	panel.add_child(event_box)
	return layer

## Экран предложения. Ждёт, пока игрок решит: купить, взять оберег или отказаться.
func _show_event(seat: String, ev: Dictionary) -> void:
	if event_layer == null:
		event_layer = _build_event()
		add_child(event_layer)
	# в хотсите предложение видит только тот, кому оно выпало: соглядатай иначе
	# показал бы чужую руку прямо сопернику
	if MatchState.shared_device(state):
		await _pass_device(seat)
	_hide_banner()
	event_done = false
	event_layer.visible = true
	_event_draw(seat, ev)
	while not event_done:
		await get_tree().process_frame
	event_layer.visible = false
	_refresh()

## Ширма перед чужим предложением: «передай телефон».
func _pass_device(seat: String) -> void:
	state["shown_to"] = ""
	_show_veil(seat)
	while veil_layer.visible:
		await get_tree().process_frame

func _event_draw(seat: String, ev: Dictionary, step := "main", ctx := {}) -> void:
	for c in event_box.get_children():
		c.queue_free()
	var kind := String(ev["kind"])
	var info: Dictionary = Events.INFO[kind]
	var cost := Events.cost_of(kind)
	var money := Events.funds(state, seat)

	var t := _label(String(info["title"]), 22, Palette.GOLD, Palette.FONT_TITLE)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	event_box.add_child(t)
	if MatchState.shared_device(state):
		var who := _label(MatchState.seat_name(state, seat), 12,
			Palette.name_of(int(state["order"].find(seat))))
		who.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		event_box.add_child(who)
	var d := _label(String(info["text"]), 11, Palette.MUTED)
	d.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	d.custom_minimum_size.x = 300
	event_box.add_child(d)
	var price := _label("Цена %d · в казне %d" % [cost, money], 13,
		Palette.GOLD_LIGHT if money >= cost else Palette.NEG, Palette.FONT_UI)
	price.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	event_box.add_child(price)

	if money < cost and step == "main":
		var poor := _label("Очков не хватает — в другой раз.", 12, Palette.MUTED)
		poor.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		event_box.add_child(poor)
	else:
		match kind:
			"buy": _event_buy(seat, ev)
			"reroll": _event_reroll(seat, ev, step, ctx)
			"spy": _event_spy(seat, ev, step, ctx)
			"swap": _event_swap(seat, ev, step, ctx)

	if step == "main":
		var ward := _button("🛡 Оберег за %d — один раз спасёт руку" % Events.WARD_COST)
		ward.disabled = not Events.can_afford(state, seat, Events.WARD_COST) \
			or Events.warded(state, seat)
		ward.modulate.a = 1.0 if not ward.disabled else 0.5
		ward.pressed.connect(func():
			_apply_event(seat, ev, {"act": "ward"})
			_event_receipt(seat, "ward", "Оберег куплен: чужой соглядатай и меняла уйдут ни с чем")
			event_done = true
		)
		event_box.add_child(ward)
	var no := _button("Отказаться" if step == "main" else "Назад", true)
	no.pressed.connect(func():
		if step == "main":
			event_done = true
		else:
			_event_draw(seat, ev, "main")
	)
	event_box.add_child(no)

## Торговец: три куба на выбор.
func _event_buy(seat: String, ev: Dictionary) -> void:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 10)
	event_box.add_child(row)
	var offer: Array = ev["offer"]
	for i in offer.size():
		var die: Dictionary = offer[i]
		var d := DieView.new()
		d.custom_minimum_size = Vector2(62, 62)
		d.clickable = true
		d.setup(int(die["value"]), String(die["type"]), true, true, 0,
			int(state["order"].find(seat)))
		d.pressed.connect(func(_x):
			var res := _apply_event(seat, ev, {"act": "buy", "idx": i})
			if bool(res.get("ok", false)):
				_event_receipt(seat, "buy", "Куб куплен и уже в руке")
			event_done = true
		)
		row.add_child(d)

## Точильщик: свой куб, потом новое значение.
func _event_reroll(seat: String, ev: Dictionary, step: String, ctx: Dictionary) -> void:
	var hand: Array = state["players"][seat]["hand"]
	if step == "main":
		event_box.add_child(_event_hint("Какой куб точим?"))
		var row := HBoxContainer.new()
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		row.add_theme_constant_override("separation", 8)
		event_box.add_child(row)
		for i in hand.size():
			var d := DieView.new()
			d.custom_minimum_size = Vector2(56, 56)
			d.clickable = true
			d.setup(int(hand[i]["value"]), String(hand[i]["type"]), true, true, 0,
				int(state["order"].find(seat)))
			d.pressed.connect(func(_x): _event_draw(seat, ev, "value", {"idx": i}))
			row.add_child(d)
		return
	event_box.add_child(_event_hint("Какое значение поставить?"))
	var vals := HBoxContainer.new()
	vals.alignment = BoxContainer.ALIGNMENT_CENTER
	vals.add_theme_constant_override("separation", 6)
	event_box.add_child(vals)
	for v in range(1, 7):
		var b := _button(str(v))
		b.custom_minimum_size = Vector2(42, 42)
		b.pressed.connect(func():
			_apply_event(seat, ev, {"act": "reroll", "idx": int(ctx["idx"]), "value": v})
			_event_receipt(seat, "reroll", "Куб сточен до %d" % v)
			event_done = true
		)
		vals.add_child(b)

## Соглядатай: выбрать соперника и посмотреть его руку.
func _event_spy(seat: String, ev: Dictionary, step: String, ctx: Dictionary) -> void:
	if step == "main":
		event_box.add_child(_event_hint("Чью руку смотрим?"))
		for foe in Events.rivals(state, seat):
			event_box.add_child(_event_foe_button(foe, func():
				var res := _apply_event(seat, ev, {"act": "spy", "target": foe})
				_event_draw(seat, ev, "shown", {"target": foe, "res": res})
			))
		return
	var res: Dictionary = ctx["res"]
	if bool(res.get("blocked", false)):
		event_box.add_child(_event_hint("Рука закрыта оберегом — ничего не видно. %d очков ушли впустую."
			% Events.cost_of("spy")))
	else:
		event_box.add_child(_event_hint("Рука игрока %s:"
			% MatchState.seat_name(state, String(ctx["target"]))))
		event_box.add_child(_event_hand_row(String(ctx["target"]), res["hand"], Callable()))
	var ok := _button("Запомнил")
	ok.pressed.connect(func(): event_done = true)
	event_box.add_child(ok)

## Меняла: свой куб → соперник → его куб.
func _event_swap(seat: String, ev: Dictionary, step: String, ctx: Dictionary) -> void:
	var hand: Array = state["players"][seat]["hand"]
	if step == "main":
		event_box.add_child(_event_hint("Какой свой куб отдаём?"))
		var row := HBoxContainer.new()
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		row.add_theme_constant_override("separation", 8)
		event_box.add_child(row)
		for i in hand.size():
			var d := DieView.new()
			d.custom_minimum_size = Vector2(56, 56)
			d.clickable = true
			d.setup(int(hand[i]["value"]), String(hand[i]["type"]), true, true, 0,
				int(state["order"].find(seat)))
			d.pressed.connect(func(_x): _event_draw(seat, ev, "who", {"mine": i}))
			row.add_child(d)
		return
	if step == "who":
		event_box.add_child(_event_hint("С кем меняемся?"))
		for foe in Events.rivals(state, seat):
			event_box.add_child(_event_foe_button(foe, func():
				_event_draw(seat, ev, "their", {"mine": int(ctx["mine"]), "target": foe})
			))
		return
	var target := String(ctx["target"])
	if Events.warded(state, target):
		event_box.add_child(_event_hint("Рука закрыта оберегом — меняться не с чем. %d очков уйдут впустую."
			% Events.cost_of("swap")))
		var back := _button("Ясно")
		back.pressed.connect(func():
			_apply_event(seat, ev, {"act": "swap", "idx": int(ctx["mine"]),
				"target": target, "their": 0})
			event_done = true
		)
		event_box.add_child(back)
		return
	event_box.add_child(_event_hint("Что берём взамен?"))
	event_box.add_child(_event_hand_row(target, state["players"][target]["hand"],
		func(i: int):
			_apply_event(seat, ev, {"act": "swap", "idx": int(ctx["mine"]),
				"target": target, "their": i})
			_event_receipt(seat, "swap", "Обмен состоялся")
			event_done = true
	))

## Чек за покупку: сколько списали и сколько осталось. Без него ни одна цифра на
## экране не шевелилась, и было непонятно, заплатил ты или нет.
func _event_receipt(seat: String, kind: String, what: String) -> void:
	var cost := Events.WARD_COST if kind == "ward" else Events.cost_of(kind)
	toast("%s · −%d, в казне %d" % [what, cost, Events.funds(state, seat)])

func _event_done_text(kind: String) -> String:
	match kind:
		"buy": return "купил куб у торговца"
		"reroll": return "сточил свой куб"
		"spy": return "подсмотрел чью-то руку"
		"swap": return "обменялся кубом"
	return "воспользовался ивентом"

func _event_hint(text: String) -> Control:
	var l := _label(text, 13, Palette.TEXT)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size.x = 300
	return l

func _event_foe_button(foe: String, on_press: Callable) -> Control:
	var b := _button(MatchState.seat_name(state, foe))
	b.pressed.connect(on_press)
	return b

## Ряд чужих кубов. `on_pick` пустой — только показать.
func _event_hand_row(seat: String, hand: Array, on_pick: Callable) -> Control:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 8)
	for i in hand.size():
		var die: Dictionary = hand[i]
		var d := DieView.new()
		d.custom_minimum_size = Vector2(56, 56)
		d.clickable = on_pick.is_valid()
		# в чужой руке видно всё, включая ловушки: за это и платят
		d.setup(int(die["value"]), String(die["type"]), false, true, 0,
			int(state["order"].find(seat)))
		if on_pick.is_valid():
			d.pressed.connect(func(_x): on_pick.call(i))
		row.add_child(d)
	return row

func _build_rules() -> Control:
	var layer := _full_dim(0.96)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(center)
	var panel := _panel(Palette.PANEL_2)
	center.add_child(panel)
	# Кнопка выхода лежит РЯДОМ с прокруткой, а не внутри неё: правила длиной в
	# два экрана, и «Понятно» приходилось искать, докручивая до самого низа.
	var shell := VBoxContainer.new()
	shell.add_theme_constant_override("separation", 8)
	panel.add_child(shell)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(330, 580)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_hide_scrollbar(scroll)
	shell.add_child(scroll)
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
	rb.add_child(_rules_line("Съесть чужой куб может любой твой куб, если его значение не меньше: шестёрка ест всех, единица — только единицу."))
	rb.add_child(_rules_head("Очки за ход"))
	rb.add_child(_rules_line("Съел — значение съеденного куба."))
	rb.add_child(_rules_line("Кубы на поле — сумма значений всех твоих кубов, начисляется каждый ход. Это главный источник очков: из него приходит около трёх четвертей дохода."))
	rb.add_child(_rules_line("Комбо из твоих кубов: пара +5, две пары +10, сет +15, фулл-хаус +25, каре +40, пятёрка +60, шестёрка +100."))
	rb.add_child(_rules_line("Лесенка — подряд идущие значения: три +10, четыре +20, пять +35. Годятся и кубы из пары: 3, 3, 4, 5 — это лесенка."))
	rb.add_child(_rules_line("Считается только ЛУЧШАЯ комбинация, а не все сразу: 4, 4, 4, 5, 6 дают сет +15, а не сет с лесенкой."))
	rb.add_child(_rules_line("Комбо начисляется каждый ход, пока кубы стоят на поле. Поэтому ранний ход стоит дороже позднего: он успеет принести доход много раз."))
	rb.add_child(_rules_line("Тот, кто ходит в раунде первым, получает очки вперёд: отвечать выгоднее, чем начинать. В Классике это +6, на Большой доске +16, а втроём-вчетвером надбавка делится по очереди — последнему не достаётся ничего."))
	rb.add_child(_rules_head("Режимы"))
	rb.add_child(_rules_line("Классика и Большая доска — три жизни. Вдвоём сердце теряет проигравший раунд, втроём и вчетвером — все, кроме взявшего раунд. Потерял все три — выбыл, остальные доигрывают без тебя."))
	rb.add_child(_rules_line("Своя колода — три раунда одной колодой, раунд берёт тот, у кого больше очков."))
	rb.add_child(_rules_line("Гонка — счёт копится между раундами, побеждает первый набравший 500."))
	rb.add_child(_rules_line("Территория — за каждый ход начисляются удержанные клетки, раунд берёт тот, у кого их больше."))
	rb.add_child(_rules_line("Дуракуб — подкидной дурак кубами, свои правила на отдельном экране."))
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
	rd.add_child(_rules_line("После кона руки добираются из колоды, первым добирает атакующий. Вдвоём и втроём рука до шести кубов, вчетвером — до пяти: иначе колода раздаётся целиком и прикупа не остаётся."))
	rd.add_child(_rules_line("Партия идёт, пока колода не кончится и с кубами не останется один — он и дуракуб. Первым атакует тот, у кого младший козырь."))
	rd.add_child(_rules_line("Способностей и очков здесь нет — только масти, значения и козырь."))

	var b := _button("Понятно")
	b.pressed.connect(func(): rules_layer.visible = false)
	shell.add_child(b)
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

## Значок в правилах обязан совпадать со значком на кубе. Раньше в правилах была
## нарисованная картинка, а на грани — эмодзи: игрок видел в правилах шипастый
## шар, а на кубе ежа, и не связывал одно с другим.
func _ability_row(key: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var mark := _label(String(Rules.TYPES[key]["icon"]), 30, Palette.TEXT)
	mark.custom_minimum_size = Vector2(44, 44)
	mark.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	mark.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(mark)
	if false:
		pass
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
	# состав прошлой партии в меню больше не действует: иначе он утекал в
	# следующую — в том числе в сетевую, где стол задаёт хозяин
	roster_for_run = []
	in_durak = false
	d_state = {}
	menu_layer.visible = true
	durak_layer.visible = false
	battle_root.visible = true
	veil_layer.visible = false
	over_layer.visible = false
	if event_layer != null:
		event_layer.visible = false
	event_done = true      # оборвать ожидание ивента, если оно шло
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

## deck — колода, набранная на экране драфта. Пустая означает «раздать самим»:
## так запускаются остальные режимы и клиент по сети.
func _start_mode(key: String, deck: Array = []) -> void:
	if key == "durak":
		await _start_durak()
		return
	# «Свою колоду» и «Территорию» игрок сперва набирает руками — иначе название
	# режима обманывает, а от классики он отличается только условием победы
	if deck.is_empty() and String(MatchState.MODES[key]["deck"]) == "draft" and opponent != "remote":
		_show_draft(key)
		return
	var seed_value := draft_seed if not deck.is_empty() else (int(Time.get_unix_time_from_system()) & 0x7fffffff)
	roster_for_run = _roster_for_match() if opponent == "roster" else []
	_announced_out = {}
	if opponent == "remote" and lan != null and lan.is_host and lan.table_seats > 2:
		# Стол на троих и больше: хозяин раздаёт сиденья по порядку подключения,
		# свободные места занимают боты, и каждому лично уходит его сиденье.
		var roster := [{"kind": "human", "name": Profile.display_name()}]
		var seat_by_peer := {}
		var ids := MatchState.seat_ids(lan.table_seats)
		var at := 1
		for p in lan.lobby:
			roster.append({"kind": "human", "name": String(p["name"])})
			seat_by_peer[int(p["id"])] = String(ids[at])
			at += 1
		var bots := 0
		while roster.size() < lan.table_seats:
			roster.append({"kind": "bot", "name": MatchState.BOT_NAMES[mini(bots, 3)]})
			bots += 1
		my_seat = "p"
		lan.send_party(key, seed_value, roster, seat_by_peer)
		var mine := []
		for i in roster.size():
			var d: Dictionary = roster[i]
			mine.append({"kind": String(d["kind"]),
				"local": String(ids[i]) == my_seat, "name": String(d["name"])})
		roster_for_run = mine
		_launch_match(key, seed_value, deck, mine)
		return
	if opponent == "remote" and lan != null and lan.is_host:
		lan.send_start(key, seed_value)      # соперник соберёт ту же раздачу из сида
	_launch_match(key, seed_value, deck)

## Общий хвост запуска боевой партии: у хоста и одиночки из _start_mode, у
## клиента из _on_lan_match_started. Раньше клиент собирал партию своей копией
## этого кода, и в ней не гасился оверлей исхода: после «Ещё раз» у хоста клиент
## смотрел на «Ждём хоста…» поверх уже идущей новой партии.
func _launch_match(key: String, seed_value: int, deck: Array = [], roster: Array = []) -> void:
	_new_flow()
	_reset_shift()
	menu_layer.visible = false
	over_layer.visible = false
	in_durak = false
	d_state = {}
	durak_layer.visible = false
	battle_root.visible = true
	selected = -1
	state = MatchState.new_match(key, seed_value, opponent, my_seat, foe_player, Profile.display_name(), deck, roster if not roster.is_empty() else roster_for_run)
	board_grid.columns = int(state["cfg"]["cols"])
	hist_sel = -1
	mode_tag.text = String(state["cfg"]["title"]).to_upper()
	for c in card_box.get_children():
		c.queue_free()
	toast("")
	_refresh()
	_relayout_soon()
	# Торг за первый ход идёт до начала партии — у сетевых партий пока цена по
	# умолчанию: обмен ставками по сети сделан не будет без отдельного протокола.
	_start_duel(func():
		banner("РАУНД %d" % int(state["round"]))
		_begin_turn(String(state["turn"]))
	)
	return
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
		# в сетевой партии бота ведёт только хозяин игры: иначе каждый сделает ход
		# за него, и состояния разъедутся
		if opponent == "remote" and lan != null and not lan.is_host:
			busy = true
			_refresh()
			return
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

## Створки съезжаются к центру: экран закрывается «дверью», а не просто гаснет.
func _veil_doors(closed: bool) -> void:
	var vp := get_viewport_rect().size
	var half := vp.x * 0.5 + 1.0        # +1: чтобы посередине не осталось щели
	for i in veil_wings.size():
		var wing: Control = veil_wings[i]
		wing.size = Vector2(half, vp.y)
		wing.position.y = 0.0
		var shut: float = 0.0 if i == 0 else vp.x - half
		var opened: float = -half if i == 0 else vp.x
		if closed:
			# перед закрытием ставим створки снаружи, чтобы движение было видно
			wing.position.x = opened
		var tw := create_tween()
		tw.tween_property(wing, "position:x", shut if closed else opened, 0.3) 			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)

func _show_veil(seat: String) -> void:
	busy = true
	selected = -1
	_veil_doors(true)
	# баннер раунда живёт своей анимацией и успевает лечь поверх заголовка ширмы
	_hide_banner()
	var st: Dictionary = d_state if in_durak else state
	veil_title.text = "%s, твой ход" % MatchState.seat_name(st, seat)
	veil_layer.visible = true
	_refresh_screen()

func _hide_veil() -> void:
	_veil_doors(false)
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

## Итог раунда или матча. `table` — показывать ли таблицу игроков: списком «Счёт:
## Скелетина 74 · Костолом 34 · Ты 11» на четверых уже ничего не понять, нужны
## строки с очками и жизнями и подсвеченный победитель.
func _show_result(title: String, detail: String, button: String, on_press: Callable,
		table_winner := "", table := false) -> void:
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
	if detail != "":
		var d := _label(detail, 13, Palette.TEXT)
		d.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		d.custom_minimum_size.x = 300
		box.add_child(d)
	if table and not state.is_empty():
		box.add_child(_score_table(table_winner))
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

## Таблица итогов: кто сколько набрал и сколько сердец осталось. Победитель
## наверху и подсвечен, выбывшие — с черепом и перечёркнутым именем.
func _score_table(winner: String) -> Control:
	var cfg: Dictionary = state["cfg"]
	var by_count: bool = String(cfg.get("win_by", "")) == "count"
	var kind := String(cfg["kind"])
	var rows := []
	for seat in state["order"]:
		rows.append({
			"seat": String(seat),
			"v": MatchState.round_value(state, String(seat)),
			"out": MatchState.is_out(state, String(seat)),
		})
	# победитель первым, выбывшие в самом низу
	rows.sort_custom(func(a, b):
		if bool(a["out"]) != bool(b["out"]):
			return not bool(a["out"])
		return int(a["v"]) > int(b["v"]))

	var grid := VBoxContainer.new()
	grid.add_theme_constant_override("separation", 4)
	var head_pad := MarginContainer.new()
	head_pad.add_theme_constant_override("margin_left", 8)
	head_pad.add_theme_constant_override("margin_right", 8)
	grid.add_child(head_pad)
	var head := HBoxContainer.new()
	head_pad.add_child(head)
	head.add_child(_col(_label("ИГРОК", 10, Palette.MUTED), 3))
	head.add_child(_col(_label("УДЕРЖАНО" if by_count else "ОЧКИ", 10, Palette.MUTED, "", HORIZONTAL_ALIGNMENT_RIGHT), 2))
	if kind == "lives":
		# рисованное сердце, а не эмодзи: заданный цвет глиф игнорирует и выходит
		# розовым — на одной панели получалось два разных сердца
		var head_heart := LifeRow.new()
		head_heart.setup(1, 1, LifeRow.KIND_HEART, Palette.MUTED)
		var hw := HBoxContainer.new()
		hw.alignment = BoxContainer.ALIGNMENT_END
		hw.add_child(head_heart)
		head.add_child(_col(hw, 1))
	elif kind == "bo3":
		head.add_child(_col(_label("ПОБЕД", 10, Palette.MUTED, "", HORIZONTAL_ALIGNMENT_RIGHT), 1))

	for r in rows:
		var seat := String(r["seat"])
		var dead: bool = bool(r["out"])
		var win: bool = seat == winner and winner != ""
		var line := PanelContainer.new()
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(Palette.GOLD, 0.10) if win else Color(0, 0, 0, 0.22)
		sb.set_corner_radius_all(8)
		sb.content_margin_left = 8
		sb.content_margin_right = 8
		sb.content_margin_top = 5
		sb.content_margin_bottom = 5
		if win:
			sb.border_color = Palette.GOLD
			sb.set_border_width_all(1)
		line.add_theme_stylebox_override("panel", sb)
		var row := HBoxContainer.new()
		line.add_child(row)
		var who_box := HBoxContainer.new()
		who_box.add_theme_constant_override("separation", 4)
		if win or dead:
			# значок отдельным узлом: внутри `[s]` линия перечёркивала сам череп и
			# это читалось как сбой отрисовки
			who_box.add_child(_label("👑" if win else "💀", 12, Palette.GOLD_LIGHT))
		who_box.add_child(_name_label(MatchState.seat_name(state, seat),
			Palette.name_of(int(state["order"].find(seat))), dead))
		row.add_child(_col(who_box, 3))
		row.add_child(_col(_label(str(int(r["v"])), 15, Palette.GOLD_LIGHT if win else Palette.TEXT,
			Palette.FONT_UI, HORIZONTAL_ALIGNMENT_RIGHT), 2))
		if kind == "lives":
			var hearts := LifeRow.new()
			hearts.setup(Rules.LIVES_MAX, int(state["players"][seat]["lives"]))
			var wrap := HBoxContainer.new()
			wrap.alignment = BoxContainer.ALIGNMENT_END
			wrap.add_child(hearts)
			row.add_child(_col(wrap, 1))
		elif kind == "bo3":
			row.add_child(_col(_label(str(int(state["players"][seat]["wins"])), 13,
				Palette.TEXT, Palette.FONT_UI, HORIZONTAL_ALIGNMENT_RIGHT), 1))
		if dead:
			# 0.55 уводило имя кровавого сиденья на 2.3:1, а счёт на 3.7:1 — читать
			# нельзя. Череп, зачёркивание и пустые сердца и так говорят всё
			line.modulate.a = 0.85
		grid.add_child(line)
	return grid

## Ячейка таблицы заданной доли ширины.
func _col(node: Control, ratio: float) -> Control:
	node.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	node.size_flags_stretch_ratio = ratio
	return node

# ------------------------------------------------------------- отображение

func _refresh() -> void:
	if state.is_empty():
		return
	var cfg: Dictionary = state["cfg"]
	var me := viewer()
	var i_am_out: bool = MatchState.is_out(state, me)
	# Череп рисовался только в строках соперников: выбывший игрок сидел с обычной
	# панелью и не понимал, почему ход к нему не приходит.
	my_name.text = ("💀 " if i_am_out else "") + MatchState.seat_name(state, me).to_upper()
	my_name.add_theme_color_override("font_color",
		Palette.MUTED if i_am_out else Palette.name_of(int(state["order"].find(me))))
	var kind := String(cfg["kind"])
	_roll_score(my_score, me, kind, cfg)
	my_score.add_theme_color_override("font_color",
		Palette.NEG if int(state["players"][me]["score"]) < 0 else Palette.GOLD_LIGHT)
	if kind == "lives":
		my_hearts.setup(Rules.LIVES_MAX, int(state["players"][me]["lives"]))
		my_hearts.visible = true
	elif kind == "bo3":
		my_hearts.setup(2, int(state["players"][me]["wins"]), LifeRow.KIND_STAR, Palette.GOLD)
		my_hearts.visible = true
	else:
		my_hearts.visible = false
	# соперники строками: с двумя игроками одна панель как раньше, с тремя-четырьмя
	# каждая строка сжимается и рубашки руки уступают место счёту
	for c in foes_box.get_children():
		c.queue_free()
	var foes := []
	for seat in state["order"]:
		if seat != me:
			foes.append(seat)
	for seat in foes:
		foes_box.add_child(_foe_row(String(seat), foes.size() > 1))
	# Казна — очки, набранные с начала матча. Раньше её нигде не показывали, и
	# число в окне ивента («в казне 200») игрок видел впервые в жизни.
	var purse := Events.funds(state, me)
	my_deck.text = "Колода: %d · казна %d" % [state["players"][me]["deck"].size(), purse]
	var turn := String(state["turn"])
	var move_no: int = mini(int(state["players"][turn]["moves"]) + 1, int(cfg["moves"]))
	turn_info.text = "РАУНД %d · ХОД %d/%d" % [int(state["round"]), move_no, int(cfg["moves"])]
	if i_am_out:
		turn_who.text = "ТЫ ВЫБЫЛ"
	elif _solo(state) and turn == me:
		turn_who.text = "ТВОЙ ХОД"
	elif _solo(state):
		turn_who.text = "ХОД СОПЕРНИКА"
	else:
		turn_who.text = "ХОД: " + MatchState.seat_name(state, turn).to_upper()
	turn_who.add_theme_color_override("font_color",
		Palette.MUTED if i_am_out else (Palette.GOLD_LIGHT if turn == me else Palette.NEG))

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

## Счёт прокручивается до нового значения, а не перескакивает: за ход прилетает
## сразу два-три десятка очков, и мгновенная подмена числа читалась как сбой.
func _roll_score(label: Label, seat: String, kind: String, cfg: Dictionary) -> void:
	var target := int(state["players"][seat]["score"])
	var shown: int = int(_shown_score.get(seat, target))
	_shown_score[seat] = target
	if shown == target or absi(target - shown) > 400:
		label.text = _score_text(seat, kind, cfg, target)
		return
	var tw := create_tween()
	tw.tween_method(func(v: float):
		label.text = _score_text(seat, kind, cfg, int(round(v)))
	, float(shown), float(target), 0.45).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)

func _score_text(seat: String, kind: String, cfg: Dictionary, override_score: int = -999999) -> String:
	var sc := int(state["players"][seat]["score"]) if override_score == -999999 else override_score
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
		var cell_owner := "" if state["board"][i] == null else String(state["board"][i]["owner"])
		slot.add_theme_stylebox_override("panel", _cell_box(valid.has(i), state["board"][i] != null,
			i == hint_cell, cell_owner))
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
				not hidden or seen, int(cell["shield"]),
				int(state["order"].find(String(cell["owner"]))))

## Размер клетки: по ширине экрана и по тому, что реально осталось от высоты.
##
## Раньше «всё кроме доски» было константой, снятой со снимка (582 px), и на
## телефоне с другой высотой строк кнопки «Правила» и «Меню» вылезали за край.
## Теперь высота остального спрашивается у самих узлов — сколько им нужно, — и
## доска забирает ровно остаток. Что бы ни поменялось в панелях, экран сойдётся.
func _cell_size(cols: int, cells: int) -> float:
	var rows: int = ceili(float(cells) / float(cols))
	# ширина — фактическая, а не 390 из макета: на телефоне уже 360, и доска,
	# посчитанная по макету, распирала столбец и вылезала за края
	var vw: float = get_viewport_rect().size.x
	var by_width: float = (vw - _safe.x - _safe.z - CELL_GAP * (cols - 1)) / float(cols)
	var by_height := by_width
	# после раскладки контейнер сам сказал, сколько места досталось доске —
	# считаем от него. Расчёт по сумме минимумов оставлен на первый кадр, когда
	# размеры ещё не известны.
	if board_holder != null and board_holder.size.y > 40.0:
		return maxf(minf(by_width, (board_holder.size.y - CELL_GAP * (rows - 1)) / float(rows)), 46.0)
	if battle_col != null and board_holder != null:
		var sep: float = float(battle_col.get_theme_constant("separation"))
		var need := 0.0
		var n := 0
		for c in battle_col.get_children():
			if c is Control and c.visible:
				n += 1
				if c != board_holder:
					need += (c as Control).get_combined_minimum_size().y
		if n > 1:
			need += sep * float(n - 1)
		var avail: float = get_viewport_rect().size.y - _safe.y - _safe.w - need
		by_height = (avail - CELL_GAP * (rows - 1)) / float(rows)
	return maxf(minf(by_width, by_height), 46.0)

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
		d.setup(int(die["value"]), String(die["type"]), me == "p", true, 0,
			int(state["order"].find(me)))
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
		# на троих ход идёт через хозяина игры: он применяет и раздаёт остальным
		if lan.table_seats > 2 or not lan.is_host:
			lan.send_move_party(seat, hand_idx, cell_idx)
		else:
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
					func(): _start_mode(String(state["mode"])), String(final["winner"]), true)
				return
			busy = true
			var rp := _round_phrases(String(out["winner"]), "")
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
			, String(out["winner"]), true)
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
	# «СОПЕРНИК» годится, когда он один; втроём нужны имена, иначе строки
	# соперников не отличить друг от друга
	if _solo(st) and st["order"].size() <= 2:
		return "ТЫ" if seat == _my_view(st) else "СОПЕРНИК"
	if seat == _my_view(st) and _solo(st):
		return "ТЫ"
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
		return {"title": "НИЧЬЯ В РАУНДЕ", "text": "Никто не теряет сердце"}
	var mine := _my_view(state)
	var title := ""
	if _solo(state):
		title = "РАУНД ТВОЙ!" if winner == mine else "РАУНД ЗА СОПЕРНИКОМ"
	else:
		title = MatchState.seat_name(state, winner).to_upper() + " БЕРЁТ РАУНД"
	# Счёт больше не пишем строкой: он в таблице под заголовком. Здесь остаётся
	# только правило — что произошло с сердцами.
	var text := detail
	var many: bool = state["order"].size() > 2
	if String(state["cfg"]["kind"]) == "lives":
		# Втроём и вчетвером сердце теряет каждый, кроме взявшего раунд, — фраза
		# про одного проигравшего описывала правило неверно, а `other_seat` вообще
		# называл соседа по кругу
		if many:
			text = "Сердце теряют все, кроме победителя"
		else:
			text = "%s сердце" % _cap(_says(state, MatchState.other_seat(state, winner),
				"теряешь", "теряет"))
	# только те, кто выбыл именно в этом раунде: иначе «💀 выбывает: Костолом»
	# повторялось в каждом следующем раунде до конца матча
	var gone := []
	for seat in state["order"]:
		var key := String(seat)
		if MatchState.is_out(state, key) and not _announced_out.has(key):
			_announced_out[key] = true
			gone.append(MatchState.seat_name(state, key))
	if not gone.is_empty():
		text += "\n💀 выбывает: %s" % ", ".join(gone)
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
	# Втроём и вчетвером «другой игрок» — это не сосед по кругу, а список. Раньше
	# все хвосты звали `other_seat`, и в партии на четверых без жизней объявляли
	# не того, а счёт показывали только у первых двух сидений.
	var many: bool = state["order"].size() > 2
	match kind:
		"lives":
			if winner == "":
				text = "Жизни кончились у всех разом."
			elif solo and winner == mine:
				text = "Враг повержен!" if vs_bot else "Соперник остался без жизней!"
			elif solo:
				text = "Подземелье забрало твои кости." if vs_bot else "Твои жизни кончились."
			elif many:
				text = "%s держится до конца — осталось %s." % [MatchState.seat_name(state, winner),
					_lives_word(int(state["players"][winner]["lives"]))]
			else:
				text = "%s остался без жизней." % MatchState.seat_name(state,
					MatchState.other_seat(state, winner))
		"race":
			var target := int(state["cfg"]["target"])
			var tally := _tally("score")
			if winner == "":
				text = "Ничья: %s" % tally
			else:
				text = "%s до %d! Итог: %s" % [_cap(_says(state, winner, "добираешься", "добирается")),
					target, tally]
		_:
			var top := 0
			var shared := false
			for seat in state["order"]:
				var w := int(state["players"][seat]["wins"])
				if w > top:
					top = w
					shared = false
				elif w == top:
					shared = true
			if not shared and winner != "":
				text = "%s %d %s из 3." % [_cap(_says(state, winner, "берёшь", "берёт")),
					top, _plural(top, "раунд", "раунда", "раундов")]
			else:
				text = "Раунды поделили (%s), решили очки за матч: %s" % [
					_tally("wins"), _tally("total")]
	return {"title": title, "text": text}

## Счёт по всем сиденьям с именами: «Руслан 320 · Костолом 285». На двоих это
## прежнее «320 : 285», только подписанное, а на четверых иначе не понять, где чей.
func _tally(field: String) -> String:
	var parts := []
	for seat in state["order"]:
		parts.append("%s %d" % [MatchState.seat_name(state, String(seat)),
			int(state["players"][seat][field])])
	return " · ".join(parts)

func _lives_word(n: int) -> String:
	return "%d %s" % [n, _plural(n, "жизнью", "жизнями", "жизнями")]

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

## Шапка карточки: чей это был ход. Номер убран намеренно — в шапке экрана уже
## стоит «РАУНД 1 · ХОД 2/6», в ленте свои номера, и три разные нумерации на
## одном экране читались как «я что-то пропустил».
func _card_head(seat: String, _n: int) -> String:
	if _solo(state) and seat == _my_view(state):
		return "ТВОЙ ХОД"
	return _who_name(state, seat).to_upper()

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

	# Строку «рента +6 · впереди 9 ходов — это ещё +54» убрали: она объясняла,
	# почему ранний куб дороже позднего, но висела под каждой карточкой и на
	# невысоком экране съедала место, которое нужнее доске. Сама рента никуда не
	# делась — она даёт около 70% всех очков и живёт в жетоне «Кубы на поле»,
	# а объяснение осталось на экране правил.

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
		# карточку могло пересобрать за время ожидания кадров и полётов чисел —
		# новый ход, конец раунда, пересчёт раскладки. Тогда играть уже нечего
		if not is_instance_valid(chips) or i >= chips.get_child_count():
			return
		var p: Dictionary = parts[i]
		var chip: Control = chips.get_child(i)
		if p.has("hl"):
			if String(p.get("cls", "")) == "combo":
				# кубы комбинации вспыхивают по очереди: видно, какие именно
				# сложились, а не «вся доска мигнула»
				for ci in p["hl"]:
					_glow_cell(int(ci))
					await get_tree().create_timer(0.07).timeout
			else:
				for ci in p["hl"]:
					_glow_cell(int(ci))
		if p.has("v") and not p.get("die", false):
			await _fly_number(p, chip, seat)
		if not is_instance_valid(chip):
			return
		_pop_in(chip)
		await get_tree().create_timer(0.16).timeout

	var pts := int(res["pts"])
	if not is_instance_valid(total):
		return
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
var _shown_score := {}      # какое число счёта сейчас на экране, для прокрутки
var veil_wings: Array = []  # створки ширмы
var battle_fit: Control         # обёртка, вписывающая колонку в экран
var durak_fit: Control
var battle_col: VBoxContainer   # колонка боевого экрана: по ней считаем свободное место
var board_holder: Control       # обёртка доски
var durak_col: VBoxContainer    # колонка экрана Дуракуба
var durak_table_holder: Control # стол Дуракуба

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
	_clamp_to_screen(box)
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
## Держим всплывающую надпись в пределах экрана. Выкрик комбинации садился на
## x=341 при ширине 390 — игрок читал «СЕ» вместо «СЕТ +15».
func _clamp_to_screen(node: Control) -> void:
	var w := get_viewport_rect().size.x
	node.global_position.x = clampf(node.global_position.x, 8.0, maxf(8.0, w - node.size.x - 8.0))

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
	_clamp_to_screen(box)
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
	# карточку могло пересобрать прямо во время полёта — новый ход, смена раунда,
	# пересчёт раскладки. Тогда лететь уже некуда, и обращение к жетону валит кадр
	if not is_instance_valid(chip):
		return
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
	if not is_instance_valid(chip):
		return
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

## Поддельные касания: ими сценарий `--shot-duel-swipe` проверяет, что бросок
## свайпом вообще срабатывает. Руками это не проверить — окна игры я не вижу.
func _fake_touch(at: Vector2, down: bool) -> void:
	var e := InputEventScreenTouch.new()
	e.index = 0
	e.pressed = down
	e.position = at
	get_viewport().push_input(e, true)

func _fake_drag(at: Vector2, rel: Vector2) -> void:
	var e := InputEventScreenDrag.new()
	e.index = 0
	e.position = at
	e.relative = rel
	get_viewport().push_input(e, true)

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
		"duel":
			opponent = "bot"
			_start_mode("classic")
			await get_tree().create_timer(0.5).timeout
		"event", "event_buy":
			# предложение выпадает со второго раунда и стоит очков — выставляем оба
			opponent = "bot"
			_start_mode("classic")
			await get_tree().create_timer(0.2).timeout
			state["round"] = 2
			state["players"]["p"]["total"] = 200
			var kind := "buy" if _shot_mode == "event_buy" else "swap"
			var offer := []
			for i in 3:
				offer.append(MatchState.random_die(state["rng"]))
			_show_event("p", {"kind": kind, "offer": offer})
			await get_tree().create_timer(0.4).timeout
		"duel_swipe":
			# проверка свайпа без человека: шлём касание, тянем вверх, отпускаем
			opponent = "bot"
			_start_mode("classic")
			await get_tree().create_timer(0.8).timeout
			var at := Vector2(195.0, 700.0)
			_fake_touch(at, true)
			for i in 8:
				at += Vector2(6, -46)
				_fake_drag(at, Vector2(6, -46))
				await get_tree().process_frame
			_fake_touch(at, false)
			await get_tree().create_timer(0.45).timeout
		"duel_hand":
			# куб лежит в руке и ждёт свайпа
			opponent = "bot"
			_start_mode("classic")
			await get_tree().create_timer(0.7).timeout
		"duel_open":
			# момент, когда стаканчики уже поднялись. Битва идёт дольше, чем раньше:
			# каждый бросает по очереди, потом отсчёт — отсюда пять секунд
			opponent = "bot"
			_start_mode("classic")
			await get_tree().create_timer(5.2).timeout
		"roster":
			roster_kinds = ["bot", "bot", "off"]
			_show_roster()
			await get_tree().process_frame
		"durak3":
			# Дуракуб втроём: я и два бота
			opponent = "roster"
			roster_kinds = ["bot", "bot", "off"]
			await _start_durak()
			d_state["shown_to"] = "p"
			busy = false
			_d_refresh()
			await get_tree().create_timer(0.3).timeout
		"three":
			# партия на троих: я и два бота
			opponent = "roster"
			roster_kinds = ["bot", "bot", "off"]
			_start_mode("classic")
			state["board"][0] = {"v": 4, "type": "basic", "owner": "p", "shield": 0}
			state["board"][2] = {"v": 5, "type": "basic", "owner": "e", "shield": 0}
			state["board"][4] = {"v": 3, "type": "basic", "owner": "c", "shield": 0}
			state["shown_to"] = "p"
			busy = false
			_refresh()
			_relayout_soon()
			await get_tree().create_timer(0.2).timeout
		"draft":
			opponent = "bot"
			_show_draft("draft")
			for i in [0, 3, 5, 8, 11, 14]:
				_draft_toggle(i)
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
			_show_result("ПОРАЖЕНИЕ", "Твои жизни кончились.", "Ещё раз", func(): pass)
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
			# ждём фанфару: таблица итогов появляется после неё
			await get_tree().create_timer(2.6).timeout
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

func _label(text: String, size_px: int, col: Color, font_path: String = "",
		align := HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = align
	l.add_theme_font_size_override("font_size", size_px)
	l.add_theme_color_override("font_color", col)
	if font_path != "" and ResourceLoader.exists(font_path):
		l.add_theme_font_override("font", load(font_path))
	return l

## Размер в логических единицах, дающий заданный размер в пикселях экрана.
func _touch(px: float) -> float:
	var vp := get_viewport_rect().size
	var k: float = minf(vp.x / 390.0, vp.y / 844.0)
	if k <= 0.01 or k >= 1.0:
		return px
	return px / k

func _button(text: String, ghost: bool = false) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", 13)
	# 44 и 40 — в ФИЗИЧЕСКИХ пикселях экрана, а не в логических.
	#
	# Игра рисуется в системе 390×844 и растягивается под окно, поэтому на телефоне
	# 360×640 всё уменьшается до 0.76: «Меню» в 40 логических превращалось в 29
	# настоящих, вдвое меньше нормы Android. Делим на масштаб холста и получаем
	# кнопку, которая на любом экране остаётся размером с палец.
	b.custom_minimum_size.y = _touch(44.0 if not ghost else 40.0)
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

## bone/blood — чей куб стоит в клетке: под ним зажигается свет своего цвета.
## Плоская сетка одинаковых клеток читалась как таблица, а не как поле боя.
func _cell_box(valid: bool, has_die: bool, hinted: bool = false, owner_seat: String = "") -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Palette.CELL
	sb.set_corner_radius_all(12)
	# тонкая рамка у свободной клетки и толстая у подсвеченной: раньше все клетки
	# были обведены одинаково жирно и доска читалась как сетка, а не как поле
	sb.set_border_width_all(2)
	sb.border_color = Palette.CELL_EDGE
	if valid:
		sb.border_color = Palette.DANGER if has_die else Palette.GOLD
	if has_die and owner_seat != "" and not hinted:
		# свет из-под куба: костяной тёплый, кровавый багровый
		var glow := Color(1.0, 0.9, 0.62, 0.28) if owner_seat == "p" else Color(1.0, 0.35, 0.4, 0.26)
		sb.shadow_color = glow
		sb.shadow_size = 10
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
		if bool(part.get("die", false)):
			# Значение куба, а не очки. Золотая цифра здесь ломала главный контракт
			# карточки: игрок складывал золотые числа и получал больше, чем итог
			# хода, потому что «Дружески перенял 7» в сумму не входит. Рисуем как в
			# вебе — цифрой в костяном мини-кубике.
			row.add_child(_dval(int(part["v"])))
			row.add_child(_label(str(int(part.get("pts", 0))), 12, Palette.GOLD_LIGHT))
		else:
			row.add_child(_label(str(int(part["v"])), 12, Palette.NEG if neg else Palette.GOLD_LIGHT))
	return box

## Мини-кубик со значением: отличает «значение куба» от «очки».
func _dval(v: int) -> Control:
	var box := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Palette.BONE
	sb.set_corner_radius_all(4)
	sb.content_margin_left = 5
	sb.content_margin_right = 5
	sb.content_margin_top = 1
	sb.content_margin_bottom = 1
	box.add_theme_stylebox_override("panel", sb)
	box.add_child(_label(str(v), 11, Palette.BONE_INK, Palette.FONT_UI))
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
