extends SceneTree

## Временный прогон (гейм-дизайн-аудит). «Гонка», «Территория», «Своя колода»
## и несколько точечных проверок инвариантов.

func _init() -> void:
	print("=== E1. Точечные проверки ===")
	checks()
	print("")
	print("=== E2. Гонка ===")
	race_stats(500)
	print("")
	print("=== E3. Территория и Своя колода ===")
	for mode in ["territory", "draft"]:
		for n in [2, 3]:
			bo3_stats(mode, n, 500)
	quit()

func checks() -> void:
	# 1. Видна ли компенсация в ленте после открытия раунда
	var s := MatchState.new_match("classic", 12345, "bot")
	print("после new_match: счёт p=%d e=%d, записей в ленте %d (ожидалась запись «Ходишь раньше»)" % [
		int(s["players"]["p"]["score"]), int(s["players"]["e"]["score"]), s["history"].size()])
	# 2. Кто объявляется победителем раунда в «Гонке»
	var r := MatchState.new_match("race", 777, "bot")
	r["players"]["p"]["score"] = 120
	r["players"]["e"]["score"] = 40
	var out := MatchState.round_outcome(r)
	print("гонка, счёт 120:40 за матч → победитель раунда «%s», строка «%s»" % [
		String(out["winner"]), String(out["detail"])])
	# 3. Хватает ли колоды драфта на три раунда
	var d := MatchState.new_match("draft", 555, "bot")
	print("драфт: колода %d + рука %d = %d кубов на %d ходов за матч" % [
		d["players"]["p"]["deck"].size(), d["players"]["p"]["hand"].size(),
		d["players"]["p"]["deck"].size() + d["players"]["p"]["hand"].size(),
		int(d["cfg"]["moves"]) * 3])
	# 4. Значение komi по позициям
	for n in [2, 3, 4]:
		var line := []
		for k in n:
			line.append(str(int(round(float(Rules.FIRST_MOVE_KOMI) * float(n - 1 - k) / float(n - 1)))))
		print("komi на %d игроков по позициям: %s" % [n, " / ".join(line)])
	# 5. Сколько раундов нужно, чтобы кто-то потерял все жизни при n>2
	print("жизней %d, при n>2 сердце теряют все кроме одного → минимум раундов до конца матча: %d" % [
		Rules.LIVES_MAX, Rules.LIVES_MAX])

func race_stats(games: int) -> void:
	var rounds_total := 0
	var moves_total := 0
	var wins := {}
	var lead_changes := 0
	var winner_led_from_r1 := 0
	var round_winner_is_leader := 0
	var round_winner_cnt := 0
	var behind_first := 0
	var behind_cnt := 0
	for g in games:
		var s := MatchState.new_match("race", 41000 + g, "roster", "p", "", "Ты", [],
			[{"kind": "bot", "local": false, "name": "Б1"}, {"kind": "bot", "local": false, "name": "Б2"}])
		var d := MatchState.roll_duel(s)
		MatchState.apply_duel(s, String(d["winner"]))
		var rng := MatchState.make_rng((41000 + g) * 11 + 1)
		var guard := 0
		var last_leader := ""
		var first_leader := ""
		while not MatchState.is_match_over(s) and guard < 20000:
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
					moves_total += 1
					ev = MatchState.advance(s)
			if String(ev.get("event", "")) == "round_end":
				var lead := ""
				var best := -(1 << 30)
				for st in s["order"]:
					if int(s["players"][st]["score"]) > best:
						best = int(s["players"][st]["score"])
						lead = String(st)
				if first_leader == "":
					first_leader = lead
				if last_leader != "" and lead != last_leader:
					lead_changes += 1
				last_leader = lead
				var out := MatchState.close_round(s)
				round_winner_cnt += 1
				if String(out["winner"]) == lead:
					round_winner_is_leader += 1
				if bool(out["match_over"]):
					break
				MatchState.new_round(s)
				behind_cnt += 1
				if String(s["turn"]) != lead:
					behind_first += 1
		rounds_total += int(s["round"])
		var mo := MatchState.match_outcome(s)
		var w := String(mo["winner"])
		wins[w] = int(wins.get(w, 0)) + 1
		if w == first_leader:
			winner_led_from_r1 += 1
	var parts := []
	for seat in ["p", "e"]:
		parts.append("%s %.1f%%" % [seat, 100.0 * float(wins.get(seat, 0)) / float(games)])
	print("гонка на 2 (%d партий): %s | раундов %.1f, ходов за партию %.0f" % [
		games, " ".join(parts), float(rounds_total) / float(games), float(moves_total) / float(games)])
	print("      смен лидера за партию %.2f | лидер после 1-го раунда берёт матч %.0f%% | «победитель раунда» = общий лидер %.0f%% | следующим начинает отстающий %.0f%%" % [
		float(lead_changes) / float(games), 100.0 * float(winner_led_from_r1) / float(games),
		100.0 * float(round_winner_is_leader) / float(maxi(1, round_winner_cnt)),
		100.0 * float(behind_first) / float(maxi(1, behind_cnt))])

func bo3_stats(mode: String, n: int, games: int) -> void:
	var rounds_total := 0
	var wins := {}
	var draws := 0
	var by_wins := 0
	var by_total := 0
	var round_ties := 0
	var round_cnt := 0
	var passes := 0
	var moves := 0
	var last_round_passes := 0
	for g in games:
		var roster := []
		for i in n:
			roster.append({"kind": "bot", "local": false, "name": "Бот %d" % (i + 1)})
		var s := MatchState.new_match(mode, 52000 + g, "roster", "p", "", "Ты", [], roster)
		var d := MatchState.roll_duel(s)
		MatchState.apply_duel(s, String(d["winner"]))
		var rng := MatchState.make_rng((52000 + g) * 19 + 2)
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
					moves += 1
					ev = MatchState.advance(s)
			if String(ev.get("event", "")) == "pass":
				passes += 1
				if int(s["round"]) >= 3:
					last_round_passes += 1
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
		else:
			by_total += 1
		var mo := MatchState.match_outcome(s)
		var w := String(mo["winner"])
		if w == "":
			draws += 1
		else:
			wins[w] = int(wins.get(w, 0)) + 1
	var parts := []
	for seat in MatchState.seat_ids(n):
		parts.append("%s %.1f%%" % [seat, 100.0 * float(wins.get(seat, 0)) / float(games)])
	print("%s на %d (%d партий): %s | ничьих %.1f%% | раундов %.2f | исход по победам %.0f%% / по очкам %.0f%% | ничьих в раунде %.1f%% | пасов %.1f%% (в 3-м раунде %.1f%% от всех пасов)" % [
		mode, n, games, " ".join(parts), 100.0 * float(draws) / float(games),
		float(rounds_total) / float(games),
		100.0 * float(by_wins) / float(games), 100.0 * float(by_total) / float(games),
		100.0 * float(round_ties) / float(maxi(1, round_cnt)),
		100.0 * float(passes) / float(maxi(1, moves + passes)),
		100.0 * float(last_round_passes) / float(maxi(1, passes))])
