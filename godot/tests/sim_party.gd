extends SceneTree

## Прогон партий на троих и четверых: сколько матчей заканчивается ничьей и как
## распределяются победы по местам. Нужен после смены правила потери жизни —
## теперь сердце теряют все, кроме взявшего раунд.

func _init() -> void:
	for n in [2, 3, 4]:
		for mode in ["classic", "big", "draft", "race", "territory"]:
			if n > 2 and mode != "classic" and mode != "big":
				continue
			run_set(mode, n, 600)
	quit()

func run_set(mode: String, n: int, games: int) -> void:
	var wins := {}
	var draws := 0
	var rounds_total := 0
	for g in games:
		var roster := []
		for i in n:
			roster.append({"kind": "bot", "local": false, "name": "Бот %d" % (i + 1)})
		var s := MatchState.new_match(mode, 1000 + g, "roster", "p", "", "Ты", [], roster)
		var rng := MatchState.make_rng(500 + g)
		var guard := 0
		while not MatchState.is_match_over(s) and guard < 8000:
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
				if bool(out["match_over"]):
					break
				MatchState.new_round(s)
		rounds_total += int(s["round"])
		var out := MatchState.match_outcome(s)
		var w := String(out["winner"])
		if w == "":
			draws += 1
		else:
			wins[w] = int(wins.get(w, 0)) + 1
	var parts := []
	for seat in MatchState.seat_ids(n):
		parts.append("%s %.1f%%" % [seat, 100.0 * float(wins.get(seat, 0)) / float(games)])
	print("%s на %d: %s | ничьих %.1f%% | раундов в среднем %.1f" % [
		mode, n, " ".join(parts), 100.0 * float(draws) / float(games),
		float(rounds_total) / float(games)])
