extends SceneTree

## Из чего складываются очки хода: съедение, рента («Кубы на поле»), комбо.
## Вопрос владельца: «нахер нужна рента, только место занимает».

func _init() -> void:
	for mode in ["classic", "big"]:
		run_set(mode, 300)
	quit()

func run_set(mode: String, games: int) -> void:
	var sum_all := 0.0
	var by := {"Съел": 0.0, "Кубы на поле": 0.0, "комбо": 0.0, "прочее": 0.0}
	var moves := 0
	var rent_only := 0     # ходы, где ВСЁ, что дал ход — это рента
	for g in games:
		var s := MatchState.new_match(mode, 4000 + g, "bot")
		s["seats"]["p"] = {"kind": "bot", "local": false, "name": "Бот 1"}
		var rng := MatchState.make_rng(77 + g)
		var guard := 0
		while not MatchState.is_match_over(s) and guard < 4000:
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
					var res := MatchState.play(s, seat, int(mv["hand"]), int(mv["cell"]))
					moves += 1
					var rent := 0.0
					var other := 0.0
					for p in res["parts"]:
						if not p.has("v") or bool(p.get("die", false)):
							continue
						var v := float(int(p["v"])) * (-1.0 if bool(p.get("neg", false)) else 1.0)
						var t := String(p["t"])
						sum_all += v
						if t == "Съел" or t == "Кубы на поле":
							by[t] += v
						elif String(p.get("cls", "")) == "combo":
							by["комбо"] += v
						else:
							by["прочее"] += v
						if t == "Кубы на поле":
							rent += v
						else:
							other += v
					if rent > 0.0 and other <= 0.0:
						rent_only += 1
					ev = MatchState.advance(s)
			if String(ev.get("event", "")) == "round_end":
				var out := MatchState.close_round(s)
				if bool(out["match_over"]):
					break
				MatchState.new_round(s)
	var parts := []
	for k in by:
		parts.append("%s %.0f%%" % [k, 100.0 * by[k] / sum_all])
	print("%s: %s | ходов %d, из них «одна рента» %.0f%%" % [
		mode, " · ".join(parts), moves, 100.0 * float(rent_only) / float(moves)])
