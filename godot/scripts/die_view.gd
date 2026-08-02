class_name DieView
extends Control

## Куб: грань рисует шейдер (`assets/shaders/die.gdshader`), значение и значок —
## обычные Label поверх. Никаких картинок: куб масштабируется под любой экран,
## перекрашивается параметрами и умеет светиться изнутри.
##
## Оформление повторяет веб-версию: объём даёт «толщина» снизу, тип способности —
## мелкий значок в углу. Арт на всю грань пробовали, его забраковали.

signal pressed(die_view: DieView)

const SHADER_PATH := "res://assets/shaders/die.gdshader"
## Щит рисуем картинкой, а не эмодзи и не рамкой: рамка по контуру куба читалась
## как наклеенная деталь, а мелкий значок 🛡 в углу терялся.
## Все способности показываются одним и тем же значком в углу грани — так было
## изначально и так владельцу нравится. Рисованные пиктограммы и картинку щита
## забраковали: «это ужас, верни».

var value: int = 1
var type_id: String = "basic"
var seat_index: int = 0     # 0 кость, 1 кровь, 2 мох, 3 лазурь
var show_badge: bool = true      # скрытый тип чужого куба значка не получает
var shield_charges: int = 0

## Куб перехватывает тапы только когда по нему действительно можно нажать.
## Иначе куб на доске съедал тап, предназначенный клетке под ним, и нажималась
## лишь тонкая рамка вокруг — казалось, что «мало мест, куда ткнуть».
var clickable: bool = false:
	set(v):
		clickable = v
		mouse_filter = Control.MOUSE_FILTER_STOP if v else Control.MOUSE_FILTER_IGNORE

var _face: ColorRect
var _mat: ShaderMaterial
var _value_label: Label
var _badge_label: Label
var _pips: Control

func _ready() -> void:
	# mouse_filter здесь не задаём: им управляет clickable, и жёсткая установка
	# перетирала IGNORE, выставленный до добавления в дерево
	_build()
	resized.connect(_sync_size)

func _build() -> void:
	_mat = ShaderMaterial.new()
	_mat.shader = load(SHADER_PATH)
	_face = ColorRect.new()
	_face.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_face.material = _mat
	_face.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_face)

	_value_label = Label.new()
	_value_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_value_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_value_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if ResourceLoader.exists(Palette.FONT_UI):
		_value_label.add_theme_font_override("font", load(Palette.FONT_UI))
	add_child(_value_label)

	# значок типа с тёмной подложкой в углу, иначе он теряется на светлой грани
	_badge_label = Label.new()
	_badge_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_badge_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	_badge_label.add_theme_constant_override("shadow_offset_x", 1)
	_badge_label.add_theme_constant_override("shadow_offset_y", 1)
	add_child(_badge_label)

	_pips = Control.new()
	_pips.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_pips)
	_pips.draw.connect(_draw_pips)

	_apply()
	_sync_size()

func setup(v: int, t: String, player: bool, badge: bool, shield: int = 0, seat_no: int = -1) -> void:
	value = v
	type_id = t
	# player оставлен для вызовов на двоих: там кость против крови
	seat_index = seat_no if seat_no >= 0 else (0 if player else 1)
	show_badge = badge
	shield_charges = shield
	if is_inside_tree() and _mat != null:
		_apply()
		_sync_size()

func _apply() -> void:
	var f := Palette.face_of(seat_index)
	_mat.set_shader_parameter("face_top", f["top"])
	_mat.set_shader_parameter("face_mid", f["mid"])
	_mat.set_shader_parameter("face_bot", f["bottom"])
	_mat.set_shader_parameter("edge_col", f["edge"])
	_mat.set_shader_parameter("deep_col", f["deep"])
	_mat.set_shader_parameter("glow_col", Palette.GOLD_LIGHT)
	_mat.set_shader_parameter("shield_col", Palette.CYAN)
	_mat.set_shader_parameter("shielded", 1.0 if shield_charges > 0 else 0.0)
	_value_label.text = str(value)
	_value_label.add_theme_color_override("font_color", f["ink"])
	_badge_label.text = String(Rules.TYPES[type_id]["icon"]) if show_badge else ""
	_pips.queue_redraw()

func _sync_size() -> void:
	if _mat == null:
		return
	_mat.set_shader_parameter("rect_size", size)
	var fs := int(size.y * 0.44)
	_value_label.add_theme_font_size_override("font_size", fs)
	# значение сдвинуто вверх на половину «толщины»: центр лица выше центра куба
	_value_label.offset_bottom = -size.y * 0.10
	var bs := int(size.y * 0.2)
	_badge_label.add_theme_font_size_override("font_size", bs)
	_badge_label.position = Vector2(size.x - bs * 1.35, size.y * 0.06)
	# щит крупный, в правом верхнем углу грани: он должен читаться и на мелком
	# кубе в руке, поэтому занимает больше места, чем эмодзи-значок
	_pips.position = Vector2.ZERO
	_pips.size = size
	_pips.queue_redraw()

func _gui_input(event: InputEvent) -> void:
	if not clickable:
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		pressed.emit(self)
		# отклик на касание важнее самой анимации: без него нажатие «не чувствуется»
		var tw := create_tween()
		tw.tween_property(self, "scale", Vector2(0.94, 0.94), 0.06)
		tw.tween_property(self, "scale", Vector2.ONE, 0.10).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)

## Выбранный куб приподнимается и обводится золотом.
func set_selected(on: bool) -> void:
	var tw := create_tween().set_parallel(true)
	tw.tween_property(self, "position:y", -10.0 if on else 0.0, 0.14).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_method(_set_shader_float.bind("select"), _get_param("select"), 1.0 if on else 0.0, 0.14)

## Куб «выскакивает» при постановке на доску.
func play_place() -> void:
	scale = Vector2(0.55, 0.55)
	pivot_offset = size * 0.5
	var tw := create_tween()
	tw.tween_property(self, "scale", Vector2(1.10, 1.10), 0.14).set_ease(Tween.EASE_OUT)
	tw.tween_property(self, "scale", Vector2.ONE, 0.12).set_trans(Tween.TRANS_BACK)

## Подсказка: куб мягко пульсирует, пока игрок не сделал свой выбор.
func play_hint() -> void:
	var tw := create_tween().set_loops()
	tw.tween_method(_set_shader_float.bind("select"), 0.15, 0.75, 0.6).set_trans(Tween.TRANS_SINE)
	tw.tween_method(_set_shader_float.bind("select"), 0.75, 0.15, 0.6).set_trans(Tween.TRANS_SINE)

## Вспышка: куб отдал очки в карточку хода.
func play_glow() -> void:
	var tw := create_tween()
	tw.tween_method(_set_shader_float.bind("glow"), 0.0, 0.85, 0.16)
	tw.tween_method(_set_shader_float.bind("glow"), 0.85, 0.0, 0.5)

func _set_shader_float(v: float, param: String) -> void:
	if _mat != null:
		_mat.set_shader_parameter(param, v)

func _get_param(param: String) -> float:
	if _mat == null:
		return 0.0
	var v = _mat.get_shader_parameter(param)
	return 0.0 if v == null else float(v)

## Заряды щита — точки под его знаком: сколько ходов соперника он ещё держит.
## Прежние полоски сверху ставились отдельно от щита и читались как царапины.
func _draw_pips() -> void:
	if shield_charges <= 0 and type_id != "shield":
		return
	var r := maxf(2.0, size.y * 0.032)
	var gap := r * 2.6
	var total := gap * (Rules.SHIELD_CHARGES - 1)
	# заряды под значком щита в правом верхнем углу
	var badge := size.y * 0.2
	var cx := size.x - badge * 0.68
	var cy := size.y * 0.06 + badge * 1.5
	for i in Rules.SHIELD_CHARGES:
		var col := Palette.CYAN
		if i >= shield_charges:
			col = Color(0.16, 0.11, 0.2, 0.75)     # погашенный: тёмная лунка, а не блёклая точка
		var at := Vector2(cx - total * 0.5 + gap * i, cy)
		# тёмная обводка: бирюза на костяной грани давала контраст 1.48:1 и точки
		# сливались с кубом — сосчитать заряды было нельзя
		_pips.draw_circle(at, r + maxf(1.5, r * 0.5), Color(0.04, 0.02, 0.07, 0.9))
		_pips.draw_circle(at, r, col)
