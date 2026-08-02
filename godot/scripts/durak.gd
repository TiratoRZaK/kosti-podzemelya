class_name Durak
extends RefCounted

## Дуракуб — подкидной дурак кубами. Перенос из веб-прототипа.
##
## 24 куба: четыре масти по значениям 1..6. Козырь — масть нижнего куба колоды.
## Отбивать можно старшим той же масти или любым козырем; подкидывать — значения,
## которые уже лежат на столе.
##
## Роли нейтральны: за атакующим и защищающимся сиденьем может сидеть человек,
## бот или игрок по сети. Фаза говорит, ЧТО делается, а кто это делает —
## выводится из attacker. В вебе фазы сначала назывались pAttack/pDefend и
## означали «игрок против ИИ», из-за чего режим не работал вдвоём.
##
## Здесь нет отображения и таймеров: действия меняют состояние и возвращают, что
## произошло, а показ и паузы — на слое интерфейса.

const SUITS := ["♠", "♥", "♦", "♣"]
const HAND_SIZE := 6
const MAX_TABLE := 6

## Вчетвером рука меньше: 24 куба на 4×6 — это раздача всей колоды, и партия
## превращалась в один проход по рукам. Прикупа не оставалось совсем, `refill_hands`
## не делала ничего, а козырь брался из нижнего куба, который при раздаче с конца
## всегда доставался последнему месту — козырь у него был в 100% раздач против 82%
## у остальных. Отсюда перекос «кто остался дуракубом»: 22/23/33/19 вместо 25.
## С рукой в пять кубов остаётся прикуп в четыре куба и разброс падает до 3 п.п.
static func hand_size(state: Dictionary) -> int:
	return 5 if state["order"].size() >= 4 else HAND_SIZE

# --------------------------------------------------------------- создание

## roster — состав на троих и четверых; пустой означает игру на двоих.
static func new_game(seed_value: int, opponent: String, my_seat: String = "p",
		foe_name: String = "Гость", my_name: String = "", roster: Array = []) -> Dictionary:
	var order: Array = MatchState.seat_ids(roster.size()) if roster.size() >= 2 else ["p", "e"]
	var players := {}
	for seat in order:
		players[seat] = {"hand": []}
	var state := {
		"mode": "durak", "kind": "durak", "seed": seed_value,
		"order": order, "players": players,
		"seats": MatchState.make_roster_seats(roster) if roster.size() >= 2 			else MatchState.make_seats(opponent, my_seat, foe_name, my_name),
		"talon": [], "discard": 0, "trump": 0,
		"table": [], "attacker": "p", "max_att": MAX_TABLE, "went_out": [], "passed": [],
		"phase": "attack", "shown_to": "", "over": false, "outcome": {},
	}
	state["rng"] = MatchState.make_rng(seed_value)
	state["talon"] = make_deck(state["rng"])
	# козырь — масть нижнего куба колоды
	state["trump"] = int(state["talon"][0]["suit"])
	for i in hand_size(state):
		for seat in order:
			players[seat]["hand"].append(state["talon"].pop_back())
	state["attacker"] = first_attacker(state)
	start_bout(state)
	return state

## Первым атакует владелец младшего козыря — как в картах. Раньше начинал всегда
## первый игрок, а начинать в дураке невыгодно: на прогонах он проигрывал 42%
## против 55%. Козырей нет ни у кого — начинает тот, у кого младший куб.
static func first_attacker(state: Dictionary) -> String:
	var trump := int(state["trump"])
	var best_seat := ""
	var best_rank := 1 << 30
	for seat in state["order"]:
		for die in hand_of(state, seat):
			# козырь важнее номинала, поэтому не-козырям добавляем разряд сверху
			var rank: int = int(die["value"]) + (0 if int(die["suit"]) == trump else 100)
			if rank < best_rank:
				best_rank = rank
				best_seat = seat
	return best_seat if best_seat != "" else String(state["order"][0])

static func make_deck(rng: RandomNumberGenerator) -> Array:
	var d := []
	for s in 4:
		for v in range(1, 7):
			d.append({"value": v, "suit": s})
	return MatchState.shuffled(rng, d)

# ------------------------------------------------------------------ правила

static func die_label(die: Dictionary) -> String:
	return "%d%s" % [int(die["value"]), SUITS[int(die["suit"])]]

## Бьёт ли защитный куб атакующий: старший той же масти либо любой козырь.
static func beats(defender: Dictionary, attacker: Dictionary, trump: int) -> bool:
	if int(defender["suit"]) == int(attacker["suit"]):
		return int(defender["value"]) > int(attacker["value"])
	return int(defender["suit"]) == trump

## Значения, которые уже на столе — только ими можно подкидывать.
static func table_values(state: Dictionary) -> Dictionary:
	var vs := {}
	for pair in state["table"]:
		vs[int(pair["a"]["value"])] = true
		if pair["d"] != null:
			vs[int(pair["d"]["value"])] = true
	return vs

static func can_throw(state: Dictionary, die: Dictionary) -> bool:
	if state["table"].is_empty():
		return true
	return table_values(state).has(int(die["value"]))

## Индекс первой неотбитой пары на столе; -1 если всё отбито.
static func undefended_idx(state: Dictionary) -> int:
	for i in state["table"].size():
		if state["table"][i]["d"] == null:
			return i
	return -1

## Защитник — следующий по кругу за атакующим, у кого ещё есть кубы. Вышедших
## пропускаем: иначе роль достаётся тому, кому нечем ни бить, ни подкидывать, и
## кон встаёт намертво — партия втроём зацикливалась.
static func defender_of(state: Dictionary, attacker: String) -> String:
	var order: Array = state["order"]
	var n := order.size()
	var i := order.find(attacker)
	for k in range(1, n + 1):
		var cand := String(order[(i + k) % n])
		if cand != attacker and not hand_of(state, cand).is_empty():
			return cand
	return String(order[(i + 1) % n])

## Следующий по кругу, у кого остались кубы: им передаётся право атаки.
static func next_with_dice(state: Dictionary, from: String) -> String:
	var order: Array = state["order"]
	var n := order.size()
	var i := order.find(from)
	for k in range(1, n + 1):
		var cand := String(order[(i + k) % n])
		if not hand_of(state, cand).is_empty():
			return cand
	return from

static func other_seat(state: Dictionary, seat: String) -> String:
	return MatchState.other_seat(state, seat)

static func hand_of(state: Dictionary, seat: String) -> Array:
	return state["players"][seat]["hand"]

## Кто сейчас действует: в фазе атаки — тот, чья очередь подкидывать, в защите —
## защищающийся.
static func actor(state: Dictionary) -> String:
	if String(state["phase"]) == "attack":
		return thrower_of(state)
	if String(state["phase"]) == "defend":
		return defender_of(state, String(state["attacker"]))
	return ""

## Чья очередь подкидывать.
##
## Первую атаку кона кладёт только атакующий. Дальше подкинуть может любой, кроме
## защитника, — это правило было записано в `attack` и в тесте, но до экрана не
## доходило: он спрашивал только атакующего, и втроём-вчетвером игра выглядела
## как «двое играют, остальные смотрят». Опрашиваем по кругу от атакующего,
## пропуская защитника, вышедших и тех, кто в этом коне уже спасовал.
## `strict` — только тот, кому реально есть чем подкинуть. Без него, когда
## подкидывать некому, возвращается атакующий: он и закроет кон «Бито», иначе
## `actor` вернул бы пустоту и поток встал бы посреди кона.
static func thrower_of(state: Dictionary, strict: bool = false) -> String:
	var attacker := String(state["attacker"])
	if state["table"].is_empty():
		return attacker
	var def := defender_of(state, attacker)
	var order: Array = state["order"]
	var n := order.size()
	var start := order.find(attacker)
	var passed: Array = state.get("passed", [])
	for k in n:
		var seat := String(order[(start + k) % n])
		if seat == def or passed.has(seat) or hand_of(state, seat).is_empty():
			continue
		# у кого нет подходящего значения — тот и не в очереди
		for die in hand_of(state, seat):
			if can_throw(state, die):
				return seat
	return "" if strict else attacker

# --------------------------------------------------------------------- кон

static func start_bout(state: Dictionary) -> void:
	state["table"] = []
	state["passed"] = []
	# вышедший не может атаковать: право уходит следующему с кубами
	if hand_of(state, String(state["attacker"])).is_empty():
		state["attacker"] = next_with_dice(state, String(state["attacker"]))
	# атак не больше, чем кубов было у защитника на начало кона
	state["max_att"] = mini(MAX_TABLE, hand_of(state, defender_of(state, String(state["attacker"]))).size())
	if check_end(state):
		return
	state["phase"] = "attack"

static func refill_hands(state: Dictionary) -> void:
	# первым добирает атакующий — как в картах
	# добирают по кругу, начиная с атакующего — как в картах
	var order: Array = state["order"]
	var start := order.find(String(state["attacker"]))
	for k in order.size():
		var seat := String(order[(start + k) % order.size()])
		var hand: Array = hand_of(state, seat)
		while hand.size() < hand_size(state) and not state["talon"].is_empty():
			hand.append(state["talon"].pop_back())

## Партия кончается, когда колода пуста и с кубами остался один. Он и дуракуб.
static func check_end(state: Dictionary) -> bool:
	# запоминаем порядок выхода: без него «кто вышел первым» спрашивали у соседа
	# по кругу, и на троих-четверых фраза называла не того в 38-66% партий
	if state["talon"].is_empty():
		for seat in state["order"]:
			if hand_of(state, String(seat)).is_empty() and not state["went_out"].has(String(seat)):
				state["went_out"].append(String(seat))
	if not state["talon"].is_empty():
		return false
	var with_dice := []
	for seat in state["order"]:
		if not hand_of(state, seat).is_empty():
			with_dice.append(seat)
	if with_dice.size() > 1:
		return false
	state["phase"] = "over"
	state["over"] = true
	if with_dice.is_empty():
		state["outcome"] = {"loser": "", "detail": "Все вышли одновременно — дуракубов сегодня нет."}
	else:
		var loser := String(with_dice[0])
		state["outcome"] = {"loser": loser, "detail": "Остался с кубами: %s" % MatchState.seat_name(state, loser)}
	return true

static func bout_beaten(state: Dictionary) -> void:
	state["passed"] = []
	state["discard"] = int(state["discard"]) + state["table"].size() * 2
	state["table"] = []
	refill_hands(state)
	# отбился — роли меняются
	state["attacker"] = defender_of(state, String(state["attacker"]))
	start_bout(state)

static func bout_taken(state: Dictionary, taker: String) -> void:
	var hand: Array = hand_of(state, taker)
	for pair in state["table"]:
		hand.append(pair["a"])
		if pair["d"] != null:
			hand.append(pair["d"])
	state["passed"] = []
	state["table"] = []
	refill_hands(state)
	# Взявший кон пропускает: право атаки уходит следующему за ним. На двоих это
	# прежнее «атакует тот же», а на троих-четверых снимает залипание пары —
	# остальные простаивали до двадцати конов подряд.
	if state["order"].size() > 2:
		state["attacker"] = next_with_dice(state, taker)
	start_bout(state)

# ------------------------------------------------------------------ действия

## Все действия проверяют, что сиденье действительно его: это же правило потом
## отсечёт чужие ходы по сети.
static func attack(state: Dictionary, seat: String, hand_idx: int) -> Dictionary:
	if String(state["phase"]) != "attack":
		return {}
	# подкидывать может любой, кроме защитника: на двоих это по-прежнему только
	# атакующий, втроём — и третий игрок тоже
	if seat == defender_of(state, String(state["attacker"])):
		return {}
	if state["table"].is_empty() and seat != String(state["attacker"]):
		return {}
	var hand: Array = hand_of(state, seat)
	if hand_idx < 0 or hand_idx >= hand.size():
		return {}
	var die: Dictionary = hand[hand_idx]
	if not can_throw(state, die):
		return {}
	if state["table"].size() >= int(state["max_att"]):
		return {}
	if hand_of(state, defender_of(state, String(state["attacker"]))).is_empty():
		return {}
	hand.remove_at(hand_idx)
	state["table"].append({"a": die, "d": null})
	# новое значение на столе — круг подкидывания открывается заново: тот, кто
	# спасовал раньше, мог не иметь чем подкинуть именно тогда
	state["passed"] = []
	state["phase"] = "defend"
	return {"act": "attack", "seat": seat, "die": die, "first": state["table"].size() == 1}

static func defend(state: Dictionary, seat: String, hand_idx: int) -> Dictionary:
	if String(state["phase"]) != "defend" or seat != defender_of(state, String(state["attacker"])):
		return {}
	var idx := undefended_idx(state)
	if idx < 0:
		return {}
	var hand: Array = hand_of(state, seat)
	if hand_idx < 0 or hand_idx >= hand.size():
		return {}
	var die: Dictionary = hand[hand_idx]
	var att: Dictionary = state["table"][idx]["a"]
	if not beats(die, att, int(state["trump"])):
		return {}
	hand.remove_at(hand_idx)
	state["table"][idx]["d"] = die
	state["phase"] = "attack"
	return {"act": "defend", "seat": seat, "die": die, "against": att}

## «Бито» от подкидывающего означает «мне добавить нечего». Кон закрывается,
## только когда так сказали все, кто мог подкинуть.
static func bito(state: Dictionary, seat: String) -> Dictionary:
	if String(state["phase"]) != "attack" or seat != thrower_of(state):
		return {}
	if state["table"].is_empty() or undefended_idx(state) >= 0:
		return {}
	var passed: Array = state["passed"]
	if not passed.has(seat):
		passed.append(seat)
	var next_thrower := thrower_of(state, true)
	if next_thrower != "":
		# слово переходит следующему — кон ещё живой
		return {"act": "pass", "seat": seat, "next": next_thrower}
	var n: int = state["table"].size()
	bout_beaten(state)
	return {"act": "bito", "seat": seat, "pairs": n}

static func take(state: Dictionary, seat: String) -> Dictionary:
	if String(state["phase"]) != "defend" or seat != defender_of(state, String(state["attacker"])):
		return {}
	var n: int = state["table"].size()
	bout_taken(state, seat)
	return {"act": "take", "seat": seat, "pairs": n}

## Единственное доступное действие: защитнику нечем отбить (остаётся «Взять») или
## атакующему нечем подкинуть (остаётся «Бито»). Выбора нет и скрывать нечего —
## стол открыт обоим, поэтому интерфейс выполняет это сам, без ширмы и нажатий.
static func forced_action(state: Dictionary, seat: String) -> String:
	if String(state["phase"]) == "defend":
		var idx := undefended_idx(state)
		if idx < 0:
			return ""
		var att: Dictionary = state["table"][idx]["a"]
		for die in hand_of(state, seat):
			if beats(die, att, int(state["trump"])):
				return ""
		return "take"
	if String(state["phase"]) == "attack":
		if state["table"].is_empty():
			return ""                      # первая атака — выбор за игроком
		if undefended_idx(state) >= 0:
			return ""
		if state["table"].size() >= int(state["max_att"]):
			return "bito"
		# смотреть надо на защитника, а не на соседа по кругу: `other_seat` берёт
		# следующее сиденье как есть, а `defender_of` пропускает вышедших из игры.
		# Втроём в 4,8% проверок, вчетвером в 10,9% сосед оказывался без кубов при
		# живом защитнике — интерфейс сам жал «Бито», хотя подкидывать было можно
		if hand_of(state, defender_of(state, String(state["attacker"]))).is_empty():
			return "bito"
		var vs := table_values(state)
		for die in hand_of(state, seat):
			if vs.has(int(die["value"])):
				return ""
		return "bito"
	return ""

# --------------------------------------------------------------------- бот

## Те же эвристики, что в вебе: отбиваться дешёвым, козыри берегём, пока в колоде
## есть запас.
static func bot_action(state: Dictionary) -> Dictionary:
	var seat := actor(state)
	if seat == "":
		return {}
	var forced := forced_action(state, seat)
	if forced == "take":
		return {"act": "take"}
	if forced == "bito":
		return {"act": "bito"}
	var hand: Array = hand_of(state, seat)
	var trump := int(state["trump"])
	var best := -1
	var best_cost := 1 << 30
	if String(state["phase"]) == "defend":
		var idx := undefended_idx(state)
		var att: Dictionary = state["table"][idx]["a"]
		for i in hand.size():
			var d: Dictionary = hand[i]
			if not beats(d, att, trump):
				continue
			var cost := int(d["value"]) + (8 if int(d["suit"]) == trump else 0)
			if cost < best_cost:
				best_cost = cost
				best = i
		if best < 0:
			return {"act": "take"}
		return {"act": "defend", "hand": best}
	# атака
	var first: bool = state["table"].is_empty()
	var vs := table_values(state)
	for i in hand.size():
		var d2: Dictionary = hand[i]
		if not first and not vs.has(int(d2["value"])):
			continue
		# пока в колоде запас, старшие кубы и козыри держим при себе
		if not first and state["talon"].size() > 2 and (int(d2["value"]) > 4 or int(d2["suit"]) == trump):
			continue
		var c := int(d2["value"]) + (8 if int(d2["suit"]) == trump else 0)
		if c < best_cost:
			best_cost = c
			best = i
	if best < 0:
		return {} if first else {"act": "bito"}
	return {"act": "attack", "hand": best}
