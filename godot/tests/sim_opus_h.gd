extends SceneTree

## Временный прогон (гейм-дизайн-аудит). Точечные проверки механики.

func _init() -> void:
	print("=== H1. Дуракуб: раздача на четверых ===")
	deal_check()
	print("")
	print("=== H2. Дуракуб: роли по местам ===")
	roles(4, 600)
	roles(3, 600)
	print("")
	print("=== H3. is_match_over обрывает bo3 на третьем раунде ===")
	over_check()
	print("")
	print("=== H4. forced_action смотрит на соседа, а не на защитника ===")
	forced_check(3, 400)
	forced_check(4, 400)
	quit()

func deal_check() -> void:
	for n in [2, 3, 4]:
		var roster := []
		for i in n:
			roster.append({"kind": "bot", "local": false, "name": "Б%d" % (i + 1)})
		var talon_left := 0
		var last_has_trump := 0
		var others_have_trump := 0.0
		var games := 2000
		for g in games:
			var s := Durak.new_game(110000 + g, "bot", "p", "", "Ты", roster)
			talon_left += s["talon"].size()
			var ids := MatchState.seat_ids(n)
			var last := String(ids[n - 1])
			var trump := int(s["trump"])
			var has := false
			for die in Durak.hand_of(s, last):
				if int(die["suit"]) == trump:
					has = true
			if has:
				last_has_trump += 1
			for seat in ids:
				if String(seat) == last:
					continue
				for die in Durak.hand_of(s, String(seat)):
					if int(die["suit"]) == trump:
						others_have_trump += 1.0
						break
		print("на %d: в колоде после раздачи %.1f куба | у последнего места есть козырь в %.1f%% раздач, у прочих в среднем %.1f%%" % [
			n, float(talon_left) / float(games),
			100.0 * float(last_has_trump) / float(games),
			100.0 * others_have_trump / float(games * (n - 1))])

func roles(n: int, games: int) -> void:
	var att := {}
	var def := {}
	var losers := {}
	for g in games:
		var roster := []
		for i in n:
			roster.append({"kind": "bot", "local": false, "name": "Б%d" % (i + 1)})
		var s := Durak.new_game(120000 + g, "bot", "p", "", "Ты", roster)
		var guard := 0
		var seen_att := {}
		while not bool(s["over"]) and guard < 4000:
			guard += 1
			var seat := Durak.actor(s)
			if seat == "":
				break
			var a := String(s["attacker"])
			if not seen_att.has(a) or String(s["phase"]) == "attack":
				pass
			att[a] = int(att.get(a, 0)) + 1
			def[Durak.defender_of(s, a)] = int(def.get(Durak.defender_of(s, a), 0)) + 1
			var act := Durak.bot_action(s)
			if act.is_empty():
				break
			match String(act["act"]):
				"attack": Durak.attack(s, seat, int(act["hand"]))
				"defend": Durak.defend(s, seat, int(act["hand"]))
				"bito": Durak.bito(s, seat)
				"take": Durak.take(s, seat)
		var l := String(s["outcome"].get("loser", ""))
		if l != "":
			losers[l] = int(losers.get(l, 0)) + 1
	var pa := []
	var pd := []
	var pl := []
	var ta := 0
	for seat in MatchState.seat_ids(n):
		ta += int(att.get(seat, 0))
	for seat in MatchState.seat_ids(n):
		pa.append("%s %.1f%%" % [seat, 100.0 * float(att.get(seat, 0)) / float(ta)])
		pd.append("%s %.1f%%" % [seat, 100.0 * float(def.get(seat, 0)) / float(ta)])
		pl.append("%s %.1f%%" % [seat, 100.0 * float(losers.get(seat, 0)) / float(games)])
	print("на %d: доля действий в роли атакующего %s | защитника %s | дуракуб %s" % [
		n, " ".join(pa), " ".join(pd), " ".join(pl)])

func over_check() -> void:
	for mode in ["draft", "territory"]:
		var a := run_bo3(mode, false)
		var b := run_bo3(mode, true)
		print("%s: цикл по is_match_over — раундов %.2f, победы %s; цикл по state.over — раундов %.2f, победы %s" % [
			mode, a["rounds"], a["wins"], b["rounds"], b["wins"]])

func run_bo3(mode: String, by_over: bool) -> Dictionary:
	var rounds := 0.0
	var wins := ""
	var w1 := 0
	var games := 300
	for g in games:
		var s := MatchState.new_match(mode, 131000 + g, "bot")
		s["seats"]["p"] = {"kind": "bot", "local": false, "name": "Бот 1"}
		var rng := MatchState.make_rng(131000 + g)
		var guard := 0
		while guard < 12000:
			if by_over:
				if bool(s["over"]):
					break
			else:
				if MatchState.is_match_over(s):
					break
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
		rounds += float(int(s["round"]))
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
			w1 += 1
	wins = "по победам %.0f%%" % (100.0 * float(w1) / float(games))
	return {"rounds": rounds / float(games), "wins": wins}

func forced_check(n: int, games: int) -> void:
	var mism := 0
	var checks := 0
	for g in games:
		var roster := []
		for i in n:
			roster.append({"kind": "bot", "local": false, "name": "Б%d" % (i + 1)})
		var s := Durak.new_game(140000 + g, "bot", "p", "", "Ты", roster)
		var guard := 0
		while not bool(s["over"]) and guard < 4000:
			guard += 1
			var seat := Durak.actor(s)
			if seat == "":
				break
			if String(s["phase"]) == "attack" and not s["table"].is_empty():
				checks += 1
				var neighbour := MatchState.other_seat(s, seat)
				var real_def := Durak.defender_of(s, String(s["attacker"]))
				if neighbour != real_def and Durak.hand_of(s, neighbour).is_empty() \
						and not Durak.hand_of(s, real_def).is_empty():
					mism += 1
			var act := Durak.bot_action(s)
			if act.is_empty():
				break
			match String(act["act"]):
				"attack": Durak.attack(s, seat, int(act["hand"]))
				"defend": Durak.defend(s, seat, int(act["hand"]))
				"bito": Durak.bito(s, seat)
				"take": Durak.take(s, seat)
	print("на %d: проверок фазы атаки %d, из них «сосед пуст, а защитник с кубами» %d (%.2f%%) — принудительное «Бито» не по правилу" % [
		n, checks, mism, 100.0 * float(mism) / float(maxi(1, checks))])
