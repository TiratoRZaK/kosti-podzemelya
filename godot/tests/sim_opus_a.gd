extends SceneTree

## Временный прогон (гейм-дизайн-аудит). Структура матча в режимах «на жизни»
## при 2/3/4 игроках: сколько раундов, чем решается исход, доля ничьих в раунде,
## решает ли всё первый раунд. Плюс сравнение с альтернативным правилом
## «сердце теряет только последний».

func _init() -> void:
	print("=== A. Структура матча в режимах на жизни ===")
	for n in [2, 3, 4]:
		for mode in ["classic", "big"]:
			run_set(mode, n, 600, false)
	print("")
	print("--- альтернатива: сердце теряет только последний ---")
	for n in [3, 4]:
		for mode in ["classic", "big"]:
			run_set(mode, n, 600, true)
	quit()

func run_set(mode: String, n: int, games: int, alt: bool) -> void:
	var rounds_hist := {}
	var rounds_total := 0
	var draws := 0
	var by_lives := 0        # исход решён жизнями
	var by_total := 0        # исход решён очками за матч
	var r1_is_winner := 0
	var r1_known := 0
	var round_ties := 0
	var round_count := 0
	var wins := {}
	var lead_flip := 0       # матчи, где победитель матча не выиграл первый раунд
	for g in games:
		var res := run_game(mode, n, 5000 + g, alt)
		var s: Dictionary = res["state"]
		var rs: Array = res["rounds"]
		rounds_total += rs.size()
		rounds_hist[rs.size()] = int(rounds_hist.get(rs.size(), 0)) + 1
		round_count += rs.size()
		for r in rs:
			if String(r["winner"]) == "":
				round_ties += 1
		var mo: Dictionary = MatchState.match_outcome(s)
		var w := String(mo["winner"])
		if w == "":
			draws += 1
		else:
			wins[w] = int(wins.get(w, 0)) + 1
		# чем решён исход: уникальный максимум по жизням или тай-брейк по total
		var best := -(1 << 30)
		var cnt := 0
		for seat in s["order"]:
			var v := int(s["players"][seat]["lives"])
			if v > best:
				best = v
				cnt = 1
			elif v == best:
				cnt += 1
		if cnt == 1:
			by_lives += 1
		else:
			by_total += 1
		if not rs.is_empty() and String(rs[0]["winner"]) != "":
			r1_known += 1
			if String(rs[0]["winner"]) == w:
				r1_is_winner += 1
			elif w != "":
				lead_flip += 1
	var parts := []
	for seat in MatchState.seat_ids(n):
		parts.append("%s %.1f%%" % [seat, 100.0 * float(wins.get(seat, 0)) / float(games)])
	var hist := []
	var keys := rounds_hist.keys()
	keys.sort()
	for k in keys:
		hist.append("%d: %.0f%%" % [k, 100.0 * float(rounds_hist[k]) / float(games)])
	print("%s на %d%s | места: %s | ничьих %.1f%% | раундов %.2f (%s)" % [
		mode, n, " [альт]" if alt else "", " ".join(parts),
		100.0 * float(draws) / float(games),
		float(rounds_total) / float(games), ", ".join(hist)])
	print("      исход по жизням %.0f%% / по очкам за матч %.0f%% | ничьих в раунде %.1f%% | победитель 1-го раунда берёт матч %.0f%%" % [
		100.0 * float(by_lives) / float(games), 100.0 * float(by_total) / float(games),
		100.0 * float(round_ties) / float(round_count),
		100.0 * float(r1_is_winner) / float(maxi(1, r1_known))])

func run_game(mode: String, n: int, seed_value: int, alt: bool) -> Dictionary:
	var roster := []
	for i in n:
		roster.append({"kind": "bot", "local": false, "name": "Бот %d" % (i + 1)})
	var s := MatchState.new_match(mode, seed_value, "roster", "p", "", "Ты", [], roster)
	# первый ход разыгрывается битвой — как в живой игре
	var d := MatchState.roll_duel(s)
	MatchState.apply_duel(s, String(d["winner"]))
	var rng := MatchState.make_rng(seed_value * 31 + 7)
	var rounds := []
	var cur := {"first": String(s["turn"]), "winner": "", "score": {}}
	var guard := 0
	while not MatchState.is_match_over(s) and guard < 12000:
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
			for st in s["order"]:
				cur["score"][st] = int(s["players"][st]["score"])
			var lives_before := {}
			for st in s["order"]:
				lives_before[st] = int(s["players"][st]["lives"])
			var out := MatchState.close_round(s)
			cur["winner"] = String(out["winner"])
			if alt and s["order"].size() > 2:
				# откатываем «все, кроме взявшего» и снимаем сердце только у последнего
				for st in s["order"]:
					s["players"][st]["lives"] = int(lives_before[st])
				var worst := 1 << 30
				var last := []
				for st in s["order"]:
					var v := MatchState.round_value(s, String(st))
					if v < worst:
						worst = v
						last = [st]
					elif v == worst:
						last.append(st)
				if last.size() == 1:
					s["players"][last[0]]["lives"] = int(s["players"][last[0]]["lives"]) - 1
				var over := MatchState.is_match_over(s)
				s["over"] = over
				out["match_over"] = over
			rounds.append(cur)
			if bool(out["match_over"]):
				break
			MatchState.new_round(s)
			cur = {"first": String(s["turn"]), "winner": "", "score": {}}
	return {"state": s, "rounds": rounds}
