extends SceneTree

## Временный прогон (гейм-дизайн-аудит). Компенсация за порядок хода.
## Считаем по РАУНДАМ, а не по матчам: для каждого раунда известно, каким по
## счёту ходит сиденье (k=0 — первый), сколько оно набрало и взяло ли раунд.
## Прогоняем с komi=0 (сырой перекос) и с боевым komi=6.

func _init() -> void:
	print("=== B. Компенсация за порядок хода ===")
	print("k=0 — ходит первым. Идеал: доля раундов 1/n у каждого k.")
	for n in [2, 3, 4]:
		for mode in ["classic", "big"]:
			for komi in [0, 6]:
				run_set(mode, n, 500, komi)
	for mode in ["draft", "territory"]:
		for komi in [0, 6]:
			run_set(mode, 2, 500, komi)
	quit()

func run_set(mode: String, n: int, games: int, komi: int) -> void:
	var score_by := {}
	var wins_by := {}
	var cnt_by := {}
	for k in n:
		score_by[k] = 0.0
		wins_by[k] = 0
		cnt_by[k] = 0
	var rounds := 0
	for g in games:
		var roster := []
		for i in n:
			roster.append({"kind": "bot", "local": false, "name": "Бот %d" % (i + 1)})
		var s := MatchState.new_match(mode, 9000 + g, "roster", "p", "", "Ты", [], roster)
		s["komi"] = komi
		# первый ход разыгрывается битвой; apply_duel заново открывает раунд 1,
		# поэтому подменённый komi действует с самого начала
		var d := MatchState.roll_duel(s)
		MatchState.apply_duel(s, String(d["winner"]))
		var rng := MatchState.make_rng((9000 + g) * 31 + 7)
		var order: Array = s["order"]
		var first := String(s["turn"])
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
				var fi := order.find(first)
				for st in order:
					var k := (order.find(st) - fi + n) % n
					score_by[k] = float(score_by[k]) + float(MatchState.round_value(s, String(st)))
					cnt_by[k] = int(cnt_by[k]) + 1
				var out := MatchState.close_round(s)
				if String(out["winner"]) != "":
					var kw := (order.find(String(out["winner"])) - fi + n) % n
					wins_by[kw] = int(wins_by[kw]) + 1
				rounds += 1
				if bool(out["match_over"]):
					break
				MatchState.new_round(s)
				first = String(s["turn"])
	var parts := []
	for k in n:
		parts.append("k%d: %.1f очк / %.1f%% раундов" % [k,
			float(score_by[k]) / float(maxi(1, int(cnt_by[k]))),
			100.0 * float(wins_by[k]) / float(maxi(1, rounds))])
	print("%s на %d, komi=%d | %s | раундов %d" % [mode, n, komi, " · ".join(parts), rounds])
