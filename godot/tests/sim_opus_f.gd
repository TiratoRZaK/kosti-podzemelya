extends SceneTree

## Временный прогон (гейм-дизайн-аудит).
## F1 — Дуракуб: кто получает первую атаку и почему у мест разная доля дуракубов.
## F2 — Дуракуб втроём/вчетвером: что меняется, если подкидывать реально может
##      любой (сейчас интерфейс спрашивает только атакующего).
## F3 — bo3 (Своя колода, Территория) на исправленном цикле: is_match_over для
##      bo3 становится истинным, как только начался третий раунд, поэтому цикл
##      «while not is_match_over» обрывает матч после второго.

func _init() -> void:
	print("=== F1. Дуракуб: первая атака ===")
	for n in [2, 3, 4]:
		first_att(n, 3000)
	print("")
	print("--- та же партия, но ничья по младшему кубу разыгрывается честно ---")
	for n in [2, 3, 4]:
		durak_run(n, 800, true, false)
	print("")
	print("--- как сейчас (ничья по младшему кубу — первому сиденью) ---")
	for n in [2, 3, 4]:
		durak_run(n, 800, false, false)
	print("")
	print("=== F2. Дуракуб: подкидывает любой (сейчас недоступно в игре) ===")
	for n in [3, 4]:
		durak_run(n, 800, false, true)
	print("")
	print("=== F3. bo3 на исправленном цикле ===")
	for mode in ["draft", "territory"]:
		for n in [2, 3, 4]:
			bo3(mode, n, 500)
	quit()

# ------------------------------------------------------------------ F1

func first_att(n: int, games: int) -> void:
	var who := {}
	var ties := 0
	for g in games:
		var roster := []
		for i in n:
			roster.append({"kind": "bot", "local": false, "name": "Б%d" % (i + 1)})
		var s := Durak.new_game(80000 + g, "bot", "p", "", "Ты", roster)
		who[String(s["attacker"])] = int(who.get(String(s["attacker"]), 0)) + 1
		if best_seats(s).size() > 1:
			ties += 1
	var parts := []
	for seat in MatchState.seat_ids(n):
		parts.append("%s %.1f%%" % [seat, 100.0 * float(who.get(seat, 0)) / float(games)])
	print("на %d: первая атака у %s | ничья по младшему кубу %.1f%% раздач (решается порядком сидений)" % [
		n, " ".join(parts), 100.0 * float(ties) / float(games)])

## Все сиденья с минимальным рангом младшего куба (козырь важнее номинала).
func best_seats(s: Dictionary) -> Array:
	var trump := int(s["trump"])
	var best := 1 << 30
	var res := []
	for seat in s["order"]:
		var r := 1 << 30
		for die in Durak.hand_of(s, seat):
			r = mini(r, int(die["value"]) + (0 if int(die["suit"]) == trump else 100))
		if r < best:
			best = r
			res = [seat]
		elif r == best:
			res.append(seat)
	return res

# ------------------------------------------------------------------ F1/F2

func durak_run(n: int, games: int, fair_tie: bool, throw_in: bool) -> void:
	var losers := {}
	var by_first := {"first": 0, "other": 0}
	var no_loser := 0
	var stuck := 0
	var acts := 0
	for g in games:
		var roster := []
		for i in n:
			roster.append({"kind": "bot", "local": false, "name": "Б%d" % (i + 1)})
		var s := Durak.new_game(90000 + g, "bot", "p", "", "Ты", roster)
		var rng := MatchState.make_rng(90000 + g)
		if fair_tie:
			var cand := best_seats(s)
			if cand.size() > 1:
				s["attacker"] = String(cand[rng.randi_range(0, cand.size() - 1)])
				Durak.start_bout(s)
		var first := String(s["attacker"])
		var guard := 0
		while not bool(s["over"]) and guard < 4000:
			guard += 1
			var seat := Durak.actor(s)
			if seat == "":
				break
			if throw_in and String(s["phase"]) == "attack" and not s["table"].is_empty():
				if try_throw_in(s, seat):
					continue
			var act := Durak.bot_action(s)
			if act.is_empty():
				break
			match String(act["act"]):
				"attack": Durak.attack(s, seat, int(act["hand"]))
				"defend": Durak.defend(s, seat, int(act["hand"]))
				"bito": Durak.bito(s, seat)
				"take": Durak.take(s, seat)
		acts += guard
		if not bool(s["over"]):
			stuck += 1
			continue
		var loser := String(s["outcome"].get("loser", ""))
		if loser == "":
			no_loser += 1
		else:
			losers[loser] = int(losers.get(loser, 0)) + 1
			by_first["first" if loser == first else "other"] = \
				int(by_first["first" if loser == first else "other"]) + 1
	var parts := []
	for seat in MatchState.seat_ids(n):
		parts.append("%s %.1f%%" % [seat, 100.0 * float(losers.get(seat, 0)) / float(games)])
	var decided := int(by_first["first"]) + int(by_first["other"])
	print("на %d%s%s: дуракуб по местам %s | первый атакующий %.1f%% (ожидание %.1f%%) | зависло %d | действий %.0f" % [
		n, " [честная ничья]" if fair_tie else "", " [подкидывают все]" if throw_in else "",
		" ".join(parts), 100.0 * float(by_first["first"]) / float(maxi(1, decided)),
		100.0 / float(n), stuck, float(acts) / float(games)])

## Подкидывание любым игроком, кроме защитника: сперва атакующий, потом остальные.
func try_throw_in(s: Dictionary, attacker: String) -> bool:
	var order: Array = s["order"]
	var def := Durak.defender_of(s, String(s["attacker"]))
	var start := order.find(attacker)
	for k in order.size():
		var seat := String(order[(start + k) % order.size()])
		if seat == def:
			continue
		var hand: Array = Durak.hand_of(s, seat)
		if hand.is_empty():
			continue
		var vs := Durak.table_values(s)
		var best := -1
		var best_cost := 1 << 30
		for i in hand.size():
			var d: Dictionary = hand[i]
			if not vs.has(int(d["value"])):
				continue
			if s["talon"].size() > 2 and (int(d["value"]) > 4 or int(d["suit"]) == int(s["trump"])):
				continue
			var c := int(d["value"]) + (8 if int(d["suit"]) == int(s["trump"]) else 0)
			if c < best_cost:
				best_cost = c
				best = i
		if best >= 0:
			var r := Durak.attack(s, seat, best)
			if not r.is_empty():
				return true
	return false

# ------------------------------------------------------------------ F3

func bo3(mode: String, n: int, games: int) -> void:
	var wins := {}
	var draws := 0
	var rounds_total := 0
	var by_wins := 0
	var round_ties := 0
	var round_cnt := 0
	for g in games:
		var roster := []
		for i in n:
			roster.append({"kind": "bot", "local": false, "name": "Бот %d" % (i + 1)})
		var s := MatchState.new_match(mode, 61000 + g, "roster", "p", "", "Ты", [], roster)
		var d := MatchState.roll_duel(s)
		MatchState.apply_duel(s, String(d["winner"]))
		var rng := MatchState.make_rng((61000 + g) * 23 + 4)
		var guard := 0
		# цикл идёт по state["over"] — его выставляет close_round; is_match_over
		# для bo3 срабатывает уже на открытии третьего раунда
		while not bool(s["over"]) and guard < 12000:
			guard += 1
			var seat := String(s["turn"])
			var ev := {}
			if MatchState.moves_left(s, seat) <= 0 or not MatchState.has_legal(s, seat):
				ev = MatchState.advance(s)
			else:
				var mv := Bot.choose_move(s, seat, rng)
				if mv.is_empty():
					ev = MatchState.advance(s)
				else:
					MatchState.play(s, seat, int(mv["hand"]), int(mv["cell"]))
					ev = MatchState.advance(s)
			if String(ev.get("event", "")) == "round_end":
				var out := MatchState.close_round(s)
				round_cnt += 1
				if String(out["winner"]) == "":
					round_ties += 1
				if bool(out["match_over"]):
					break
				MatchState.new_round(s)
		rounds_total += int(s["round"])
		var best := -(1 << 30)
		var cnt := 0
		for st in s["order"]:
			var v := int(s["players"][st]["wins"])
			if v > best:
				best = v
				cnt = 1
			elif v == best:
				cnt += 1
		if cnt == 1:
			by_wins += 1
		var mo := MatchState.match_outcome(s)
		var w := String(mo["winner"])
		if w == "":
			draws += 1
		else:
			wins[w] = int(wins.get(w, 0)) + 1
	var parts := []
	for seat in MatchState.seat_ids(n):
		parts.append("%s %.1f%%" % [seat, 100.0 * float(wins.get(seat, 0)) / float(games)])
	print("%s на %d: %s | ничьих %.1f%% | раундов %.2f | исход по победам %.0f%% / по очкам %.0f%% | ничьих в раунде %.1f%%" % [
		mode, n, " ".join(parts), 100.0 * float(draws) / float(games),
		float(rounds_total) / float(games), 100.0 * float(by_wins) / float(games),
		100.0 - 100.0 * float(by_wins) / float(games),
		100.0 * float(round_ties) / float(maxi(1, round_cnt))])
