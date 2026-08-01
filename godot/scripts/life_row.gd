class_name LifeRow
extends Control

## Ряд жизней или побед: сердца в боевых режимах, звёзды в режимах до трёх побед.
##
## Рисуем сами по той же причине, что и масти: системный шрифт подставляет на
## ♥ и ★ цветные эмодзи, которые игнорируют заданный цвет. Сердца выходили
## розовыми `#ff3f67` вместо кровавого `DANGER` и были самым чужим цветом на
## экране, а на другом телефоне набор эмодзи мог оказаться совсем иным.

const KIND_HEART := "heart"
const KIND_STAR := "star"

var total := 3
var filled := 3
var kind := KIND_HEART
var color := Palette.DANGER

func setup(total_count: int, filled_count: int, of_kind: String = KIND_HEART,
		of_color: Color = Palette.DANGER) -> void:
	total = total_count
	filled = filled_count
	kind = of_kind
	color = of_color
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(_step() * total, size_hint())
	queue_redraw()

func size_hint() -> float:
	return 16.0

func _step() -> float:
	return size_hint() * 1.15

func _draw() -> void:
	var s := size_hint()
	for i in total:
		var at := Vector2(_step() * i, (size.y - s) * 0.5)
		# погашенное — тёмный контур того же силуэта: видно, сколько было всего
		var col := color if i < filled else Color(0.28, 0.2, 0.36, 0.85)
		if kind == KIND_STAR:
			_star(at, s, col)
		else:
			_heart(at, s, col)

func _heart(at: Vector2, s: float, col: Color) -> void:
	draw_circle(at + Vector2(s * 0.3, s * 0.34), s * 0.235, col)
	draw_circle(at + Vector2(s * 0.7, s * 0.34), s * 0.235, col)
	var tri := PackedVector2Array([
		at + Vector2(s * 0.075, s * 0.42),
		at + Vector2(s * 0.925, s * 0.42),
		at + Vector2(s * 0.5, s * 0.95),
	])
	draw_colored_polygon(tri, col)

func _star(at: Vector2, s: float, col: Color) -> void:
	var mid := at + Vector2(s * 0.5, s * 0.52)
	var pts := PackedVector2Array()
	for i in 10:
		# вершины и впадины чередуются — получается пятиконечная звезда
		var r: float = s * (0.5 if i % 2 == 0 else 0.21)
		var a: float = -PI * 0.5 + PI * float(i) / 5.0
		pts.append(mid + Vector2(cos(a), sin(a)) * r)
	draw_colored_polygon(pts, col)
