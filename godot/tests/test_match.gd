extends SceneTree

## Поток игры: раздача от сида, передача хода, пас, исходы, полная партия ботов.
## Аналог блоков «сиденья и ширма», «сид», «матч от начала до конца» из харнесса
## веб-прототипа.
##
## Запуск:
##   ...console.exe --headless --path godot --script tests/test_match.gd

var fails := 0

func _init() -> void:
	print("")
	print("--- сид и раздача ---")
	print("")
	seed_case()

	print("")
	print("--- сиденья и ширма ---")
	print("")
	seats_case()
	pass_case()

	print("")
	print("--- матч от начала до конца ---")
	print("")
	full_match_case("classic")
	full_match_case("big")
	full_match_case("race")

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

func hand_print(state: Dictionary, seat: String) -> String:
	var out := []
	for d in state["players"][seat]["hand"]:
		out.append("%d%s" % [int(d["value"]), String(d["type"]).substr(0, 2)])
	return ",".join(out)

# ----------------------------------------------------------------- сценарии

func seed_case() -> void:
	var a := MatchState.new_match("classic", 12345, false)
	var b := MatchState.new_match("classic", 12345, false)
	var c := MatchState.new_match("classic", 777, false)
	var same := hand_print(a, "p") == hand_print(b, "p")
	var diff := hand_print(a, "p") != hand_print(c, "p")
	check(same and diff, "тот же сид — та же раздача, другой — другая",
		"сид 12345: %s | сид 777: %s" % [hand_print(a, "p"), hand_print(c, "p")])
	check(int(a["seed"]) == 12345, "сид матча лежит в состоянии", "S.seed=%d" % int(a["seed"]))

func seats_case() -> void:
	var pve := MatchState.new_match("classic", 1, false)
	var ok_pve := MatchState.seat_kind(pve, "e") == "bot" and not MatchState.shared_device(pve) \
		and not MatchState.needs_veil(pve, "p")
	check(ok_pve, "PVE: за вторым сиденьем бот, ширма не нужна",
		"p=%s e=%s общее устройство=%s" % [MatchState.seat_kind(pve, "p"),
			MatchState.seat_kind(pve, "e"), str(MatchState.shared_device(pve))])

	var hs := MatchState.new_match("classic", 1, true)
	hs["shown_to"] = "p"
	var ok_hs := MatchState.shared_device(hs) and MatchState.needs_veil(hs, "e") \
		and not MatchState.needs_veil(hs, "p")
	check(ok_hs, "хотсит: ширма нужна второму игроку и не нужна первому",
		"экран у p | для e=%s, для p=%s" % [str(MatchState.needs_veil(hs, "e")),
			str(MatchState.needs_veil(hs, "p"))])

	var names_ok := MatchState.seat_name(hs, "p") == "Игрок 1" and MatchState.seat_name(pve, "e") == "Враг"
	check(names_ok, "имена сидений зависят от состава")

func pass_case() -> void:
	# соперник не может ходить: доска забита его же кубами, в руке единицы
	var s := MatchState.new_match("classic", 4242, true)
	s["shown_to"] = "p"
	for i in s["board"].size():
		s["board"][i] = {"v": 6, "type": "basic", "owner": "e", "shield": 0}
	s["players"]["e"]["hand"] = [{"value": 1, "type": "basic"}]
	s["players"]["e"]["deck"] = []
	s["turn"] = "p"
	var ev := MatchState.advance(s)
	var ok := String(ev["event"]) == "pass" and String(ev["seat"]) == "e" and String(s["shown_to"]) == "p"
	check(ok, "ходить нечем — пас, экран не переезжает и ширмы нет",
		"событие=%s seat=%s | экран у=%s | в истории=%s" % [
			String(ev["event"]), String(ev.get("seat", "")), String(s["shown_to"]),
			String(s["history"][-1]["parts"][0]["t"])])

## Полная партия: оба сиденья боты, крутим до конца матча. Проверяем, что игра
## доходит до исхода, счёт конечен и на каждом ходу сумма жетонов равна итогу.
func full_match_case(mode: String) -> void:
	var s := MatchState.new_match(mode, 31337, false)
	s["seats"]["p"] = {"kind": "bot", "local": false, "name": "Бот 1"}
	var rng := MatchState.make_rng(999)
	var guard := 0
	var rounds := 0
	var contract_ok := true
	while not MatchState.is_match_over(s) and guard < 4000:
		guard += 1
		var seat := String(s["turn"])
		if MatchState.moves_left(s, seat) <= 0 or not MatchState.has_legal(s, seat):
			var ev := MatchState.advance(s)
			if String(ev["event"]) == "round_end":
				rounds += 1
				var out := MatchState.close_round(s)
				if bool(out["match_over"]):
					break
				MatchState.new_round(s)
			continue
		var mv := Bot.choose_move(s, seat, rng)
		if mv.is_empty():
			var ev2 := MatchState.advance(s)
			if String(ev2["event"]) == "round_end":
				rounds += 1
				var out2 := MatchState.close_round(s)
				if bool(out2["match_over"]):
					break
				MatchState.new_round(s)
			continue
		var res := MatchState.play(s, seat, int(mv["hand"]), int(mv["cell"]))
		# контракт: сумма жетонов карточки равна итогу хода
		var shown := 0 if res["mined"] else Rules.chip_sum(res["parts"])
		if shown != int(res["pts"]):
			contract_ok = false
		var ev3 := MatchState.advance(s)
		if String(ev3["event"]) == "round_end":
			rounds += 1
			var out3 := MatchState.close_round(s)
			if bool(out3["match_over"]):
				break
			MatchState.new_round(s)

	var final := MatchState.match_outcome(s)
	var finite: bool = absi(int(s["players"]["p"]["score"])) < 100000
	var ok: bool = MatchState.is_match_over(s) and contract_ok and finite and guard < 4000
	check(ok, "%s: партия ботов доиграна до исхода" % mode,
		"раундов=%d | %s | победитель=%s | контракт карточек=%s%s" % [
			int(s["round"]), String(final["detail"]),
			(MatchState.seat_name(s, String(final["winner"])) if final["winner"] != "" else "ничья"),
			str(contract_ok), " | УПЁРЛСЯ В ЛИМИТ" if guard >= 4000 else ""])
