class_name Bot
extends RefCounted

## Жадная оценка хода. Перенос evalMove/botTurn из веб-прототипа.
##
## Бот НЕ знает о скрытых типах (шипы, мина) — это подтверждённая фича: ловушки
## должны работать и против него. Поэтому оценка смотрит только на значения.

## Насколько хорош ход. Считает по копии доски, состояние не меняет.
static func eval_move(state: Dictionary, die: Dictionary, cell_idx: int, seat: String) -> int:
	var board: Array = state["board"]
	var cols: int = int(state["cols"])
	var cells: int = board.size()
	var b := []
	for cell in board:
		b.append(null if cell == null else cell.duplicate())

	var gain := 0
	var target = b[cell_idx]
	var piece := {
		"v": int(die["value"]), "type": String(die["type"]), "owner": seat,
		"shield": Rules.SHIELD_CHARGES if die["type"] == "shield" else 0,
	}
	if target != null:
		if die["type"] == "warlock":
			piece["v"] = int(target["v"])
		# съедение вдвойне ценно: и очки, и лишение соперника дохода
		gain += int(target["v"]) * 2
	b[cell_idx] = piece

	if die["type"] == "friendly":
		piece["v"] = mini(int(piece["v"]) + Rules.neighbor_sum(b, cell_idx, cols, cells), Rules.FRIENDLY_CAP)
	if die["type"] == "jaw" and cell_idx % cols < cols - 1:
		var t2 = b[cell_idx + 1]
		if t2 != null and t2["owner"] != seat and int(t2["shield"]) <= 0:
			gain += int(t2["v"]) * 2
			b[cell_idx + 1] = null

	gain += Rules.board_sum(b, seat)
	gain += int(Rules.combo_bonus(Rules.owner_vals(b, seat))["bonus"])
	# щит нельзя съесть два хода — эта рента доживёт до следующего хода
	if die["type"] == "shield":
		gain += int(piece["v"])
	# Сколько комбо отняли у соперников: без этого бот не мешал собирать пары.
	# Считаем по всем, а не по одному — `other_seat` брал соседа по кругу, и за
	# столом на четверых бот не видел двоих из трёх.
	for opp in state["order"]:
		if String(opp) == seat:
			continue
		gain += int(Rules.combo_bonus(Rules.owner_vals(board, String(opp)))["bonus"])
		gain -= int(Rules.combo_bonus(Rules.owner_vals(b, String(opp)))["bonus"])
	if String(state["cfg"].get("win_by", "")) == "count":
		gain += Rules.owner_count(b, seat) * 10
		if target != null:
			gain += 10
	return gain

## Выбрать ход: {"hand": i, "cell": j} или пустой словарь, если ходить нечем.
## Шум пропорционален оценке — фиксированная добавка при счёте в сотни бота
## не расшатывала, и он играл предсказуемо.
static func choose_move(state: Dictionary, seat: String, rng: RandomNumberGenerator) -> Dictionary:
	var hand: Array = state["players"][seat]["hand"]
	var best := {}
	var best_score := -1.0
	for hi in hand.size():
		var die: Dictionary = hand[hi]
		for ci in Rules.legal_targets(state["board"], die, seat):
			var raw := float(eval_move(state, die, ci, seat))
			var score := raw + rng.randf() * maxf(4.0, raw * 0.06)
			if best.is_empty() or score > best_score:
				best_score = score
				best = {"hand": hi, "cell": ci}
	return best
