extends SceneTree

## Временный прогон (гейм-дизайн-аудит). Кубы и комбинации:
##  * реальная доля типов в раздаче против весов;
##  * как часто ловушки вообще срабатывают;
##  * сколько очков приносит ход каждым типом;
##  * берёт ли раунд тот, кому досталось больше кубов данного типа;
##  * частота комбинаций и мёртвые строчки таблицы;
##  * доля пасов.

var TYPES := ["basic", "shield", "spikes", "mine", "jaw", "friendly", "warlock"]

func _init() -> void:
	print("=== C. Кубы, ловушки, комбинации ===")
	weights_check()
	for mode in ["classic", "big"]:
		run_set(mode, 2, 500)
	run_set("classic", 4, 400)
	quit()

func weights_check() -> void:
	var rng := MatchState.make_rng(4242)
	var cnt := {}
	var n := 200000
	for i in n:
		var t := MatchState.pick_type(rng)
		cnt[t] = int(cnt.get(t, 0)) + 1
	var parts := []
	for t in TYPES:
		parts.append("%s %.1f%%" % [t, 100.0 * float(cnt.get(t, 0)) / float(n)])
	print("раздача типов (200k бросков): %s" % " ".join(parts))

func run_set(mode: String, n: int, games: int) -> void:
	var played := {}          # сколько кубов типа сыграно
	var pts_by := {}          # суммарный итог хода этим типом
	var idx_by := {}          # средний номер хода в раунде (контроль ренты)
	var eat_pts := {}         # итог хода, когда съеден куб типа T
	var eat_cnt := {}
	var triggers := {"spikes": 0, "mine": 0, "jaw": 0, "friendly": 0, "warlock": 0}
	var combo_cnt := {}
	var combo_best := {}
	var moves := 0
	var passes := 0
	var win_tab := {}         # (тип, перевес) -> [побед, раундов]
	for t in TYPES:
		played[t] = 0
		pts_by[t] = 0.0
		idx_by[t] = 0.0
		eat_pts[t] = 0.0
		eat_cnt[t] = 0
	for g in games:
		var roster := []
		for i in n:
			roster.append({"kind": "bot", "local": false, "name": "Бот %d" % (i + 1)})
		var s := MatchState.new_match(mode, 21000 + g, "roster", "p", "", "Ты", [], roster)
		var d := MatchState.roll_duel(s)
		MatchState.apply_duel(s, String(d["winner"]))
		var rng := MatchState.make_rng((21000 + g) * 17 + 3)
		var order: Array = s["order"]
		var rt := {}
		var rbest := {}
		for st in order:
			rt[st] = {}
			rbest[st] = ""
		var guard := 0
		while not MatchState.is_match_over(s) and guard < 12000:
			guard += 1
			var seat := String(s["turn"])
			var ev := {}
			if MatchState.moves_left(s, seat) <= 0 or not MatchState.has_legal(s, seat):
				ev = MatchState.advance(s)
				if String(ev.get("event", "")) == "pass":
					passes += 1
			else:
				var mv := Bot.choose_move(s, seat, rng)
				if mv.is_empty():
					ev = MatchState.advance(s)
				else:
					var die: Dictionary = s["players"][seat]["hand"][int(mv["hand"])]
					var t := String(die["type"])
					var mi := int(s["players"][seat]["moves"])
					var target = s["board"][int(mv["cell"])]
					var tt := ""
					if target != null:
						tt = String(target["type"])
					var res := MatchState.play(s, seat, int(mv["hand"]), int(mv["cell"]))
					moves += 1
					played[t] = int(played[t]) + 1
					pts_by[t] = float(pts_by[t]) + float(int(res["pts"]))
					idx_by[t] = float(idx_by[t]) + float(mi)
					var rr: Dictionary = rt[seat]
					rr[t] = int(rr.get(t, 0)) + 1
					if tt != "":
						eat_pts[tt] = float(eat_pts[tt]) + float(int(res["pts"]))
						eat_cnt[tt] = int(eat_cnt[tt]) + 1
					var cb: Dictionary = res["combo"]
					var nm := String(cb.get("name", "")) if not cb.is_empty() else ""
					combo_cnt[nm] = int(combo_cnt.get(nm, 0)) + 1
					if nm != "" and int(cb.get("bonus", 0)) > combo_rank(String(rbest[seat])):
						rbest[seat] = nm
					for p in res["parts"]:
						var pt := String(p.get("t", ""))
						if pt == "Укололся на":
							triggers["spikes"] = int(triggers["spikes"]) + 1
						elif pt == "Подорвался на мине" or pt == "Пережевал мину":
							triggers["mine"] = int(triggers["mine"]) + 1
						elif pt == "Пережевал":
							triggers["jaw"] = int(triggers["jaw"]) + 1
						elif pt == "Дружески перенял":
							triggers["friendly"] = int(triggers["friendly"]) + 1
						elif pt == "Превратился в":
							triggers["warlock"] = int(triggers["warlock"]) + 1
					ev = MatchState.advance(s)
			if String(ev.get("event", "")) == "round_end":
				var out := MatchState.close_round(s)
				var w := String(out["winner"])
				for st in order:
					if String(rbest[st]) != "":
						combo_best[String(rbest[st])] = int(combo_best.get(String(rbest[st]), 0)) + 1
					else:
						combo_best["—"] = int(combo_best.get("—", 0)) + 1
				if w != "":
					for st in order:
						for t in TYPES:
							var mine_cnt := int(rt[st].get(t, 0))
							var other := 0
							for st2 in order:
								if st2 != st:
									other = maxi(other, int(rt[st2].get(t, 0)))
							var diff := clampi(mine_cnt - other, -2, 2)
							var key := "%s|%d" % [t, diff]
							var rec: Array = win_tab.get(key, [0, 0])
							rec[1] = int(rec[1]) + 1
							if String(st) == w:
								rec[0] = int(rec[0]) + 1
							win_tab[key] = rec
				for st in order:
					rt[st] = {}
					rbest[st] = ""
				if bool(out["match_over"]):
					break
				MatchState.new_round(s)
	print("")
	print("--- %s на %d, ходов %d, пасов %.1f%% ---" % [mode, n, moves, 100.0 * float(passes) / float(moves + passes)])
	var pl := []
	for t in TYPES:
		if int(played[t]) == 0:
			continue
		pl.append("%s: сыгран %.1f%%, итог хода %.1f (ход №%.1f)" % [t,
			100.0 * float(played[t]) / float(moves),
			float(pts_by[t]) / float(played[t]), float(idx_by[t]) / float(played[t])])
	print("  " + "\n  ".join(pl))
	var el := []
	for t in TYPES:
		if int(eat_cnt[t]) == 0:
			continue
		el.append("съел %s: %d раз, итог хода %.1f" % [t, int(eat_cnt[t]), float(eat_pts[t]) / float(eat_cnt[t])])
	print("  " + " | ".join(el))
	print("  срабатываний: шипы %d из %d (%.0f%%) · мина %d из %d (%.0f%%) · челюсть %d из %d (%.0f%%) · дружелюбный %d из %d (%.0f%%) · колдун %d из %d (%.0f%%)" % [
		int(triggers["spikes"]), int(played["spikes"]), 100.0 * float(triggers["spikes"]) / float(maxi(1, int(played["spikes"]))),
		int(triggers["mine"]), int(played["mine"]), 100.0 * float(triggers["mine"]) / float(maxi(1, int(played["mine"]))),
		int(triggers["jaw"]), int(played["jaw"]), 100.0 * float(triggers["jaw"]) / float(maxi(1, int(played["jaw"]))),
		int(triggers["friendly"]), int(played["friendly"]), 100.0 * float(triggers["friendly"]) / float(maxi(1, int(played["friendly"]))),
		int(triggers["warlock"]), int(played["warlock"]), 100.0 * float(triggers["warlock"]) / float(maxi(1, int(played["warlock"])))])
	var cl := []
	var ck := combo_cnt.keys()
	ck.sort()
	for k in ck:
		cl.append("%s %.1f%%" % ["нет" if String(k) == "" else String(k), 100.0 * float(combo_cnt[k]) / float(moves)])
	print("  комбо на ходу: " + " · ".join(cl))
	var bl := []
	var bk := combo_best.keys()
	bk.sort()
	var brt := 0
	for k in bk:
		brt += int(combo_best[k])
	for k in bk:
		bl.append("%s %.1f%%" % [String(k), 100.0 * float(combo_best[k]) / float(brt)])
	print("  лучшее комбо за раунд: " + " · ".join(bl))
	var wl := []
	for t in TYPES:
		var row := []
		for dd in [-2, -1, 0, 1, 2]:
			var rec: Array = win_tab.get("%s|%d" % [t, dd], [0, 0])
			if int(rec[1]) < 40:
				row.append("·")
			else:
				row.append("%.0f" % (100.0 * float(rec[0]) / float(rec[1])))
		wl.append("%s [%s]" % [t, " ".join(row)])
	print("  доля взятых раундов по перевесу типа (-2 -1 0 +1 +2): " + " | ".join(wl))

func combo_rank(nm: String) -> int:
	match nm:
		"ПАРА": return 5
		"ДВЕ ПАРЫ": return 10
		"СЕТ!": return 15
		"ФУЛЛ-ХАУС!": return 25
		"КАРЕ!": return 40
		"ПЯТЁРКА!": return 60
		"ШЕСТЁРКА!": return 100
		"ЛЕСЕНКА": return 10
		"ЛЕСЕНКА!": return 20
	return 0
