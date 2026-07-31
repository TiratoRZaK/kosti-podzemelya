shader_type canvas_item;

// Грань куба одним проходом: скруглённый прямоугольник, вертикальный градиент,
// верхний блик, внутренняя тень снизу, кромка и свечение.
//
// Через StyleBoxFlat это не собрать — он не умеет градиент, а объём у куба
// главное: он центральный элемент интерфейса. Шейдер ещё и даёт свечение
// «изнутри», которое со спрайтом пришлось бы запекать заранее.

uniform vec4 face_top : source_color = vec4(1.0, 0.96, 0.85, 1.0);
uniform vec4 face_mid : source_color = vec4(0.92, 0.85, 0.71, 1.0);
uniform vec4 face_bot : source_color = vec4(0.80, 0.72, 0.54, 1.0);
uniform vec4 edge_col : source_color = vec4(0.69, 0.60, 0.43, 1.0);
uniform vec4 deep_col : source_color = vec4(0.49, 0.42, 0.28, 1.0);
uniform vec4 glow_col : source_color = vec4(1.0, 0.86, 0.45, 1.0);

uniform float radius : hint_range(0.0, 0.5) = 0.17;   // доля от меньшей стороны
uniform float thickness : hint_range(0.0, 0.3) = 0.10; // «толщина» кости снизу
uniform float edge_w : hint_range(0.0, 0.1) = 0.022;
uniform float glow : hint_range(0.0, 1.0) = 0.0;       // вспышка при отдаче очков
uniform float select : hint_range(0.0, 1.0) = 0.0;     // подсветка выбранного
uniform float shielded : hint_range(0.0, 1.0) = 0.0;   // куб под щитом — его не съесть
uniform vec4 shield_col : source_color = vec4(0.38, 0.76, 0.79, 1.0);
uniform vec2 rect_size = vec2(74.0, 74.0);

// расстояние до скруглённого прямоугольника: <0 внутри, >0 снаружи
float rounded_box(vec2 p, vec2 half_size, float r) {
	vec2 q = abs(p) - half_size + vec2(r);
	return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - r;
}

void fragment() {
	vec2 px = UV * rect_size;
	float short_side = min(rect_size.x, rect_size.y);
	float r = radius * short_side;
	float thick = thickness * rect_size.y;

	// нижняя плашка — она и создаёт ощущение толщины
	vec2 deep_half = vec2(rect_size.x, rect_size.y - thick) * 0.5;
	vec2 deep_p = px - vec2(rect_size.x * 0.5, thick + deep_half.y);
	float d_deep = rounded_box(deep_p, deep_half, r);

	// лицо
	vec2 face_half = vec2(rect_size.x, rect_size.y - thick) * 0.5;
	vec2 face_p = px - vec2(rect_size.x * 0.5, face_half.y);
	float d_face = rounded_box(face_p, face_half, r);

	float aa = 1.2;
	float a_deep = 1.0 - smoothstep(0.0, aa, d_deep);
	float a_face = 1.0 - smoothstep(0.0, aa, d_face);

	// вертикальный градиент лица: сверху светлее
	float t = clamp((px.y - 0.0) / max(face_half.y * 2.0, 1.0), 0.0, 1.0);
	vec3 face = mix(face_top.rgb, face_mid.rgb, smoothstep(0.0, 0.55, t));
	face = mix(face, face_bot.rgb, smoothstep(0.5, 1.0, t));

	// блик сверху — узкая светлая полоса, повторяет скругление
	float hi = 1.0 - smoothstep(0.0, face_half.y * 0.42, px.y);
	face += vec3(0.16) * hi;

	// внутренняя тень у нижней кромки лица
	float sh = smoothstep(face_half.y * 1.45, face_half.y * 2.0, px.y);
	face -= vec3(0.10) * sh;

	// кромка
	float edge_band = smoothstep(-edge_w * short_side, 0.0, d_face);
	vec3 col = mix(face, edge_col.rgb, edge_band);

	// свечение: изнутри к центру, плюс ореол при выборе
	col += glow_col.rgb * glow * (0.55 + 0.45 * (1.0 - smoothstep(0.0, face_half.y, length(face_p))));
	float halo = (1.0 - smoothstep(0.0, 6.0, abs(d_face))) * select;

	float alpha = max(a_face, a_deep);
	vec3 out_rgb = mix(deep_col.rgb, col, a_face);

	// Щит: мягкое свечение внутрь от края грани, без всякой линии. Обводка по
	// контуру выглядела наклеенной рамкой — сколько её ни утончай, она читается
	// как чужеродная деталь. Сам знак щита рисует иконка поверх куба.
	float d_all = min(d_face, d_deep);
	float a_all = 1.0 - smoothstep(0.0, aa, d_all);
	// узкая полоса у самого края и слабо: при широкой ауре костяной куб зеленел,
	// а кровавый отдавал бирюзой — цвет владельца важнее подсветки
	float aura = (1.0 - smoothstep(0.0, short_side * 0.14, abs(d_all))) * a_all;
	out_rgb = mix(out_rgb, shield_col.rgb, pow(aura, 1.4) * shielded * 0.3);

	out_rgb = mix(out_rgb, glow_col.rgb, halo * 0.75);
	alpha = max(alpha, halo);

	COLOR = vec4(out_rgb, alpha * COLOR.a);
}
