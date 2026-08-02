extends SceneTree

## Временный прогон (гейм-дизайн-аудит). Подбор компенсации по режимам.
## komi=6 подбиралось на «Классике» вдвоём. Проверяем, сколько нужно на «Большой
## доске» и в «Своей колоде», и что делать с «Территорией», где раунд считается
## по удержанию и очковая компенсация не работает вовсе.

func _init() -> void:
	print("=== G. Подбор компенсации по режимам ===")
	print("k0 — ходит первым. Идеал: 1/n раундов у каждого k.")
	for komi in [6, 12, 16]:
		run_set("big", 2, 400, komi, 0)
	for komi in [6, 12]:
		run_set("big", 3, 400, komi, 0)
	for komi in [6, 12]:
		run_set("big", 4, 400, komi, 0)
	for komi in [6, 10, 14]:
		run_set("draft", 2, 400, komi, 0)
	for komi in [6, 10]:
		run_set("classic", 3, 400, komi, 0)
	print("")
	print("--- Территория: компенсация в удержанных клетках, а не в очках ---")
	for hb in [0, 1, 2, 3]:
		run_set("territory", 2, 400, 6, hb)
	for hb in [0, 2, 3]:
		run_set("territory", 3, 400, 6, hb)
	quit()

func run_set(mode: String, n: int, games: int, komi: int, held_bonus: int) -> void:
	var score_by := {}
	var wins_by := {}
	var cnt_by := {}
	for k in n:
		score_by[k] = 0.0
		wins_by[k] = 0
		cnt_by[k] = 0
	var rounds := 0
	var ties := 0
	for g in games:
		var roster := []
		for i in n:
			roster.append({"kind": "bot", "local": false, "name": "Бот %d" % (i + 1)})
		var s := MatchState.new_match(mode, 71000 + g, "roster", "p", "", "Ты", [], roster)
		s["komi"] = komi
		var d := MatchState.roll_duel(s)
		MatchState.apply_duel(s, String(d["winner"]))
		var order: Array = s["order"]
		var first := String(s["turn"])
		if held_bonus > 0:
			s["players"][first]["held"] = int(s["players"][first]["held"]) + held_bonus
		var rng := MatchState.make_rng((71000 + g) * 29 + 6)
		var guard := 0
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
				var fi := order.find(first)
				for st in order:
					var k := (order.find(st) - fi + n) % n
					score_by[k] = float(score_by[k]) + float(MatchState.round_value(s, String(st)))
					cnt_by[k] = int(cnt_by[k]) + 1
				var out := MatchState.close_round(s)
				rounds += 1
				if String(out["winner"]) == "":
					ties += 1
				else:
					var kw := (order.find(String(out["winner"])) - fi + n) % n
					wins_by[kw] = int(wins_by[kw]) + 1
				if bool(out["match_over"]):
					break
				MatchState.new_round(s)
				first = String(s["turn"])
				if held_bonus > 0:
					s["players"][first]["held"] = int(s["players"][first]["held"]) + held_bonus
	var parts := []
	for k in n:
		parts.append("k%d: %.1f / %.1f%%" % [k,
			float(score_by[k]) / float(maxi(1, int(cnt_by[k]))),
			100.0 * float(wins_by[k]) / float(maxi(1, rounds))])
	print("%s на %d, komi=%d%s | %s | ничьих в раунде %.1f%% | раундов %d" % [
		mode, n, komi, ", +%d клетки первому" % held_bonus if held_bonus > 0 else "",
		" · ".join(parts), 100.0 * float(ties) / float(maxi(1, rounds)), rounds])
