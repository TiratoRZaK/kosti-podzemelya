class_name CupView
extends Control

## Перевёрнутый стаканчик, которым накрывают брошенный куб.
##
## Рисуется вручную по той же причине, что масти и сердца: любой готовый глиф
## тянет за собой чужой стиль и цвет, а тут нужен предмет из того же подземелья —
## тёмная кость с золотой каймой.
##
## Форма: трапеция, расширяющаяся книзу (стакан стоит вверх дном), сверху донце
## эллипсом, по низу — тень на стол.

var body := Color("2a2036")
var edge := Color("d9a13c")
var top := Color("3a2c4c")

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _draw() -> void:
	var w := size.x
	var h := size.y
	if w <= 0.0 or h <= 0.0:
		return
	# тень под стаканом: без неё он висит в воздухе
	draw_circle(Vector2(w * 0.5, h * 0.94), w * 0.42, Color(0, 0, 0, 0.35))

	var top_w := w * 0.62      # донце уже основания: стакан сужается кверху
	var body_pts := PackedVector2Array([
		Vector2((w - top_w) * 0.5, h * 0.16),
		Vector2((w + top_w) * 0.5, h * 0.16),
		Vector2(w * 0.94, h * 0.9),
		Vector2(w * 0.06, h * 0.9),
	])
	draw_colored_polygon(body_pts, body)
	# блик по левой грани — стакан перестаёт быть плоским пятном
	draw_colored_polygon(PackedVector2Array([
		Vector2((w - top_w) * 0.5, h * 0.16),
		Vector2((w - top_w) * 0.5 + w * 0.1, h * 0.16),
		Vector2(w * 0.2, h * 0.9),
		Vector2(w * 0.06, h * 0.9),
	]), Color(1, 1, 1, 0.06))
	draw_polyline(body_pts + PackedVector2Array([body_pts[0]]), edge, maxf(2.0, w * 0.03))

	# донце
	var cap := Rect2(Vector2((w - top_w) * 0.5, h * 0.06), Vector2(top_w, h * 0.2))
	draw_ellipse_filled(cap, top)
	draw_ellipse_outline(cap, edge, maxf(2.0, w * 0.03))

func draw_ellipse_filled(r: Rect2, col: Color) -> void:
	var pts := PackedVector2Array()
	for i in 28:
		var a := TAU * float(i) / 28.0
		pts.append(r.position + r.size * 0.5 + Vector2(cos(a) * r.size.x * 0.5, sin(a) * r.size.y * 0.5))
	draw_colored_polygon(pts, col)

func draw_ellipse_outline(r: Rect2, col: Color, width: float) -> void:
	var pts := PackedVector2Array()
	for i in 29:
		var a := TAU * float(i % 28) / 28.0
		pts.append(r.position + r.size * 0.5 + Vector2(cos(a) * r.size.x * 0.5, sin(a) * r.size.y * 0.5))
	draw_polyline(pts, col, width)
