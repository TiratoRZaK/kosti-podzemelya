class_name SuitMark
extends Control

## Значок масти, нарисованный вручную.
##
## В шрифтах проекта (Manrope, Ruslan Display) глифов ♠♥♦♣ нет — проверено
## has_char, все четыре false. Системный fallback подставляет цветные emoji, а
## они игнорируют цвет текста: козырь перестаёт быть золотым, а ♣ на зелёном
## кубе становится фиолетовым. Плюс на Android набор системных шрифтов другой,
## и вид поехал бы ещё раз. Фигуры рисуем сами — цвет любой, вид одинаковый
## везде.
##
## Порядок мастей совпадает с Durak.SUITS: ♠ ♥ ♦ ♣.

var suit := 0
var color := Color.WHITE

func setup(s: int, c: Color) -> void:
	suit = s
	color = c
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	queue_redraw()

func _draw() -> void:
	var r: float = minf(size.x, size.y)
	if r <= 0.0:
		return
	var off := Vector2((size.x - r) * 0.5, (size.y - r) * 0.5)
	match suit:
		0: _spade(off, r)
		1: _heart(off, r)
		2: _diamond(off, r)
		_: _club(off, r)

## Точка в долях от размера значка: рисуем в единичном квадрате.
func _p(off: Vector2, r: float, x: float, y: float) -> Vector2:
	return off + Vector2(x * r, y * r)

func _poly(off: Vector2, r: float, pts: Array) -> void:
	var out := PackedVector2Array()
	for pt in pts:
		out.append(_p(off, r, pt[0], pt[1]))
	draw_colored_polygon(out, color)

func _diamond(off: Vector2, r: float) -> void:
	_poly(off, r, [[0.5, 0.04], [0.9, 0.5], [0.5, 0.96], [0.1, 0.5]])

func _heart(off: Vector2, r: float) -> void:
	draw_circle(_p(off, r, 0.3, 0.33), r * 0.235, color)
	draw_circle(_p(off, r, 0.7, 0.33), r * 0.235, color)
	_poly(off, r, [[0.075, 0.42], [0.925, 0.42], [0.5, 0.95]])

func _spade(off: Vector2, r: float) -> void:
	_poly(off, r, [[0.5, 0.05], [0.95, 0.62], [0.05, 0.62]])
	draw_circle(_p(off, r, 0.27, 0.6), r * 0.26, color)
	draw_circle(_p(off, r, 0.73, 0.6), r * 0.26, color)
	_poly(off, r, [[0.38, 0.99], [0.62, 0.99], [0.55, 0.68], [0.45, 0.68]])

func _club(off: Vector2, r: float) -> void:
	draw_circle(_p(off, r, 0.5, 0.27), r * 0.245, color)
	draw_circle(_p(off, r, 0.25, 0.62), r * 0.245, color)
	draw_circle(_p(off, r, 0.75, 0.62), r * 0.245, color)
	_poly(off, r, [[0.38, 0.99], [0.62, 0.99], [0.56, 0.6], [0.44, 0.6]])
