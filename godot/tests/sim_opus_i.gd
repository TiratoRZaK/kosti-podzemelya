extends SceneTree

## Временный прогон (гейм-дизайн-аудит). Цена скрытности ловушек.
## Бот ловушек не видит. Сравниваем его ход с ходом «ясновидящего»: та же оценка,
## но с честной поправкой за шипы (−10) и мину (ход сгорает). Если выбор
## совпадает — знание ловушки решения не меняет, и прятать её незачем.

func _init() -> void:
	print("=== I. Сколько стоит незнание ловушек ===")
	for mode in ["classic", "big"]:
		run_set(mode, 2, 400)
	run_set("classic", 4, 300)
	quit()

func run_set(mode: String, n: int, games: int) -> void:
	var moves := 0
	var trap_moves := 0        # ход, где бот наступил на ловушку
	var spikes_moves := 0
	var mine_moves := 0
	var changed := 0           # ясновидящий выбрал бы другое
	var changed_spikes := 0
	var changed_mine := 0
	var loss := 0.0            # разница оценок между слепым и ясновидящим выбором
	var trap_visible := 0      # ходов, где на доске вообще была видимая ловушка соперника
	for g in games:
		var roster := []
		for i in n:
			roster.append({"kind": "bot", "local": false, "name": "Бот %d" % (i + 1)})
		var s := MatchState.new_match(mode, 151000 + g, "roster", "p", "", "Ты", [], roster)
		var d := MatchState.roll_duel(s)
		MatchState.apply_duel(s, String(d["winner"]))
		var rng := MatchState.make_rng((151000 + g) * 37 + 8)
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
					moves += 1
					# есть ли на доске чужая ловушка вообще
					var any_trap := false
					for c in s["board"]:
						if c != null and String(c["owner"]) != seat and \
								(String(c["type"]) == "spikes" or String(c["type"]) == "mine"):
							any_trap = true
					if any_trap:
						trap_visible += 1
					var tgt = s["board"][int(mv["cell"])]
					var tt := "" if tgt == null else String(tgt["type"])
					if tt == "spikes":
						spikes_moves += 1
						trap_moves += 1
					elif tt == "mine":
						mine_moves += 1
						trap_moves += 1
					if any_trap:
						# сравниваем ЛУЧШИЙ слепой ход с ЛУЧШИМ ясновидящим, а не с
						# фактическим: у бота в выборе есть шум, и он бы засчитался
						# как «знание изменило решение»
						var bb := -(1 << 30)
						var bh := -1
						var bc := -1
						var cb := -(1 << 30)
						var ch := -1
						var cc := -1
						var hand: Array = s["players"][seat]["hand"]
						for hi in hand.size():
							for ci in Rules.legal_targets(s["board"], hand[hi], seat):
								var vb := clair_value(s, seat, hi, ci, false)
								if vb > bb:
									bb = vb
									bh = hi
									bc = ci
								var vc := clair_value(s, seat, hi, ci, true)
								if vc > cb:
									cb = vc
									ch = hi
									cc = ci
						if bh != ch or bc != cc:
							changed += 1
							loss += float(cb - clair_value(s, seat, bh, bc, true))
							var bt = s["board"][bc]
							var btt := "" if bt == null else String(bt["type"])
							if btt == "spikes":
								changed_spikes += 1
							elif btt == "mine":
								changed_mine += 1
					MatchState.play(s, seat, int(mv["hand"]), int(mv["cell"]))
					ev = MatchState.advance(s)
			if String(ev.get("event", "")) == "round_end":
				var out := MatchState.close_round(s)
				if bool(out["match_over"]):
					break
				MatchState.new_round(s)
	print("%s на %d: ходов %d, из них с чужой ловушкой на доске %.1f%%" % [
		mode, n, moves, 100.0 * float(trap_visible) / float(moves)])
	print("      наступил на шипы %.1f%% ходов, на мину %.1f%% | зная ловушки, бот сходил бы иначе в %.1f%% ходов «при живой ловушке» (из них шипы %d, мина %d) | средняя потеря оценки %.1f" % [
		100.0 * float(spikes_moves) / float(moves), 100.0 * float(mine_moves) / float(moves),
		100.0 * float(changed) / float(maxi(1, trap_visible)), changed_spikes, changed_mine,
		loss / float(maxi(1, changed))])

## Оценка хода с честной поправкой на ловушки.
func clair_value(s: Dictionary, seat: String, hi: int, ci: int, see: bool) -> int:
	var hand: Array = s["players"][seat]["hand"]
	var die: Dictionary = hand[hi]
	var v := Bot.eval_move(s, die, ci, seat)
	if not see:
		return v
	var tgt = s["board"][ci]
	if tgt != null:
		if String(tgt["type"]) == "spikes":
			v -= Rules.SPIKES_PENALTY
		elif String(tgt["type"]) == "mine":
			# ход сгорает: ни очков, ни клетки, куб потерян
			v = -int(Rules.board_sum(s["board"], seat))
	# челюсть тоже может доесть ловушку справа
	var cols := int(s["cols"])
	if String(die["type"]) == "jaw" and ci % cols < cols - 1:
		var t2 = s["board"][ci + 1]
		if t2 != null and String(t2["owner"]) != seat and int(t2["shield"]) <= 0:
			if String(t2["type"]) == "spikes":
				v -= Rules.SPIKES_PENALTY
			elif String(t2["type"]) == "mine":
				v = -int(Rules.board_sum(s["board"], seat))
	return v
