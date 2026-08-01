class_name MatchState
extends RefCounted

## Состояние матча и поток игры: режимы, сиденья, раздача, передача хода,
## исходы раунда и матча.
##
## Перенос из веб-прототипа (initMatch/newRound/advance/endRound/matchEnd).
## Как и там, состояние — обычный словарь: так его проще сериализовать для
## сетевой игры и сравнивать в тестах.
##
## Здесь нет отображения и таймеров. `advance()` не рисует и ничего не планирует
## — она возвращает описание события, а показывать его и выдерживать паузы будет
## слой интерфейса. Это то, ради чего в вебе разделяли applyMove/presentMove.

const HAND_SIZE := Rules.HAND_SIZE
const LIVES_MAX := Rules.LIVES_MAX

const MODES := {
	"classic": {
		"title": "КЛАССИКА", "sub": "3 жизни · поле 3×2 · 6 ходов в раунде",
		"cols": 3, "cells": 6, "moves": 6, "kind": "lives", "deck": "per_round", "deck_size": 10,
	},
	"big": {
		"title": "БОЛЬШАЯ ДОСКА", "sub": "3 жизни · поле 3×3 · 10 ходов в раунде",
		"cols": 3, "cells": 9, "moves": 10, "kind": "lives", "deck": "per_round", "deck_size": 14,
	},
	"draft": {
		"title": "СВОЯ КОЛОДА", "sub": "18 кубов из 30 · у соперника та же колода · 3 раунда",
		"cols": 3, "cells": 6, "moves": 6, "kind": "bo3", "win_by": "score", "deck": "draft",
	},
	"race": {
		"title": "ГОНКА ДО 500", "sub": "общая колода · счёт копится · кто первым наберёт 500",
		"cols": 3, "cells": 6, "moves": 6, "kind": "race", "target": 500, "deck": "shared",
	},
	"territory": {
		"title": "ТЕРРИТОРИЯ", "sub": "3 раунда · за каждый ход считаются удержанные клетки",
		"cols": 3, "cells": 6, "moves": 6, "kind": "bo3", "win_by": "count", "deck": "draft",
	},
}
const MODE_ORDER := ["classic", "big", "draft", "race", "territory"]

## Дуракуб живёт на отдельной машине состояний (Durak), поэтому в MODES его нет:
## всё, что перебирает MODE_ORDER, ждёт боевой матч с доской и очками.
const DURAK_MODE := {
	"title": "ДУРАКУБ", "sub": "подкидной дурак кубами · 24 куба · 4 масти · козырь",
	"kind": "durak",
}

# ------------------------------------------------------------------ сиденья

## За сиденьем сидит человек, бот или (в будущем) игрок по сети. `local` — играет
## на этом устройстве. Через это выражается всё: ждать ввода или звать бота, как
## называть игрока, нужна ли ширма.
## opponent: "bot" — игра против бота, "human" — хотсит на одном устройстве,
## "remote" — соперник по сети. my_seat важен только для сети: у клиента своё
## сиденье второе, и именно оно local.
## my_name — имя из профиля игрока. Пустое означает «профиля нет», тогда сиденья
## зовутся как раньше: «Ты» против бота и «Игрок 1» в хотсите.
static func make_seats(opponent: String, my_seat: String = "p", foe_name: String = "Соперник",
		my_name: String = "") -> Dictionary:
	if opponent == "human":
		return {
			"p": {"kind": "human", "local": true, "name": my_name if my_name != "" else "Игрок 1"},
			"e": {"kind": "human", "local": true, "name": "Игрок 2"},
		}
	if opponent == "remote":
		var mine := {"kind": "human", "local": true, "name": my_name if my_name != "" else "Ты"}
		var theirs := {"kind": "remote", "local": false, "name": foe_name}
		return {"p": mine, "e": theirs} if my_seat == "p" else {"p": theirs, "e": mine}
	return {
		"p": {"kind": "human", "local": true, "name": my_name if my_name != "" else "Ты"},
		"e": {"kind": "bot", "local": false, "name": "Враг"},
	}

static func seat_kind(state: Dictionary, seat: String) -> String:
	return String(state["seats"][seat]["kind"])

static func seat_name(state: Dictionary, seat: String) -> String:
	return String(state["seats"][seat]["name"])

static func seat_local(state: Dictionary, seat: String) -> bool:
	return bool(state["seats"][seat]["local"])

static func seat_is_human(state: Dictionary, seat: String) -> bool:
	return seat_kind(state, seat) == "human"

## Оба сиденья заняты местными людьми — только тогда состояние прячут ширмой.
## При игре по сети удалённое сиденье не local, и ширма отключается сама.
static func shared_device(state: Dictionary) -> bool:
	for seat in state["order"]:
		if not (seat_is_human(state, seat) and seat_local(state, seat)):
			return false
	return state["order"].size() > 1

## Ширма нужна, когда экран сейчас «принадлежит» другому человеку.
static func needs_veil(state: Dictionary, seat: String) -> bool:
	return shared_device(state) and seat_is_human(state, seat) and state["shown_to"] != seat

# ------------------------------------------------------------------ раздача

## Случайность идёт через один генератор на матч: тот же сид — та же раздача.
## Для сетевой игры этого достаточно, чтобы у клиентов совпали кубы.
static func make_rng(seed_value: int) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	return rng

static func pick_type(rng: RandomNumberGenerator) -> String:
	var roll := rng.randi_range(0, 99)
	var acc := 0
	for pair in Rules.WEIGHTS:
		acc += int(pair[1])
		if roll < acc:
			return String(pair[0])
	return "basic"

static func random_die(rng: RandomNumberGenerator) -> Dictionary:
	return {"value": rng.randi_range(1, 6), "type": pick_type(rng)}

static func make_deck(rng: RandomNumberGenerator, n: int) -> Array:
	var d := []
	for i in n:
		d.append(random_die(rng))
	return d

static func shuffled(rng: RandomNumberGenerator, arr: Array) -> Array:
	var a := arr.duplicate(true)
	for i in range(a.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var t = a[i]
		a[i] = a[j]
		a[j] = t
	return a

# --------------------------------------------------------------- создание

static func new_match(mode_key: String, seed_value: int, opponent: String,
		my_seat: String = "p", foe_name: String = "Соперник", my_name: String = "") -> Dictionary:
	var cfg: Dictionary = MODES[mode_key]
	var order := ["p", "e"]
	var players := {}
	for seat in order:
		players[seat] = {
			"hand": [], "deck": [], "score": 0, "total": 0,
			"moves": 0, "lives": LIVES_MAX, "wins": 0, "held": 0,
		}
	var state := {
		"mode": mode_key, "cfg": cfg, "seed": seed_value,
		"cols": int(cfg["cols"]), "board": [],
		"order": order, "players": players,
		"seats": make_seats(opponent, my_seat, foe_name, my_name),
		"turn": "p", "first_seat": "p",
		"round": 0, "history": [], "shown_to": "", "veil": "",
		"over": false, "outcome": {},
	}
	state["rng"] = make_rng(seed_value)
	# общая колода гонки: одна база, перемешанная каждому по-своему
	if String(cfg["deck"]) == "shared":
		var base := make_deck(state["rng"], 18)
		players["p"]["deck"] = shuffled(state["rng"], base)
		players["e"]["deck"] = shuffled(state["rng"], base)
	# драфт: 18 кубов из 30 предложенных, у соперника та же колода. Экран выбора
	# ещё не перенесён, поэтому набор случайный — как кнопка «Случайно» в вебе.
	# Предложенные 30 держим в состоянии: экран драфта потом возьмёт их отсюда.
	if String(cfg["deck"]) == "draft":
		var offer := make_deck(state["rng"], 30)
		state["draft_offer"] = offer
		var picked := shuffled(state["rng"], offer).slice(0, 18)
		players["p"]["deck"] = shuffled(state["rng"], picked)
		players["e"]["deck"] = shuffled(state["rng"], picked)
	new_round(state)
	return state

static func new_round(state: Dictionary) -> void:
	var cfg: Dictionary = state["cfg"]
	state["round"] = int(state["round"]) + 1
	state["board"] = []
	for i in int(cfg["cells"]):
		state["board"].append(null)
	for seat in state["order"]:
		state["players"][seat]["moves"] = 0
		state["players"][seat]["held"] = 0
		if String(cfg["kind"]) != "race":
			state["players"][seat]["score"] = 0
	if String(cfg["deck"]) == "per_round":
		for seat in state["order"]:
			state["players"][seat]["deck"] = make_deck(state["rng"], int(cfg["deck_size"]))
			state["players"][seat]["hand"] = []
	# драфт живёт три раунда одной колодой: доносим руку тем, что осталось
	if String(cfg["deck"]) == "draft":
		pass
	# В гонке колода досыпается одинаковой партией обоим. Смотреть надо на того,
	# у кого меньше: раньше проверялся только первый игрок, и второй мог остаться
	# без кубов, пока у первого колода ещё не подошла к концу.
	var thinnest := 1 << 30
	for seat in state["order"]:
		thinnest = mini(thinnest, state["players"][seat]["deck"].size())
	if String(cfg["deck"]) == "shared" and thinnest < 6:
		var extra := make_deck(state["rng"], 18)
		for seat in state["order"]:
			var d: Array = state["players"][seat]["deck"]
			state["players"][seat]["deck"] = shuffled(state["rng"], extra) + d
	for seat in state["order"]:
		var pl: Dictionary = state["players"][seat]
		while pl["hand"].size() < HAND_SIZE and not pl["deck"].is_empty():
			pl["hand"].append(pl["deck"].pop_back())
	# Первым ходит победитель прошлого раунда. Ходить первым невыгодно (правило
	# съедения «не меньше» отдаёт преимущество отвечающему), а при простом
	# чередовании в трёх раундах одно сиденье начинало дважды — и режимы «до трёх
	# побед» ложились в сторону второго игрока.
	state["turn"] = String(state["first_seat"])
	state["first_seat"] = other_seat(state, String(state["first_seat"]))
	state["shown_to"] = ""
	state["history"] = []

# ------------------------------------------------------------- поток хода

static func other_seat(state: Dictionary, seat: String) -> String:
	var order: Array = state["order"]
	var i := order.find(seat)
	return String(order[(i + 1) % order.size()])

static func moves_left(state: Dictionary, seat: String) -> int:
	return int(state["cfg"]["moves"]) - int(state["players"][seat]["moves"])

static func all_moves_spent(state: Dictionary) -> bool:
	for seat in state["order"]:
		if moves_left(state, seat) > 0:
			return false
	return true

## Следующее сиденье по кругу, у которого остались ходы; иначе ходит тот же.
static func next_seat(state: Dictionary, from: String) -> String:
	var order: Array = state["order"]
	var n := order.size()
	var i := order.find(from)
	for k in range(1, n + 1):
		var cand := String(order[(i + k) % n])
		if moves_left(state, cand) > 0:
			return cand
	return from

static func has_legal(state: Dictionary, seat: String) -> bool:
	return Rules.has_legal(state["board"], state["players"][seat]["hand"], seat)

## Сделать ход и записать его в историю.
static func play(state: Dictionary, seat: String, hand_idx: int, cell_idx: int) -> Dictionary:
	var res := Rules.apply_move(state, seat, hand_idx, cell_idx)
	state["history"].append({
		"n": state["history"].size() + 1, "who": seat,
		"pts": int(res["pts"]), "parts": res["parts"], "mined": bool(res["mined"]),
	})
	return res

## Передать ход. Возвращает событие для слоя интерфейса:
##   {"event": "round_end"} — все отыграли лимит ходов
##   {"event": "pass", "seat": s} — ходить нечем, ход сгорает
##   {"event": "turn", "seat": s, "veil": bool} — ждём этого игрока или бота
## Пас не просит ширмы: выбора нет, и экран не должен переезжать к пасующему —
## иначе сидящий увидит его руку.
static func advance(state: Dictionary) -> Dictionary:
	# после конца матча ходов нет: устаревший таймер интерфейса не должен
	# двигать счётчики поверх закрытого состояния
	if bool(state["over"]):
		return {"event": "over"}
	if all_moves_spent(state):
		return {"event": "round_end"}
	var nxt := next_seat(state, String(state["turn"]))
	state["turn"] = nxt
	if not has_legal(state, nxt):
		state["players"][nxt]["moves"] = int(state["players"][nxt]["moves"]) + 1
		state["history"].append({
			"n": state["history"].size() + 1, "who": nxt, "pts": 0,
			"parts": [{"t": "Пас — нет ходов", "icon": "⏭"}], "mined": false,
		})
		return {"event": "pass", "seat": nxt}
	return {"event": "turn", "seat": nxt, "veil": needs_veil(state, nxt)}

# ----------------------------------------------------------------- исходы

## Кто взял раунд. Возвращает {"winner": seat|"", "detail": String}.
static func round_outcome(state: Dictionary) -> Dictionary:
	var cfg: Dictionary = state["cfg"]
	var a := String(state["order"][0])
	var b := String(state["order"][1])
	if String(cfg.get("win_by", "")) == "count":
		var ca := int(state["players"][a].get("held", 0))
		var cb := int(state["players"][b].get("held", 0))
		var w := "" if ca == cb else (a if ca > cb else b)
		return {"winner": w, "detail": "Удержано клеток %d : %d" % [ca, cb]}
	var sa := int(state["players"][a]["score"])
	var sb := int(state["players"][b]["score"])
	var w2 := "" if sa == sb else (a if sa > sb else b)
	return {"winner": w2, "detail": "Счёт %d : %d" % [sa, sb]}

## Закрыть раунд: списать жизнь или засчитать победу в раунде. Возвращает
## {"winner": seat|"", "detail": String, "match_over": bool}.
static func close_round(state: Dictionary) -> Dictionary:
	var cfg: Dictionary = state["cfg"]
	var out := round_outcome(state)
	var kind := String(cfg["kind"])
	if kind == "lives":
		if out["winner"] != "":
			var loser := other_seat(state, String(out["winner"]))
			state["players"][loser]["lives"] = int(state["players"][loser]["lives"]) - 1
	elif kind == "bo3":
		if out["winner"] != "":
			var w: String = String(out["winner"])
			state["players"][w]["wins"] = int(state["players"][w]["wins"]) + 1
		for seat in state["order"]:
			state["players"][seat]["total"] = int(state["players"][seat]["total"]) + int(state["players"][seat]["score"])
	# Следующий раунд начинает победитель этого. Ходить первым невыгодно: правило
	# съедения «не меньше» отдаёт преимущество отвечающему, и раньше при простом
	# чередовании в трёх раундах одно сиденье начинало дважды — режимы «до трёх
	# побед» ложились в сторону второго игрока (драфт 43% против 57%). Заодно это
	# работает как догоняющая механика. При ничьей порядок просто чередуется.
	if String(out["winner"]) != "":
		state["first_seat"] = String(out["winner"])
	out["match_over"] = is_match_over(state)
	state["over"] = bool(out["match_over"])
	return out

static func is_match_over(state: Dictionary) -> bool:
	var cfg: Dictionary = state["cfg"]
	var kind := String(cfg["kind"])
	if kind == "lives":
		for seat in state["order"]:
			if int(state["players"][seat]["lives"]) <= 0:
				return true
		return false
	if kind == "bo3":
		for seat in state["order"]:
			if int(state["players"][seat]["wins"]) >= 2:
				return true
		return int(state["round"]) >= 3
	if kind == "race":
		for seat in state["order"]:
			if int(state["players"][seat]["score"]) >= int(cfg["target"]):
				return true
		return false
	return false

## Итог матча: {"winner": seat|"", "detail": String}.
static func match_outcome(state: Dictionary) -> Dictionary:
	var cfg: Dictionary = state["cfg"]
	var kind := String(cfg["kind"])
	var a := String(state["order"][0])
	var b := String(state["order"][1])
	if kind == "lives":
		var la := int(state["players"][a]["lives"])
		var lb := int(state["players"][b]["lives"])
		var w := "" if la == lb else (a if la > lb else b)
		return {"winner": w, "detail": "Жизни %d : %d" % [la, lb]}
	if kind == "race":
		var sa := int(state["players"][a]["score"])
		var sb := int(state["players"][b]["score"])
		var w2 := "" if sa == sb else (a if sa > sb else b)
		return {"winner": w2, "detail": "Итог %d : %d" % [sa, sb]}
	# bo3: сперва победы в раундах, при равенстве — очки за матч
	var wa := int(state["players"][a]["wins"])
	var wb := int(state["players"][b]["wins"])
	if wa != wb:
		return {"winner": a if wa > wb else b, "detail": "Победы %d : %d" % [wa, wb]}
	var ta := int(state["players"][a]["total"])
	var tb := int(state["players"][b]["total"])
	var w3 := "" if ta == tb else (a if ta > tb else b)
	return {"winner": w3, "detail": "Победы %d : %d · очки за матч %d : %d" % [wa, wb, ta, tb]}
