class_name Rules
extends RefCounted

## Правила «Костей Подземелья»: типы кубов, комбинации, легальность ходов и
## подсчёт очков за ход.
##
## Это перенос ядра из веб-прототипа (`index.html`, функции comboBonus,
## legalTargets, applyMove). Веб-версия остаётся эталоном: тесты в
## `tests/test_rules.gd` прогоняют те же сценарии, что и харнесс прототипа, и
## должны давать те же числа. Расхождение = ошибка переноса.
##
## Здесь нет ни отображения, ни таймеров — только состояние и результат хода.
## Тот же принцип, что у applyMove в прототипе: логику можно крутить на сервере,
## в тестах и в боте, не поднимая интерфейс.

const LIVES_MAX := 3
const HAND_SIZE := 3
const FRIENDLY_CAP := 12
const SPIKES_PENALTY := 10
## Компенсация тому, кто ходит в раунде первым. Правило съедения «не меньше»
## отдаёт преимущество отвечающему: у второго счёт за раунд выше на 6%, и в
## режимах до трёх побед это копилось в перекос 44 на 55. Размер подобран
## прогонами — см. историю правок.
const FIRST_MOVE_KOMI := 6
const SHIELD_CHARGES := 2

## Типы кубов. hidden — противник не видит значок, пока куб не сработает.
const TYPES := {
	"basic":    {"icon": "",   "name": "Базовый",      "hidden": false},
	"shield":   {"icon": "🛡", "name": "Щит",           "hidden": false},
	"spikes":   {"icon": "🦔", "name": "Шипы",          "hidden": true},
	"mine":     {"icon": "💣", "name": "Мина",          "hidden": true},
	"jaw":      {"icon": "🦷", "name": "Челюсть",       "hidden": false},
	"friendly": {"icon": "🤝", "name": "Дружелюбный",   "hidden": false},
	"warlock":  {"icon": "🔮", "name": "Колдун",        "hidden": false},
}

## Веса раздачи: сумма 100. Держать синхронно с WEIGHTS веб-версии.
const WEIGHTS := [
	["basic", 50], ["shield", 12], ["spikes", 11], ["mine", 5],
	["jaw", 12], ["friendly", 5], ["warlock", 5],
]

# ---------------------------------------------------------------- комбинации

## Лучшая комбинация из значений своих кубов на доске.
## Возвращает {bonus:int, name:String, vals:Array} — vals нужны для подсветки.
static func combo_bonus(vals: Array) -> Dictionary:
	var count := {}
	for v in vals:
		count[v] = int(count.get(v, 0)) + 1
	var entries := []
	for v in count:
		entries.append({"v": int(v), "c": int(count[v])})
	# больше одинаковых — раньше; при равенстве старше значение.
	# ВНИМАНИЕ: sort_custom ждёт bool «a идёт раньше b», а не числовой компаратор
	# как в JS. Дословный перенос сравнения из веб-версии ломает фулл-хаус:
	# [5,5,5,4,4] определялось как «две пары».
	entries.sort_custom(func(a, b):
		if int(a["c"]) != int(b["c"]):
			return int(a["c"]) > int(b["c"])
		return int(a["v"]) > int(b["v"])
	)
	if entries.is_empty():
		return {"bonus": 0, "name": "", "vals": []}
	var e0: Dictionary = entries[0]
	var e1: Dictionary = entries[1] if entries.size() > 1 else {}
	var second_pair := not e1.is_empty() and int(e1["c"]) >= 2
	if int(e0["c"]) >= 6:
		return {"bonus": 100, "name": "ШЕСТЁРКА!", "vals": [e0["v"]]}
	if int(e0["c"]) == 5:
		return {"bonus": 60, "name": "ПЯТЁРКА!", "vals": [e0["v"]]}
	if int(e0["c"]) == 4:
		return {"bonus": 40, "name": "КАРЕ!", "vals": [e0["v"]]}
	if int(e0["c"]) == 3 and second_pair:
		return {"bonus": 25, "name": "ФУЛЛ-ХАУС!", "vals": [e0["v"], e1["v"]]}
	if int(e0["c"]) == 3:
		return {"bonus": 15, "name": "СЕТ!", "vals": [e0["v"]]}
	if int(e0["c"]) == 2 and second_pair:
		return {"bonus": 10, "name": "ДВЕ ПАРЫ", "vals": [e0["v"], e1["v"]]}
	# «Лесенка» — подряд идущие значения. Даёт вторую линию игры: собирать разные
	# вместо одинаковых. Без неё верх таблицы мёртв: на поле 3×2 пятёрка и
	# шестёрка недостижимы в принципе, и за 250 матчей не встретилось ни одной, а
	# в 44% раундов игрок не собирал вообще ничего.
	var run := longest_run(count)
	var run_bonus := run_score(run.size())
	# лесенка сравнивается с парами честно, по величине бонуса
	if int(e0["c"]) == 2 and second_pair and run_bonus <= 10:
		return {"bonus": 10, "name": "ДВЕ ПАРЫ", "vals": [e0["v"], e1["v"]]}
	if run_bonus > 0 and (int(e0["c"]) < 2 or run_bonus > 5):
		return {"bonus": run_bonus, "name": "ЛЕСЕНКА!" if run.size() >= 4 else "ЛЕСЕНКА", "vals": run}
	if int(e0["c"]) == 2 and second_pair:
		return {"bonus": 10, "name": "ДВЕ ПАРЫ", "vals": [e0["v"], e1["v"]]}
	if int(e0["c"]) == 2:
		return {"bonus": 5, "name": "ПАРА", "vals": [e0["v"]]}
	return {"bonus": 0, "name": "", "vals": []}

## Самая длинная цепочка подряд идущих значений среди своих кубов.
static func longest_run(count: Dictionary) -> Array:
	var best := []
	var cur := []
	# до 12, а не до 6: дружелюбный куб раздувается соседями до двенадцати, и
	# лесенка из таких значений просто не замечалась
	for v in range(1, FRIENDLY_CAP + 1):
		if count.has(v):
			cur.append(v)
			if cur.size() > best.size():
				best = cur.duplicate()
		else:
			cur = []
	return best

## Цена лесенки: три подряд +10, четыре +20, пять и больше +35.
static func run_score(n: int) -> int:
	if n >= 5:
		return 35
	if n == 4:
		return 20
	if n == 3:
		return 10
	return 0

# ------------------------------------------------------------------- доска

static func owner_vals(board: Array, seat: String) -> Array:
	var res := []
	for cell in board:
		if cell != null and cell["owner"] == seat:
			res.append(int(cell["v"]))
	return res

static func owner_count(board: Array, seat: String) -> int:
	return owner_vals(board, seat).size()

static func board_sum(board: Array, seat: String) -> int:
	var s := 0
	for v in owner_vals(board, seat):
		s += int(v)
	return s

static func neighbors(idx: int, cols: int, cells: int) -> Array:
	var r := idx / cols
	var c := idx % cols
	var res := []
	if c > 0: res.append(idx - 1)
	if c < cols - 1: res.append(idx + 1)
	if r > 0: res.append(idx - cols)
	if idx + cols < cells: res.append(idx + cols)
	return res

static func neighbor_sum(board: Array, idx: int, cols: int, cells: int) -> int:
	var s := 0
	for j in neighbors(idx, cols, cells):
		if board[j] != null:
			s += int(board[j]["v"])
	return s

## Куда можно поставить куб. Правило съедения: значение атакующего >= цели.
## Колдун ест куб любого значения, но щит останавливает и его — проверка щита
## идёт ДО проверки колдуна, это подтверждённое решение по балансу.
static func legal_targets(board: Array, die: Dictionary, seat: String) -> Array:
	var res := []
	for i in board.size():
		var cell = board[i]
		if cell == null:
			res.append(i)
			continue
		if cell["owner"] == seat:
			continue
		if int(cell["shield"]) > 0:
			continue
		if die["type"] == "warlock" or int(die["value"]) >= int(cell["v"]):
			res.append(i)
	return res

static func has_legal(board: Array, hand: Array, seat: String) -> bool:
	for die in hand:
		if not legal_targets(board, die, seat).is_empty():
			return true
	return false

## Клетки, из которых сложилась комбинация — для подсветки.
static func combo_cells(board: Array, seat: String, combo: Dictionary) -> Array:
	var res := []
	for v in combo["vals"]:
		for i in board.size():
			var cell = board[i]
			if cell != null and cell["owner"] == seat and int(cell["v"]) == int(v):
				res.append(i)
	return res

# --------------------------------------------------------------- ход

## Применить ход к состоянию. Меняет board/hand/deck/score и возвращает описание
## того, что произошло: жетоны карточки хода, итог, признак взрыва.
##
## Порядок операций повторяет веб-версию дословно, включая два неочевидных места:
##  * при взрыве мины ход сгорает целиком, поэтому уколы шипов НЕ начисляются
##    (иначе счёт уезжал в минус при показанном «0»);
##  * счёт меняется ровно на итог хода, без обрезки в нуль.
static func apply_move(state: Dictionary, seat: String, hand_idx: int, cell_idx: int) -> Dictionary:
	var board: Array = state["board"]
	var cols: int = int(state["cols"])
	var cells: int = board.size()
	var player: Dictionary = state["players"][seat]
	var hand: Array = player["hand"]
	var deck: Array = player["deck"]

	var die: Dictionary = hand[hand_idx]
	hand.remove_at(hand_idx)
	if not deck.is_empty():
		hand.append(deck.pop_back())

	var eat_pts := 0
	var jaw_pts := 0
	var spikes_hit := 0
	var mined := false
	var warlock_ate := false
	var extra := []          # жетоны событий: превращение, пережёвывание, взрыв
	var boom := []           # клетки для анимации взрыва
	var placed := -1

	var target = board[cell_idx]
	var piece := {
		"v": int(die["value"]),
		"type": String(die["type"]),
		"owner": seat,
		"shield": SHIELD_CHARGES if die["type"] == "shield" else 0,
	}

	if target != null:
		if target["type"] == "mine":
			board[cell_idx] = null
			mined = true
			boom.append(cell_idx)
			extra = [{"t": "Подорвался на мине", "icon": "💣"}]
		else:
			if die["type"] == "warlock":
				piece["v"] = int(target["v"])
				warlock_ate = true
				extra.append({"t": "Превратился в", "v": int(target["v"]), "icon": "🔮"})
			eat_pts += int(target["v"])
			if target["type"] == "spikes":
				spikes_hit += SPIKES_PENALTY
			board[cell_idx] = piece
			placed = cell_idx
	else:
		board[cell_idx] = piece
		placed = cell_idx

	if not mined:
		if die["type"] == "friendly":
			var add := neighbor_sum(board, cell_idx, cols, cells)
			if add > 0:
				var before := int(piece["v"])
				piece["v"] = mini(before + add, FRIENDLY_CAP)
				var got := int(piece["v"]) - before
				if got > 0:
					extra.append({"t": "Дружески перенял", "v": got, "icon": "🤝", "die": true})
		# челюсть доедает соседа СПРАВА, поэтому в последнем столбце бессильна
		if die["type"] == "jaw" and cell_idx % cols < cols - 1:
			var j := cell_idx + 1
			var t2 = board[j]
			if t2 != null and t2["owner"] != seat and int(t2["shield"]) <= 0:
				if t2["type"] == "mine":
					board[j] = null
					board[cell_idx] = null
					mined = true
					boom.append(j)
					boom.append(cell_idx)
					placed = -1
					extra = [{"t": "Пережевал мину", "icon": "💣"}]
				else:
					jaw_pts += int(t2["v"])
					if t2["type"] == "spikes":
						spikes_hit += SPIKES_PENALTY
					board[j] = null
					extra.append({"t": "Пережевал", "v": int(t2["v"]), "icon": "🦷"})

	# мина: ход сгорает без подсчёта — уколы шипов тоже не начисляются
	if mined:
		spikes_hit = 0

	# щиты противников выгорают после этого хода
	for cell in board:
		if cell != null and cell["owner"] != seat and int(cell["shield"]) > 0:
			cell["shield"] = int(cell["shield"]) - 1

	var gain := 0
	var parts := []
	var combo := {}
	if not mined:
		if eat_pts != 0:
			gain += eat_pts
			if not warlock_ate:
				parts.append({"t": "Съел", "v": eat_pts})
		if jaw_pts != 0:
			gain += jaw_pts
		var bs := board_sum(board, seat)
		if bs != 0:
			var mine_cells := []
			for i in board.size():
				if board[i] != null and board[i]["owner"] == seat:
					mine_cells.append(i)
			gain += bs
			parts.append({"t": "Кубы на поле", "v": bs, "hl": mine_cells})
		var cb := combo_bonus(owner_vals(board, seat))
		if int(cb["bonus"]) != 0:
			gain += int(cb["bonus"])
			combo = cb
			var nm: String = String(cb["name"]).replace("!", "")
			var chl := combo_cells(board, seat, cb)
			parts.append({
				"t": nm.substr(0, 1) + nm.substr(1).to_lower(),
				"v": int(cb["bonus"]), "cls": "combo", "hl": chl,
				"ci": chl[0] if not chl.is_empty() else cell_idx,
			})
		if spikes_hit != 0:
			parts.append({"t": "Укололся на", "v": spikes_hit, "neg": true, "icon": "🦔", "cls": "foe"})
		parts.append_array(extra)
	else:
		parts = extra

	# счёт меняется ровно на итог хода — без обрезки в нуль, иначе карточка
	# показывает одно число, а счётчик двигается на другое
	var delta := gain - spikes_hit
	player["score"] = int(player["score"]) + delta
	player["moves"] = int(player["moves"]) + 1
	# «Территория» считает не кубы в конце раунда, а сумму удержанных клеток после
	# каждого хода: иначе раунд забирал тот, кто ходит последним, — второй игрок
	# брал 60% раундов просто по очереди хода
	player["held"] = int(player.get("held", 0)) + owner_count(board, seat)

	return {
		"seat": seat, "cell": cell_idx, "parts": parts, "pts": delta,
		"mined": mined, "combo": combo, "boom": boom, "placed": placed,
	}

## Сумма очков по жетонам карточки. Контракт с игроком: она обязана равняться
## итогу хода. Жетон со значением куба («Дружески перенял») очков не даёт.
static func chip_sum(parts: Array) -> int:
	var s := 0
	for p in parts:
		if not p.has("v"):
			continue
		if p.get("die", false):
			s += int(p.get("pts", 0))
			continue
		s += -int(p["v"]) if p.get("neg", false) else int(p["v"])
	return s
