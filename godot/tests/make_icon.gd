extends SceneTree

## Иконка приложения: костяной куб с золотой рамкой на тёмном фоне подземелья.
## Рисуем попиксельно, чтобы не тащить в репозиторий внешний редактор.

const N := 512

func _init() -> void:
	var img := Image.create(N, N, false, Image.FORMAT_RGBA8)
	var bg_top := Color("2a1c3e")
	var bg_bot := Color("0e0a14")
	var bone := Color("ead9b6")
	var bone_hi := Color("fff5da")
	var edge := Color("d9a13c")
	var ink := Color("2b2114")
	var half := N * 0.5
	var box := 150.0        # полуразмер куба
	var rad := 42.0         # скругление
	for y in N:
		for x in N:
			var p := Vector2(x - half, y - half)
			# фон: вертикальный градиент плюс лёгкое пятно света сверху
			var t: float = clampf(float(y) / float(N), 0.0, 1.0)
			var col := bg_top.lerp(bg_bot, t)
			var glow: float = clampf(1.0 - p.length() / (N * 0.62), 0.0, 1.0)
			col = col.lerp(Color("4a2f6b"), glow * 0.45)
			# SDF скруглённого квадрата: <0 внутри куба
			var q := Vector2(absf(p.x), absf(p.y)) - Vector2(box - rad, box - rad)
			var d: float = Vector2(maxf(q.x, 0.0), maxf(q.y, 0.0)).length() + minf(maxf(q.x, q.y), 0.0) - rad
			if d < 0.0:
				# лицо куба: сверху светлее
				var f: float = clampf((p.y + box) / (box * 2.0), 0.0, 1.0)
				col = bone_hi.lerp(bone, f)
				if d > -12.0:
					col = edge          # золотая рамка по контуру
				# пипсы «пятёрки»
				var step := 78.0
				for pip in [Vector2(-step, -step), Vector2(step, -step), Vector2(0, 0),
						Vector2(-step, step), Vector2(step, step)]:
					if p.distance_to(pip) < 26.0:
						col = ink
			img.set_pixel(x, y, col)
	img.save_png("res://assets/icon.png")
	print("иконка: assets/icon.png")
	quit()
