extends SceneTree

## Проверка правок по отчёту механика: Дуракуб вчетвером, компенсация в ленте,
## победитель раунда в «Гонке», ничьи в «Территории».

func _init() -> void:
	lives_case(4, 400)
	lives_case(3, 400)
	lives_case(2, 400)
	komi_case()
	durak_case(4, 1200)
	durak_case(3, 600)
	race_case(400)
	territory_case(2, 400)
	territory_case(4, 400)
	quit()

## Выбывание: проигравший все жизни выходит, остальные доигрывают. Победитель
## обязан быть живым, а с ненулевыми жизнями проигрывать нельзя.
func lives_case(n: int, games: int) -> void:
	var bad_win := 0        # победитель с нулём жизней
	var bad_loss := 0       # у проигравшего остались жизни, а живых больше одного
	var rounds := 0.0
	var draws := 0
	var moves_after_out := 0
	for g in games:
		var roster := []
		for i in n:
			roster.append({"kind": "bot", "local": false, "name": "Бот %d" % (i + 1)})
		var s := MatchState.new_match("classic", 5000 + g, "roster", "p", "", "Ты", [], roster)
		var rng := MatchState.make_rng(3 + g)
		var guard := 0
		while not bool(s.get("over", false)) and guard < 8000:
			guard += 1
			var seat := String(s["turn"])
			if MatchState.is_out(s, seat):
				moves_after_out += 1
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
		rounds += float(s["round"])
		var fin := MatchState.match_outcome(s)
		var w := String(fin["winner"])
		if w == "":
			draws += 1
		elif int(s["players"][w]["lives"]) <= 0:
			bad_win += 1
		for seat in s["order"]:
			if String(seat) != w and int(s["players"][seat]["lives"]) > 0 					and MatchState.alive_seats(s).size() > 1:
				bad_loss += 1
	print("жизни на %d: раундов %.1f | ничьих %.1f%% | победитель без сердец %d | проиграл с сердцами %d | ходов после выбывания %d" % [
		n, rounds / float(games), 100.0 * float(draws) / float(games),
		bad_win, bad_loss, moves_after_out])

## Жетон «Ходишь раньше» обязан лежать в ленте с первого кадра раунда.
func komi_case() -> void:
	var s := MatchState.new_match("classic", 42, "bot")
	var lead := ""
	for e in s["history"]:
		lead += String(e["parts"][0]["t"])
	var score_sum := 0
	for seat in s["order"]:
		score_sum += int(s["players"][seat]["score"])
	print("компенсация: счёт=%d записей в ленте=%d (%s)" % [
		score_sum, s["history"].size(), lead])

## Кто остаётся дуракубом: места должны быть равны.
func durak_case(n: int, games: int) -> void:
	var lose := {}
	var stuck := 0
	var talon_left := 0.0
	var trump_last := 0
	for g in games:
		var roster := []
		for i in n:
			roster.append({"kind": "bot", "local": false, "name": "Бот %d" % (i + 1)})
		var st := Durak.new_game(9000 + g, "roster", "p", "", "Ты", roster)
		talon_left += float(st["talon"].size())
		var last := String(st["order"][n - 1])
		for die in Durak.hand_of(st, last):
			if int(die["suit"]) == int(st["trump"]):
				trump_last += 1
				break
		var guard := 0
		while not bool(st["over"]) and guard < 4000:
			guard += 1
			var seat := Durak.actor(st)
			if seat == "":
				break
			var act := Durak.bot_action(st)
			if act.is_empty():
				break
			match String(act["act"]):
				"attack": Durak.attack(st, seat, int(act["hand"]))
				"defend": Durak.defend(st, seat, int(act["hand"]))
				"bito": Durak.bito(st, seat)
				"take": Durak.take(st, seat)
		if guard >= 4000:
			stuck += 1
		var who := String(st["outcome"].get("loser", ""))
		if who != "":
			lose[who] = int(lose.get(who, 0)) + 1
	var parts := []
	for seat in MatchState.seat_ids(n):
		parts.append("%s %.1f%%" % [seat, 100.0 * float(lose.get(seat, 0)) / float(games)])
	print("дуракуб на %d: %s | зависаний %d | в колоде после раздачи %.1f | козырь у последнего %.0f%%" % [
		n, " ".join(parts), stuck, talon_left / float(games),
		100.0 * float(trump_last) / float(games)])

## В гонке победителем раунда должен объявляться набравший больше ЗА РАУНД.
func race_case(games: int) -> void:
	var same := 0
	var total := 0
	for g in games:
		var s := MatchState.new_match("race", 300 + g, "bot")
		s["seats"]["p"] = {"kind": "bot", "local": false, "name": "Бот 1"}
		var rng := MatchState.make_rng(31 + g)
		var guard := 0
		while not MatchState.is_match_over(s) and guard < 6000:
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
				# кто лидирует по матчу и кто взял раунд — теперь это разные вещи
				var lead := ""
				var best := -(1 << 30)
				for seat2 in s["order"]:
					if int(s["players"][seat2]["score"]) > best:
						best = int(s["players"][seat2]["score"])
						lead = String(seat2)
				var out := MatchState.close_round(s)
				total += 1
				if String(out["winner"]) == lead:
					same += 1
				if bool(out["match_over"]):
					break
				MatchState.new_round(s)
	print("гонка: победитель раунда совпал с лидером матча в %.0f%% раундов (%d)" % [
		100.0 * float(same) / float(total), total])

## «Территория»: сколько раундов заканчивается ничьей и как ложатся места.
func territory_case(n: int, games: int) -> void:
	var wins := {}
	var draws := 0
	var rounds := 0
	var draw_rounds := 0
	for g in games:
		var roster := []
		for i in n:
			roster.append({"kind": "bot", "local": false, "name": "Бот %d" % (i + 1)})
		var s := MatchState.new_match("territory", 700 + g, "roster", "p", "", "Ты", [], roster)
		# как в живой игре: первый ход разыгрывается битвой, иначе сиденье p всегда
		# начинает и замер по сиденьям показывает несуществующий перекос
		MatchState.apply_duel(s, String(MatchState.roll_duel(s)["winner"]))
		var rng := MatchState.make_rng(17 + g)
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
				var out := MatchState.close_round(s)
				rounds += 1
				if String(out["winner"]) == "":
					draw_rounds += 1
				if bool(out["match_over"]):
					break
				MatchState.new_round(s)
		var fin := MatchState.match_outcome(s)
		if String(fin["winner"]) == "":
			draws += 1
		else:
			wins[String(fin["winner"])] = int(wins.get(String(fin["winner"]), 0)) + 1
	var parts := []
	for seat in MatchState.seat_ids(n):
		parts.append("%s %.1f%%" % [seat, 100.0 * float(wins.get(seat, 0)) / float(games)])
	print("территория на %d: %s | ничьих матчей %.1f%% | ничьих раундов %.1f%%" % [
		n, " ".join(parts), 100.0 * float(draws) / float(games),
		100.0 * float(draw_rounds) / float(rounds)])
