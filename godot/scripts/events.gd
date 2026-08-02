class_name Events
extends RefCounted

## Ивенты — покупки между раундами за накопленные очки.
##
## Раз в несколько раундов игроку выпадает предложение: за очки, набранные с
## начала матча (`total`), купить кубу преимущество. Предложения у игроков разные
## и выпадают независимо, от него всегда можно отказаться — очки тогда остаются.
##
## Почему в начале раунда, а не в конце: три ивента из четырёх работают с рукой, а
## рука раздаётся заново каждый раунд. Отдай их между раундами — и «поменяй
## значение куба» меняло бы куб, который сейчас уйдёт в сброс.
##
## Валюта — `total`, очки за матч. Это единственный счётчик, который живёт дольше
## раунда, и заодно у него появляется вторая роль: раньше он был скрытым
## тай-брейком, теперь на него можно играть.
##
## Здесь только правила. Показ, выбор игроком и боты — в интерфейсе.

const KINDS := ["buy", "reroll", "spy", "swap"]

const INFO := {
	"buy": {
		"title": "ТОРГОВЕЦ", "cost": 40,
		"text": "Выбери куб — он ляжет в твою руку прямо сейчас.",
	},
	"reroll": {
		"title": "ТОЧИЛЬЩИК", "cost": 25,
		"text": "Сточим грани: у твоего куба будет то значение, какое скажешь.",
	},
	"spy": {
		"title": "СОГЛЯДАТАЙ", "cost": 15,
		"text": "Покажу руку любого соперника. Смотри, пока раунд не начался.",
	},
	"swap": {
		"title": "МЕНЯЛА", "cost": 45,
		"text": "Покажу руку соперника и обменяю твой куб на любой из неё.",
	},
}

## Защита стоит дороже любого ивента: за неё платят, чтобы соперник не смог
## посмотреть руку и не смог обменяться. Держится до конца следующего ивента.
const WARD_COST := 60
const WARD_TITLE := "ОБЕРЕГ"

## С какого раунда возможны ивенты и как часто выпадают.
const FIRST_ROUND := 2
const CHANCE := 0.55

## Разыграть предложения на раунд: {seat: {"kind": ..., "offer": [...]}}.
##
## Всё от генератора матча, поэтому по сети у всех устройств выпадет одно и то
## же — обмениваться предложениями не нужно, как и с раздачей кубов.
static func roll(state: Dictionary) -> Dictionary:
	var out := {}
	if int(state["round"]) < FIRST_ROUND:
		return out
	var rng: RandomNumberGenerator = state["rng"]
	for seat in state["order"]:
		if MatchState.is_out(state, String(seat)):
			continue
		if rng.randf() > CHANCE:
			continue
		var kind := String(KINDS[rng.randi_range(0, KINDS.size() - 1)])
		# нечего смотреть и не с кем меняться — предложение бессмысленно
		if (kind == "spy" or kind == "swap") and rivals(state, String(seat)).is_empty():
			kind = "reroll"
		var offer := []
		if kind == "buy":
			for i in 3:
				offer.append(MatchState.random_die(rng))
		out[String(seat)] = {"kind": kind, "offer": offer}
	return out

## Живые соперники — те, у кого есть рука и кого можно выбрать целью.
static func rivals(state: Dictionary, seat: String) -> Array:
	var out := []
	for other in state["order"]:
		if String(other) == seat or MatchState.is_out(state, String(other)):
			continue
		out.append(String(other))
	return out

static func cost_of(kind: String) -> int:
	return int(INFO[kind]["cost"]) if INFO.has(kind) else 0

static func funds(state: Dictionary, seat: String) -> int:
	# в «Гонке» очки за матч и есть счёт: платить приходится прогрессом до 500
	if String(state["cfg"]["kind"]) == "race":
		return int(state["players"][seat]["score"])
	return int(state["players"][seat]["total"])

static func can_afford(state: Dictionary, seat: String, cost: int) -> bool:
	return funds(state, seat) >= cost

static func pay(state: Dictionary, seat: String, cost: int) -> void:
	if String(state["cfg"]["kind"]) == "race":
		state["players"][seat]["score"] = int(state["players"][seat]["score"]) - cost
	else:
		state["players"][seat]["total"] = int(state["players"][seat]["total"]) - cost

## Оберег: спасает от чужого ивента и сгорает, сработав.
static func warded(state: Dictionary, seat: String) -> bool:
	return bool(state["players"][seat].get("ward", false))

static func set_ward(state: Dictionary, seat: String, on: bool) -> void:
	state["players"][seat]["ward"] = on

# ------------------------------------------------------------- применение

## Купить куб из предложенных — он сразу в руке.
static func apply_buy(state: Dictionary, seat: String, offer: Array, idx: int) -> Dictionary:
	if idx < 0 or idx >= offer.size():
		return {"ok": false}
	pay(state, seat, cost_of("buy"))
	var die: Dictionary = (offer[idx] as Dictionary).duplicate()
	state["players"][seat]["hand"].append(die)
	return {"ok": true, "die": die}

## Заменить значение своего куба.
static func apply_reroll(state: Dictionary, seat: String, hand_idx: int, value: int) -> Dictionary:
	var hand: Array = state["players"][seat]["hand"]
	if hand_idx < 0 or hand_idx >= hand.size():
		return {"ok": false}
	pay(state, seat, cost_of("reroll"))
	var was := int(hand[hand_idx]["value"])
	hand[hand_idx]["value"] = clampi(value, 1, 6)
	return {"ok": true, "was": was, "now": int(hand[hand_idx]["value"])}

## Посмотреть руку соперника. Оберег закрывает её, но деньги всё равно списаны:
## соглядатай сходил и вернулся ни с чем.
static func apply_spy(state: Dictionary, seat: String, target: String) -> Dictionary:
	pay(state, seat, cost_of("spy"))
	if warded(state, target):
		set_ward(state, target, false)
		return {"ok": true, "blocked": true, "hand": []}
	return {"ok": true, "blocked": false, "hand": state["players"][target]["hand"].duplicate(true)}

## Обменять свой куб на куб из руки соперника.
static func apply_swap(state: Dictionary, seat: String, mine_idx: int,
		target: String, their_idx: int) -> Dictionary:
	var mine: Array = state["players"][seat]["hand"]
	var theirs: Array = state["players"][target]["hand"]
	if mine_idx < 0 or mine_idx >= mine.size() or their_idx < 0 or their_idx >= theirs.size():
		return {"ok": false}
	pay(state, seat, cost_of("swap"))
	if warded(state, target):
		set_ward(state, target, false)
		return {"ok": true, "blocked": true}
	var tmp: Dictionary = mine[mine_idx]
	mine[mine_idx] = theirs[their_idx]
	theirs[their_idx] = tmp
	return {"ok": true, "blocked": false}

## Купить оберег вместо предложенного ивента.
static func apply_ward(state: Dictionary, seat: String) -> Dictionary:
	if not can_afford(state, seat, WARD_COST):
		return {"ok": false}
	pay(state, seat, WARD_COST)
	set_ward(state, seat, true)
	return {"ok": true}

# ------------------------------------------------------------------- бот

## Что сделает бот со своим предложением. Пустой словарь — отказаться.
##
## Бот считает грубо: берёт то, что даёт кубы или прячет его собственную руку, и
## не тратит больше половины накопленного — иначе он в первом же ивенте спускал
## всё и проигрывал матч по очкам.
static func bot_choice(state: Dictionary, seat: String, ev: Dictionary,
		rng: RandomNumberGenerator) -> Dictionary:
	var kind := String(ev["kind"])
	var cost := cost_of(kind)
	var money := funds(state, seat)
	if money < cost or cost * 2 > money:
		return {}
	var foes := rivals(state, seat)
	match kind:
		"buy":
			# берём самый крупный из предложенных
			var best := 0
			var offer: Array = ev["offer"]
			for i in offer.size():
				if int(offer[i]["value"]) > int(offer[best]["value"]):
					best = i
			return {"act": "buy", "idx": best}
		"reroll":
			# точим самый слабый куб руки до шестёрки
			var hand: Array = state["players"][seat]["hand"]
			if hand.is_empty():
				return {}
			var worst := 0
			for i in hand.size():
				if int(hand[i]["value"]) < int(hand[worst]["value"]):
					worst = i
			if int(hand[worst]["value"]) >= 5:
				return {}
			return {"act": "reroll", "idx": worst, "value": 6}
		"spy":
			# знание чужой руки боту ничего не даёт: он и так не помнит её между
			# ходами. Тратить на это очки — только терять
			return {}
		"swap":
			var hand2: Array = state["players"][seat]["hand"]
			if hand2.is_empty() or foes.is_empty():
				return {}
			var target := String(foes[rng.randi_range(0, foes.size() - 1)])
			var their: Array = state["players"][target]["hand"]
			if their.is_empty():
				return {}
			var my_worst := 0
			for i in hand2.size():
				if int(hand2[i]["value"]) < int(hand2[my_worst]["value"]):
					my_worst = i
			var their_best := 0
			for i in their.size():
				if int(their[i]["value"]) > int(their[their_best]["value"]):
					their_best = i
			if int(their[their_best]["value"]) <= int(hand2[my_worst]["value"]) + 1:
				return {}
			return {"act": "swap", "idx": my_worst, "target": target, "their": their_best}
	return {}
