extends SceneTree

## «Территория»: кто берёт раунд по позиции в круге (0 — ходит первым).
## Ничья по клеткам решается порядком хода; проверяем, не создало ли это перекос.

func _init() -> void:
	for n in [2, 3, 4]:
		run(n, 700)
	quit()

func run(n: int, games: int) -> void:
	var by_pos := []
	var rounds := 0
	var ties := 0
	var no_winner := 0
	for i in n:
		by_pos.append(0)
	for g in games:
		var roster := []
		for i in n:
			roster.append({"kind": "bot", "local": false, "name": "Бот %d" % (i + 1)})
		var s := MatchState.new_match("territory", 800 + g, "roster", "p", "", "Ты", [], roster)
		MatchState.apply_duel(s, String(MatchState.roll_duel(s)["winner"]))
		var rng := MatchState.make_rng(19 + g)
		var guard := 0
		while not bool(s.get("over", false)) and guard < 6000:
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
				# позиция считается от того, кто начал раунд
				var alive: Array = MatchState.alive_seats(s)
				var first := alive.find(String(s["first_seat"]))
				if first < 0:
					first = 0
				# ничья по клеткам до закрытия раунда
				var best := -1
				var top := 0
				for seat2 in alive:
					var v := int(s["players"][seat2].get("held", 0))
					if v > best:
						best = v
						top = 1
					elif v == best:
						top += 1
				if top > 1:
					ties += 1
				var out := MatchState.close_round(s)
				rounds += 1
				var w := String(out["winner"])
				if w == "":
					no_winner += 1
				else:
					var pos := (alive.find(w) - first + alive.size()) % alive.size()
					by_pos[pos] = int(by_pos[pos]) + 1
				if bool(out["match_over"]):
					break
				MatchState.new_round(s)
	var parts := []
	for i in n:
		parts.append("%.1f%%" % [100.0 * float(by_pos[i]) / float(rounds)])
	print("территория на %d: по позициям %s | ничьих по клеткам %.1f%% | раунд без победителя %.1f%% | раундов %d" % [
		n, " / ".join(parts), 100.0 * float(ties) / float(rounds),
		100.0 * float(no_winner) / float(rounds), rounds])
