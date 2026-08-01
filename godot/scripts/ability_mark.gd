class_name AbilityMark
extends Control

## Значок способности на грани куба, нарисованный вручную.
##
## Сгенерированные картинки годятся для экрана правил, где они по 44 px, но на
## кубе значок выходит 24–30 px: рукопожатие превращалось в палочку, сфера
## колдуна — в мутное пятно. Системные эмодзи не годятся тем же, чем не годились
## для мастей: они игнорируют цвет и на разных телефонах выглядят по-разному.
##
## Поэтому здесь простые силуэты, читаемые в мелком размере. Форма повторяет
## картинку из правил настолько, чтобы игрок узнал: щит, шипастый шар, бомба,
## зубастая пасть, союз, магическая сфера.

var kind := "basic"
var color := Color.BLACK

func setup(type_id: String, of_color: Color) -> void:
	kind = type_id
	color = of_color
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	queue_redraw()

func _draw() -> void:
	var r: float = minf(size.x, size.y)
	if r <= 0.0:
		return
	var off := Vector2((size.x - r) * 0.5, (size.y - r) * 0.5)
	match kind:
		"shield": _shield(off, r)
		"spikes": _spikes(off, r)
		"mine": _mine(off, r)
		"jaw": _jaw(off, r)
		"friendly": _friendly(off, r)
		"warlock": _warlock(off, r)

func _p(off: Vector2, r: float, x: float, y: float) -> Vector2:
	return off + Vector2(x * r, y * r)

func _poly(off: Vector2, r: float, pts: Array, col: Color) -> void:
	var out := PackedVector2Array()
	for pt in pts:
		out.append(_p(off, r, pt[0], pt[1]))
	draw_colored_polygon(out, col)

## Геральдический щит: прямой верх, сужение к острию.
func _shield(off: Vector2, r: float) -> void:
	_poly(off, r, [[0.12, 0.12], [0.88, 0.12], [0.88, 0.5], [0.5, 0.95], [0.12, 0.5]], color)

## Шипастый шар: круг и восемь треугольных шипов.
func _spikes(off: Vector2, r: float) -> void:
	var mid := _p(off, r, 0.5, 0.5)
	for i in 8:
		var a: float = PI * 2.0 * float(i) / 8.0
		var dir := Vector2(cos(a), sin(a))
		var side := Vector2(-dir.y, dir.x)
		draw_colored_polygon(PackedVector2Array([
			mid + dir * r * 0.48,
			mid + dir * r * 0.26 + side * r * 0.12,
			mid + dir * r * 0.26 - side * r * 0.12,
		]), color)
	draw_circle(mid, r * 0.29, color)

## Бомба: шар и фитиль.
func _mine(off: Vector2, r: float) -> void:
	draw_circle(_p(off, r, 0.46, 0.6), r * 0.33, color)
	_poly(off, r, [[0.56, 0.3], [0.72, 0.3], [0.72, 0.38], [0.56, 0.38]], color)
	draw_line(_p(off, r, 0.7, 0.3), _p(off, r, 0.88, 0.12), color, maxf(1.5, r * 0.08))

## Зубастая пасть: две челюсти с треугольными зубами.
func _jaw(off: Vector2, r: float) -> void:
	_poly(off, r, [[0.08, 0.3], [0.92, 0.3], [0.92, 0.4], [0.08, 0.4]], color)
	_poly(off, r, [[0.08, 0.72], [0.92, 0.72], [0.92, 0.62], [0.08, 0.62]], color)
	for i in 4:
		var x: float = 0.14 + 0.21 * float(i)
		_poly(off, r, [[x, 0.4], [x + 0.14, 0.4], [x + 0.07, 0.56]], color)
		_poly(off, r, [[x, 0.62], [x + 0.14, 0.62], [x + 0.07, 0.46]], color)

## Союз: два сцепленных кольца — «прибавляет от соседей».
func _friendly(off: Vector2, r: float) -> void:
	var w := maxf(2.0, r * 0.12)
	draw_arc(_p(off, r, 0.36, 0.5), r * 0.27, 0.0, TAU, 24, color, w)
	draw_arc(_p(off, r, 0.64, 0.5), r * 0.27, 0.0, TAU, 24, color, w)

## Магическая сфера: круг с бликом и искрой.
func _warlock(off: Vector2, r: float) -> void:
	draw_arc(_p(off, r, 0.5, 0.54), r * 0.34, 0.0, TAU, 28, color, maxf(2.0, r * 0.13))
	draw_circle(_p(off, r, 0.39, 0.44), r * 0.08, color)
	_poly(off, r, [[0.78, 0.06], [0.84, 0.2], [0.98, 0.26], [0.84, 0.32], [0.78, 0.46],
		[0.72, 0.32], [0.58, 0.26], [0.72, 0.2]], color)
