extends SceneTree

## Дуракуб: правила отбоя, нейтральные роли, безальтернативные действия и полная
## партия ботов. Те же проверки, что в харнессе веб-прототипа.

var fails := 0

func _init() -> void:
	print("")
	print("--- дуракуб: правила ---")
	print("")
	deck_case()
	beats_case()
	throw_case()

	print("")
	print("--- дуракуб: роли и действия ---")
	print("")
	roles_case()
	wrong_seat_case()
	forced_case()

	print("")
	print("--- дуракуб: партия целиком ---")
	print("")
	full_game_case()

	print("")
	if fails > 0:
		print("ПРОВАЛОВ: %d" % fails)
	else:
		print("ВСЕ ПРОВЕРКИ ПРОЙДЕНЫ")
	print("")
	quit(1 if fails > 0 else 0)

func check(ok: bool, title: String, detail: String = "") -> void:
	if not ok:
		fails += 1
	print("%s%s" % ["  OK  " if ok else " FAIL ", title])
	if detail != "":
		print("        %s" % detail)

# ------------------------------------------------------------------ правила

func deck_case() -> void:
	var s := Durak.new_game(1234, "bot")
	var total: int = s["talon"].size() + s["players"]["p"]["hand"].size() + s["players"]["e"]["hand"].size()
	var hands_ok: bool = s["players"]["p"]["hand"].size() == 6 and s["players"]["e"]["hand"].size() == 6
	check(total == 24 and hands_ok, "24 куба, по 6 в руки, козырь определён",
		"в колоде=%d, руки %d и %d, козырь=%s" % [s["talon"].size(),
			s["players"]["p"]["hand"].size(), s["players"]["e"]["hand"].size(),
			Durak.SUITS[int(s["trump"])]])

	var a := Durak.new_game(999, "bot")
	var b := Durak.new_game(999, "bot")
	var same := _hand(a, "p") == _hand(b, "p") and int(a["trump"]) == int(b["trump"])
	check(same, "тот же сид — та же раздача и козырь", "[%s]" % _hand(a, "p"))

func beats_case() -> void:
	var trump := 0     # ♠
	var ok1 := Durak.beats({"value": 5, "suit": 1}, {"value": 3, "suit": 1}, trump)
	var ok2 := not Durak.beats({"value": 2, "suit": 1}, {"value": 3, "suit": 1}, trump)
	var ok3 := Durak.beats({"value": 1, "suit": 0}, {"value": 6, "suit": 1}, trump)   # козырь бьёт всё
	var ok4 := not Durak.beats({"value": 6, "suit": 1}, {"value": 1, "suit": 2}, trump) # чужая масть не бьёт
	var ok5 := not Durak.beats({"value": 3, "suit": 0}, {"value": 5, "suit": 0}, trump) # козырь младше не бьёт
	check(ok1 and ok2 and ok3 and ok4 and ok5, "отбой: старший той же масти или козырь",
		"5♥>3♥=%s | 2♥>3♥=%s | 1♠(козырь) бьёт 6♥=%s | 6♥ бьёт 1♦=%s" % [str(ok1), str(not ok2), str(ok3), str(not ok4)])

func throw_case() -> void:
	var s := Durak.new_game(7, "bot")
	s["table"] = [{"a": {"value": 4, "suit": 1}, "d": {"value": 6, "suit": 1}}]
	var ok1 := Durak.can_throw(s, {"value": 4, "suit": 2})   # значение есть на столе
	var ok2 := Durak.can_throw(s, {"value": 6, "suit": 3})   # тоже есть (отбившийся)
	var ok3 := not Durak.can_throw(s, {"value": 2, "suit": 0})
	check(ok1 and ok2 and ok3, "подкидывать можно только значения со стола",
		"4=%s, 6=%s, 2=%s" % [str(ok1), str(ok2), str(not ok3)])

# --------------------------------------------------------------- роли

func roles_case() -> void:
	var s := _fixed_game()
	var att := String(s["attacker"])
	var def := Durak.other_seat(s, att)
	# руки задаём вручную: проверяем роли, а не удачу раздачи
	s["trump"] = 0
	Durak.hand_of(s, att).clear()
	Durak.hand_of(s, att).append({"value": 3, "suit": 1})
	Durak.hand_of(s, def).clear()
	Durak.hand_of(s, def).append({"value": 5, "suit": 1})
	s["max_att"] = 2
	var a_ok := Durak.actor(s) == att and String(s["phase"]) == "attack"
	var r1 := Durak.attack(s, att, 0)
	var b_ok := not r1.is_empty() and String(s["phase"]) == "defend" and Durak.actor(s) == def
	var r2 := Durak.defend(s, def, 0)
	var c_ok := not r2.is_empty() and String(s["phase"]) == "attack" and Durak.actor(s) == att
	check(a_ok and b_ok and c_ok, "атака и отбой идут от разных сидений, роли ведёт фаза",
		"стол=%s | фаза=%s" % [_table(s), String(s["phase"])])

	# «Бито» закрывает кон и меняет атакующего
	var before := String(s["attacker"])
	var r3 := Durak.bito(s, att)
	var d_ok: bool = not r3.is_empty() and String(s["attacker"]) != before and s["table"].is_empty()
	check(d_ok, "«Бито»: стол в отбой, роли меняются",
		"отбой=%d, теперь атакует %s" % [int(s["discard"]), String(s["attacker"])])

func wrong_seat_case() -> void:
	var s := _fixed_game()
	var att := String(s["attacker"])
	var def := Durak.other_seat(s, att)
	var bad1 := Durak.attack(s, def, 0)        # атакует не тот
	var bad2 := Durak.defend(s, att, 0)        # защищается не тот и не в той фазе
	check(bad1.is_empty() and bad2.is_empty(), "чужим сиденьем действовать нельзя")

func forced_case() -> void:
	# защитнику нечем отбить: козырь ♠, атака 6♥, в руке только 1♦ и 2♣
	var s := _fixed_game()
	var att := String(s["attacker"])
	var def := Durak.other_seat(s, att)
	s["trump"] = 0
	Durak.hand_of(s, att).clear()
	Durak.hand_of(s, att).append({"value": 6, "suit": 1})
	Durak.hand_of(s, def).clear()
	Durak.hand_of(s, def).append({"value": 1, "suit": 2})
	Durak.hand_of(s, def).append({"value": 2, "suit": 3})
	s["max_att"] = 2
	s["phase"] = "attack"
	Durak.attack(s, att, 0)
	var f1 := Durak.forced_action(s, def)
	check(f1 == "take", "нечем отбить — остаётся только «Взять»", "forced=%s" % f1)

	# атакующему нечем подкинуть: на столе значение 6, в руке 5♥
	var s2 := _fixed_game()
	var att2 := String(s2["attacker"])
	var def2 := Durak.other_seat(s2, att2)
	s2["trump"] = 0
	Durak.hand_of(s2, att2).clear()
	Durak.hand_of(s2, att2).append({"value": 6, "suit": 1})
	Durak.hand_of(s2, att2).append({"value": 5, "suit": 1})
	Durak.hand_of(s2, def2).clear()
	Durak.hand_of(s2, def2).append({"value": 6, "suit": 0})
	Durak.hand_of(s2, def2).append({"value": 3, "suit": 0})
	s2["max_att"] = 3
	s2["phase"] = "attack"
	Durak.attack(s2, att2, 0)
	Durak.defend(s2, def2, 0)
	var f2 := Durak.forced_action(s2, att2)
	check(f2 == "bito", "нечем подкинуть — остаётся только «Бито»", "forced=%s" % f2)

	# когда выбор есть, ничего навязывать нельзя
	var s3 := _fixed_game()
	var att3 := String(s3["attacker"])
	var def3 := Durak.other_seat(s3, att3)
	s3["trump"] = 0
	Durak.hand_of(s3, att3).clear()
	Durak.hand_of(s3, att3).append({"value": 3, "suit": 1})
	Durak.hand_of(s3, def3).clear()
	Durak.hand_of(s3, def3).append({"value": 5, "suit": 1})
	Durak.hand_of(s3, def3).append({"value": 4, "suit": 1})
	s3["max_att"] = 2
	s3["phase"] = "attack"
	Durak.attack(s3, att3, 0)
	var f3 := Durak.forced_action(s3, def3)
	check(f3 == "", "есть чем отбить — выбор остаётся за игроком", "forced='%s'" % f3)

# ------------------------------------------------------------------ партия

## Оба бота, кон за коном до конца колоды. Проверяем, что партия заканчивается,
## кубы не теряются и не появляются из воздуха.
func full_game_case() -> void:
	var s := Durak.new_game(20260731, "bot")
	s["seats"]["p"] = {"kind": "bot", "local": false, "name": "Бот 1"}
	var guard := 0
	while not bool(s["over"]) and guard < 3000:
		guard += 1
		var seat := Durak.actor(s)
		if seat == "":
			break
		var act := Durak.bot_action(s)
		if act.is_empty():
			break
		match String(act["act"]):
			"attack": Durak.attack(s, seat, int(act["hand"]))
			"defend": Durak.defend(s, seat, int(act["hand"]))
			"bito": Durak.bito(s, seat)
			"take": Durak.take(s, seat)
	var on_table := 0
	for pair in s["table"]:
		on_table += 1 + (1 if pair["d"] != null else 0)
	var total: int = s["talon"].size() + Durak.hand_of(s, "p").size() + Durak.hand_of(s, "e").size() \
		+ int(s["discard"]) + on_table
	var ok: bool = bool(s["over"]) and total == 24 and guard < 3000
	check(ok, "партия ботов доиграна, все 24 куба на месте",
		"ходов=%d | руки %d:%d | колода=%d | отбой=%d | итог: %s" % [guard,
			Durak.hand_of(s, "p").size(), Durak.hand_of(s, "e").size(),
			s["talon"].size(), int(s["discard"]), String(s["outcome"]["detail"])])

# ------------------------------------------------------------- вспомогательное

## Партия с предсказуемым состоянием: сид фиксирован, фаза атаки.
func _fixed_game() -> Dictionary:
	var s := Durak.new_game(2024, "human")
	s["shown_to"] = String(s["attacker"])
	s["phase"] = "attack"
	return s

func _hand(s: Dictionary, seat: String) -> String:
	var out := []
	for d in Durak.hand_of(s, seat):
		out.append(Durak.die_label(d))
	return ",".join(out)

func _table(s: Dictionary) -> String:
	var out := []
	for pair in s["table"]:
		out.append("%s/%s" % [Durak.die_label(pair["a"]),
			"—" if pair["d"] == null else Durak.die_label(pair["d"])])
	return " ".join(out)
