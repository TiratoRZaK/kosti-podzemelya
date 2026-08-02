extends SceneTree

## Проверка переноса правил. Сценарии те же, что в харнессе веб-прототипа
## (`tools/repro.js`), с теми же ожидаемыми числами — веб-версия остаётся
## эталоном. Если здесь другой итог хода, значит перенос сломал правило.
##
## Запуск:
##   Godot_v4.7.1-stable_win64_console.exe --headless --path godot --script tests/test_rules.gd

var fails := 0

func _init() -> void:
	print("")
	print("--- контракт «сумма жетонов = итог хода» ---")
	print("")
	scenario("челюсть съела шипы + справа мина -> ход сгорает в 0", 0, 50, func(s):
		s["board"][1] = die_on(3, "spikes", "e")
		s["board"][2] = die_on(5, "mine", "e")
		s["players"]["p"]["hand"][0] = {"value": 6, "type": "jaw"}
		return 1)
	scenario("обычный ход: съел 2, поле 8, пара 5", 15, 0, func(s):
		s["board"][0] = die_on(2, "basic", "e")
		s["board"][3] = die_on(4, "basic", "p")
		s["players"]["p"]["hand"][0] = {"value": 4, "type": "basic"}
		return 0)
	scenario("съел шипы: 3 + поле 5 - укол 10", -2, 50, func(s):
		s["board"][0] = die_on(3, "spikes", "e")
		s["players"]["p"]["hand"][0] = {"value": 5, "type": "basic"}
		return 0)
	scenario("челюсть: съел 3, пережевала 2, поле 6, укол 10", 1, 50, func(s):
		s["board"][1] = die_on(3, "spikes", "e")
		s["board"][2] = die_on(2, "basic", "e")
		s["players"]["p"]["hand"][0] = {"value": 6, "type": "jaw"}
		return 1)
	scenario("прямая атака на мину -> 0", 0, 50, func(s):
		s["board"][0] = die_on(4, "mine", "e")
		s["players"]["p"]["hand"][0] = {"value": 6, "type": "basic"}
		return 0)
	scenario("колдун съел 6 и стал шестёркой", 12, 0, func(s):
		s["board"][0] = die_on(6, "basic", "e")
		s["players"]["p"]["hand"][0] = {"value": 1, "type": "warlock"}
		return 0)

	print("")
	print("--- комбинации ---")
	print("")
	combo_case([4, 4], 5, "ПАРА")
	combo_case([4, 4, 5, 5], 10, "ДВЕ ПАРЫ")
	combo_case([4, 4, 4], 15, "СЕТ!")
	combo_case([5, 5, 5, 4, 4], 25, "ФУЛЛ-ХАУС!")
	combo_case([2, 2, 2, 2], 40, "КАРЕ!")
	combo_case([3, 3, 3, 3, 3], 60, "ПЯТЁРКА!")
	combo_case([6, 6, 6, 6, 6, 6], 100, "ШЕСТЁРКА!")
	combo_case([1, 2, 3], 10, "ЛЕСЕНКА")     # с появлением лесенки это уже комбинация
	combo_case([1, 3, 5], 0, "")             # вразнобой — по-прежнему ничего

	print("")
	print("--- щит и легальность ---")
	print("")
	shield_case()
	spikes_visible_case()

	print("")
	print("--- лесенка ---")
	print("")
	run_case()

	print("")
	if fails > 0:
		print("ПРОВАЛОВ: %d" % fails)
	else:
		print("ВСЕ ПРОВЕРКИ ПРОЙДЕНЫ")
	print("")
	quit(1 if fails > 0 else 0)

# ------------------------------------------------------------- вспомогательное

func die_on(v: int, type: String, seat: String) -> Dictionary:
	return {"v": v, "type": type, "owner": seat, "shield": Rules.SHIELD_CHARGES if type == "shield" else 0}

func fresh_state(start_score: int) -> Dictionary:
	var board := []
	for i in 6:
		board.append(null)
	return {
		"board": board, "cols": 3,
		"players": {
			"p": {"hand": [{"value": 1, "type": "basic"}], "deck": [], "score": start_score, "moves": 0},
			"e": {"hand": [], "deck": [], "score": 0, "moves": 0},
		},
	}

func scenario(name: String, expect_pts: int, start_score: int, setup: Callable) -> void:
	var s := fresh_state(start_score)
	var cell: int = setup.call(s)
	var res := Rules.apply_move(s, "p", 0, cell)
	var shown := 0 if res["mined"] else Rules.chip_sum(res["parts"])
	var ok_pts: bool = int(res["pts"]) == expect_pts
	var ok_sum: bool = shown == int(res["pts"])
	if not (ok_pts and ok_sum):
		fails += 1
	print("%s%s" % ["  OK  " if ok_pts and ok_sum else " FAIL ", name])
	var names := []
	for p in res["parts"]:
		var val := ""
		if p.has("v"):
			val = " %s%d" % ["-" if p.get("neg", false) else "+", int(p["v"])]
		names.append(String(p["t"]) + val)
	print("        итог=%d (ожидание %d) | в карточке=%d%s | счёт=%d" % [
		int(res["pts"]), expect_pts, shown,
		" (mined)" if res["mined"] else "", int(s["players"]["p"]["score"])])
	print("        жетоны: %s" % " | ".join(names))

func combo_case(vals: Array, expect_bonus: int, expect_name: String) -> void:
	var cb := Rules.combo_bonus(vals)
	var ok: bool = int(cb["bonus"]) == expect_bonus and String(cb["name"]) == expect_name
	if not ok:
		fails += 1
	print("%s%s -> %d %s" % [
		"  OK  " if ok else " FAIL ", str(vals), int(cb["bonus"]), String(cb["name"])])

func shield_case() -> void:
	var s := fresh_state(0)
	s["board"][0] = die_on(1, "basic", "e")
	s["board"][0]["shield"] = 2
	var warlock := {"value": 1, "type": "warlock"}
	var six := {"value": 6, "type": "basic"}
	var t_warlock := Rules.legal_targets(s["board"], warlock, "p")
	var t_six := Rules.legal_targets(s["board"], six, "p")
	var ok: bool = not t_warlock.has(0) and not t_six.has(0) and t_warlock.has(1)
	if not ok:
		fails += 1
	print("%sщит держит и колдуна, и шестёрку" % ["  OK  " if ok else " FAIL "])
	print("        колдун -> %s | шестёрка -> %s" % [str(t_warlock), str(t_six)])

func spikes_visible_case() -> void:
	# Скрыта осталась одна мина. Шипы открыли: пока они были скрыты, решение не
	# менялось — незнакомый куб оказывался базовым в трёх случаях из четырёх, и
	# правильный ответ всегда был «ешь», росла только дисперсия. Открытые шипы —
	# это выбор «стоит ли эта клетка десяти очков».
	var ok: bool = Rules.TYPES["mine"]["hidden"] and not Rules.TYPES["spikes"]["hidden"] \
		and not Rules.TYPES["shield"]["hidden"] and not Rules.TYPES["jaw"]["hidden"]
	if not ok:
		fails += 1
	print("%sскрытой осталась только мина, шипы видны" % ["  OK  " if ok else " FAIL "])

## Лесенка не должна перебивать то, что дороже её, и обязана считаться там, где
## одинаковых кубов нет вовсе.
func run_case() -> void:
	var cases := [
		{"vals": [2, 3, 4], "bonus": 10, "name": "ЛЕСЕНКА"},
		{"vals": [1, 2, 3, 4], "bonus": 20, "name": "ЛЕСЕНКА!"},
		{"vals": [2, 3, 4, 5, 6], "bonus": 35, "name": "ЛЕСЕНКА!"},
		{"vals": [1, 3, 5], "bonus": 0, "name": ""},                  # не подряд
		{"vals": [4, 4, 5, 6], "bonus": 10, "name": "ЛЕСЕНКА"},       # лесенка дороже пары
		{"vals": [5, 5, 4, 4], "bonus": 10, "name": "ДВЕ ПАРЫ"},      # две пары не хуже
		{"vals": [5, 5, 5, 4, 4], "bonus": 25, "name": "ФУЛЛ-ХАУС!"}, # фулл-хаус сильнее
		{"vals": [6, 6, 6, 6], "bonus": 40, "name": "КАРЕ!"},         # каре сильнее
		{"vals": [3, 3], "bonus": 5, "name": "ПАРА"},                 # пара как была
	]
	var ok := true
	var detail := ""
	for c in cases:
		var got := Rules.combo_bonus(c["vals"])
		if int(got["bonus"]) != int(c["bonus"]) or String(got["name"]) != String(c["name"]):
			ok = false
			detail += "%s → %s %d (ждали %s %d); " % [str(c["vals"]), String(got["name"]),
				int(got["bonus"]), String(c["name"]), int(c["bonus"])]
	if not ok:
		fails += 1
	print("%sлесенка считается и не перебивает старшие комбинации" % ["  OK  " if ok else " FAIL "])
	print("        %s" % (detail if detail != "" else "9 раскладов сошлись"))
