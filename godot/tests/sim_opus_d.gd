extends SceneTree

## Временный прогон (гейм-дизайн-аудит). Битва за первый ход и Дуракуб.

func _init() -> void:
	print("=== D1. Битва за первый ход ===")
	for n in [2, 3, 4]:
		duel_stats(n, 20000)
	print("")
	print("--- помогает ли победа в битве выиграть матч ---")
	for n in [2, 3, 4]:
		duel_effect("classic", n, 500)
	print("")
	print("=== D2. Дуракуб ===")
	for n in [2, 3, 4]:
		durak_stats(n, 600)
	quit()

func duel_stats(n: int, tries: int) -> void:
	var wins := {}
	var rolls_hist := {}
	var total_rolls := 0
	var fallback := 0
	var roster := []
	for i in n:
		roster.append({"kind": "bot", "local": false, "name": "Бот %d" % (i + 1)})
	for g in tries:
		var s := MatchState.new_match("classic", 700000 + g, "roster", "p", "", "Ты", [], roster)
		var d := MatchState.roll_duel(s)
		var w := String(d["winner"])
		wins[w] = int(wins.get(w, 0)) + 1
		var r: int = d["rounds"].size()
		rolls_hist[r] = int(rolls_hist.get(r, 0)) + 1
		total_rolls += r
		if r >= 20:
			fallback += 1
	var parts := []
	for seat in MatchState.seat_ids(n):
		parts.append("%s %.2f%%" % [seat, 100.0 * float(wins.get(seat, 0)) / float(tries)])
	var hk := rolls_hist.keys()
	hk.sort()
	var hp := []
	for k in hk:
		hp.append("%d: %.2f%%" % [k, 100.0 * float(rolls_hist[k]) / float(tries)])
	print("на %d (%d битв): %s | бросков в среднем %.3f | %s | упёрлось в предел %d" % [
		n, tries, " ".join(parts), float(total_rolls) / float(tries), ", ".join(hp), fallback])

func duel_effect(mode: String, n: int, games: int) -> void:
	var duel_won_match := 0
	var decided := 0
	for g in games:
		var roster := []
		for i in n:
			roster.append({"kind": "bot", "local": false, "name": "Бот %d" % (i + 1)})
		var s := MatchState.new_match(mode, 33000 + g, "roster", "p", "", "Ты", [], roster)
		var d := MatchState.roll_duel(s)
		var champ := String(d["winner"])
		MatchState.apply_duel(s, champ)
		var rng := MatchState.make_rng((33000 + g) * 13 + 5)
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
				var out := MatchState.close_round(s)
				if bool(out["match_over"]):
					break
				MatchState.new_round(s)
		var mo := MatchState.match_outcome(s)
		var w := String(mo["winner"])
		if w == "":
			continue
		decided += 1
		if w == champ:
			duel_won_match += 1
	print("%s на %d: победитель битвы берёт матч %.1f%% (ожидание %.1f%%), решённых матчей %d" % [
		mode, n, 100.0 * float(duel_won_match) / float(maxi(1, decided)), 100.0 / float(n), decided])

func durak_stats(n: int, games: int) -> void:
	var losers := {}
	var no_loser := 0
	var stuck := 0
	var acts_total := 0
	var acts_hist := {}
	var first_att_loses := 0
	var lost_dice := 0
	for g in games:
		var roster := []
		for i in n:
			roster.append({"kind": "bot", "local": false, "name": "Бот %d" % (i + 1)})
		var s := Durak.new_game(60000 + g, "bot", "p", "", "Ты", roster)
		var first_att := String(s["attacker"])
		var guard := 0
		while not bool(s["over"]) and guard < 4000:
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
		acts_total += guard
		acts_hist[guard / 10] = int(acts_hist.get(guard / 10, 0)) + 1
		if not bool(s["over"]):
			stuck += 1
			continue
		var on_table := 0
		for pair in s["table"]:
			on_table += 1 + (1 if pair["d"] != null else 0)
		var total: int = s["talon"].size() + int(s["discard"]) + on_table
		for seat in s["order"]:
			total += Durak.hand_of(s, seat).size()
		if total != 24:
			lost_dice += 1
		var loser := String(s["outcome"].get("loser", ""))
		if loser == "":
			no_loser += 1
		else:
			losers[loser] = int(losers.get(loser, 0)) + 1
			if loser == first_att:
				first_att_loses += 1
	var parts := []
	for seat in MatchState.seat_ids(n):
		parts.append("%s %.1f%%" % [seat, 100.0 * float(losers.get(seat, 0)) / float(games)])
	print("дуракуб на %d (%d партий): дуракуб по местам %s | «все вышли» %.1f%% | зависло %d | кубы потеряны %d | действий в среднем %.0f | первый атакующий остаётся дуракубом %.1f%% (ожидание %.1f%%)" % [
		n, games, " ".join(parts), 100.0 * float(no_loser) / float(games), stuck, lost_dice,
		float(acts_total) / float(games),
		100.0 * float(first_att_loses) / float(games - no_loser - stuck), 100.0 / float(n)])
