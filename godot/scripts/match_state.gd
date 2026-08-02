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
const DRAFT_OFFER := 30     # сколько кубов показывают на выбор
const DRAFT_PICK := 18      # сколько из них уходит в колоду
const LIVES_MAX := Rules.LIVES_MAX

const MODES := {
	"classic": {
		"title": "КЛАССИКА", "sub": "3 жизни · поле 3×2 · 6 ходов в раунде",
		"cols": 3, "cells": 6, "moves": 6, "kind": "lives", "deck": "per_round", "deck_size": 10,
		"komi": Rules.FIRST_MOVE_KOMI, "komi3": 12, "komi4": 8,
	},
	"big": {
		"title": "БОЛЬШАЯ ДОСКА", "sub": "3 жизни · поле 3×3 · 10 ходов в раунде",
		"cols": 3, "cells": 9, "moves": 10, "kind": "lives", "deck": "per_round", "deck_size": 14,
		# 3×3 и десять ходов: сырой перекос больше, чем в классике, но шестнадцать
		# оказалось перебором — первый ходящий брал 38% раундов против 25% у
		# последнего. Замеренные значения: 10 вдвоём, 8 втроём, 9 вчетвером.
		"komi": 10, "komi3": 8, "komi4": 9,
	},
	"draft": {
		"title": "СВОЯ КОЛОДА", "sub": "18 кубов из 30 · у соперника та же колода · 3 раунда",
		"cols": 3, "cells": 6, "moves": 6, "kind": "bo3", "win_by": "score", "deck": "draft",
		"komi": 9, "komi3": 8, "komi4": 8,
	},
	"race": {
		"title": "ГОНКА ДО 500", "sub": "общая колода · счёт копится · кто первым наберёт 500",
		"cols": 3, "cells": 6, "moves": 6, "kind": "race", "target": 500, "deck": "shared",
		# Половины хватает: вторая половина шла не в справедливость, а в догонялку
		# поверх правила «первым ходит отстающий» — 47 очков из 500 за партию.
		"komi": 3, "komi3": 3, "komi4": 3,
	},
	"territory": {
		"title": "ТЕРРИТОРИЯ", "sub": "3 раунда · за каждый ход считаются удержанные клетки",
		"cols": 3, "cells": 6, "moves": 6, "kind": "bo3", "win_by": "count", "deck": "draft",
		# Здесь компенсация доходит до раунда только через ничью по клеткам (каждый
		# пятый раунд), поэтому шести очков не хватало: перекос против первого
		# держался на −4…−7 п.п.
		# 18 — середина между «не доходит до раунда» (6 давало −5 п.п. первому) и
		# «снежный ком» (24 давало +3 и тянуло весь матч через тай-брейк)
		"komi": 18, "komi3": 14, "komi4": 14,
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
## Сиденья на любое число игроков. `roster` — список описаний по порядку:
## {"kind": "human"|"bot"|"remote", "local": bool, "name": String}. Пустой список
## означает старую двойку, чтобы вызовы на двоих не переписывать.
const SEAT_IDS := ["p", "e", "c", "d"]
const SEAT_NAMES := ["Игрок 1", "Игрок 2", "Игрок 3", "Игрок 4"]
## Имена ботов: у каждого своё. Раньше первый звался безлико «Враг», а остальные
## получали прозвища — выглядело как недоделка.
const BOT_NAMES := ["Костолом", "Могильщик", "Скелетина", "Точильщик"]

## Цена первого хода для режима и числа игроков.
##
## Общего множителя нет: сырой перекос на позицию втроём вдвое больше, чем
## вчетвером, а на большой доске он вообще не такой, как в классике. Значения
## подобраны прогонами по позициям отдельно для каждого состава.
static func _komi_for(cfg: Dictionary, players: int) -> int:
	if players >= 4:
		return int(cfg.get("komi4", cfg.get("komi", Rules.FIRST_MOVE_KOMI)))
	if players == 3:
		return int(cfg.get("komi3", cfg.get("komi", Rules.FIRST_MOVE_KOMI)))
	return int(cfg.get("komi", Rules.FIRST_MOVE_KOMI))

static func seat_ids(count: int) -> Array:
	return SEAT_IDS.slice(0, clampi(count, 2, SEAT_IDS.size()))

static func make_roster_seats(roster: Array) -> Dictionary:
	var seats := {}
	var ids := seat_ids(roster.size())
	for i in ids.size():
		var d: Dictionary = roster[i]
		seats[ids[i]] = {
			"kind": String(d.get("kind", "bot")),
			"local": bool(d.get("local", false)),
			"name": String(d.get("name", SEAT_NAMES[i])),
		}
	return seats

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
		"e": {"kind": "bot", "local": false, "name": BOT_NAMES[0]},
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

## Восстановить партию по журналу: собираем от того же сида и повторяем ходы.
## Работает потому, что вся случайность идёт от сида, а ход — это три числа.
static func replay(mode_key: String, seed_value: int, opponent: String, my_seat: String,
		foe_name: String, my_name: String, picked: Array, log: Array,
		roster: Array = []) -> Dictionary:
	# состав обязателен, если игроков больше двух: иначе в партии не будет сидений
	# «c» и «d», и ходы из журнала просто некому применить
	var st := new_match(mode_key, seed_value, opponent, my_seat, foe_name, my_name, picked, roster)
	# Живая партия проходит через битву за первый ход, а она забирает броски из
	# того же генератора и заново раздаёт раунд (`apply_duel` обнуляет round,
	# историю и журнал). Без этого шага восстановленная по журналу партия — другая
	# партия: другая раздача, другой первый ходящий, другая компенсация.
	apply_duel(st, String(roll_duel(st)["winner"]))
	for entry in log:
		var seat := String(entry[0])
		# Ход мог прийти в конце раунда: доигрываем поток так же, как в живой игре.
		# Круг вчетвером — до 24 ходов, поэтому запас больше прежних шестнадцати.
		var guard := 0
		while String(st["turn"]) != seat and guard < 64:
			guard += 1
			if not _replay_step(st):
				return st
		play(st, seat, int(entry[1]), int(entry[2]))
		if not _replay_step(st):
			return st
	return st

## Один шаг потока после хода — дословно как в живой игре (`_after_move`).
##
## Ошибка была в том, что здесь делался РОВНО ОДИН `advance`, а живая игра на
## событии «пас» продолжает крутить поток дальше. Когда раунд закрывался пасами и
## пасовавший становился первым в новом раунде, догоняющий цикл сразу видел
## «очередь уже его» и не докручивал — ход нового раунда ложился на доску
## старого. Дальше расходилось всё: до 12% точек обрыва, а вчетвером журнал
## приводил к обращению за пределы руки.
##
## Возвращает false, если матч кончился и продолжать нечего.
static func _replay_step(state: Dictionary) -> bool:
	var guard := 0
	while guard < 64:
		guard += 1
		var ev := advance(state)
		match String(ev["event"]):
			"round_end":
				var out := close_round(state)
				if bool(out["match_over"]):
					return false
				new_round(state)
				return true
			"pass":
				continue      # пас — поток идёт дальше, как в живой игре
			_:
				return true
	return true

## picked — колода, набранная игроком на экране драфта. Пустая означает «набрать
## случайно»: так партию собирает клиент по сети и кнопка «Добрать случайно».
static func new_match(mode_key: String, seed_value: int, opponent: String,
		my_seat: String = "p", foe_name: String = "Соперник", my_name: String = "",
		picked: Array = [], roster: Array = []) -> Dictionary:
	var cfg: Dictionary = MODES[mode_key]
	var order: Array = seat_ids(roster.size()) if roster.size() >= 2 else ["p", "e"]
	var players := {}
	for seat in order:
		players[seat] = {
			"hand": [], "deck": [], "score": 0, "total": 0,
			"moves": 0, "lives": LIVES_MAX, "wins": 0, "held": 0, "out": false,
		}
	var state := {
		"mode": mode_key, "cfg": cfg, "seed": seed_value,
		"cols": int(cfg["cols"]), "board": [],
		"order": order, "players": players,
		"seats": make_roster_seats(roster) if roster.size() >= 2 			else make_seats(opponent, my_seat, foe_name, my_name),
		"turn": "p", "first_seat": "p",
		"round": 0, "history": [], "log": [], "shown_to": "", "veil": "",
		# Цена первого хода: сколько получает тот, кто ходит в раунде первым.
		# Размер зависит от режима — на большой доске отвечающий выигрывает втрое
		# больше, чем в классике, и общей шестёрки там не хватало. С тремя и
		# четырьмя игроками перекос тоже крупнее: раундов на каждого меньше.
		"komi": _komi_for(cfg, order.size()), "bids": {},
		"over": false, "outcome": {},
	}
	state["rng"] = make_rng(seed_value)
	# общая колода гонки: одна база, перемешанная каждому по-своему
	if String(cfg["deck"]) == "shared":
		var base := make_deck(state["rng"], 18)
		for seat in order:
			players[seat]["deck"] = shuffled(state["rng"], base)
	# драфт: 18 кубов из 30 предложенных, у соперника та же колода. Экран выбора
	# ещё не перенесён, поэтому набор случайный — как кнопка «Случайно» в вебе.
	# Предложенные 30 держим в состоянии: экран драфта потом возьмёт их отсюда.
	if String(cfg["deck"]) == "draft":
		var offer := make_deck(state["rng"], DRAFT_OFFER)
		state["draft_offer"] = offer
		# у соперника та же колода: состязание в игре, а не в раздаче
		var chosen: Array = picked if not picked.is_empty() else shuffled(state["rng"], offer).slice(0, DRAFT_PICK)
		for seat in order:
			players[seat]["deck"] = shuffled(state["rng"], chosen)
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
		# В гонке счёт между раундами не обнуляется, поэтому запоминаем, с чего
		# раунд начался: иначе «победителем раунда» объявлялся просто лидер по
		# матчу — выиграл раунд 60:20, отстаёшь 300:400, а баннер говорит, что
		# раунд взял соперник. Совпадало в 99% раундов.
		state["players"][seat]["round_from"] = int(state["players"][seat]["score"])
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
		if is_out(state, String(seat)):
			# выбывшему ни руки, ни колоды: он смотрит партию со стороны
			state["players"][seat]["hand"] = []
			continue
		var pl: Dictionary = state["players"][seat]
		while pl["hand"].size() < HAND_SIZE and not pl["deck"].is_empty():
			pl["hand"].append(pl["deck"].pop_back())
	# Первым ходит победитель прошлого раунда. Ходить первым невыгодно (правило
	# съедения «не меньше» отдаёт преимущество отвечающему), а при простом
	# чередовании в трёх раундах одно сиденье начинало дважды — и режимы «до трёх
	# побед» ложились в сторону второго игрока.
	state["turn"] = String(state["first_seat"])
	# Компенсация за невыгодный ход по порядку: чем раньше ходишь, тем больше.
	# Отвечать выгоднее, чем начинать, и с тремя игроками последний брал матчи
	# заметно чаще — компенсация распределяется по всем, а не только первому.
	# Ленту чистим ДО начисления компенсации, а не после: строчкой ниже жетон
	# «Ходишь раньше» стирался тут же, и раунд открывался со счётом 6 при пустой
	# ленте — ровно то молчаливое начисление, которое запрещено правилом карточки.
	state["shown_to"] = ""
	state["history"] = []
	# Считаем по живым, а не по стартовому составу. Иначе после выбывания за
	# столом сидят двое, а надбавка берётся по кругу из четверых: на экране одна и
	# та же картина, а «Ходишь раньше» показывает то +7, то +21 — в зависимости от
	# того, какое сиденье умерло. Игроку это ниоткуда не видно.
	var alive: Array = alive_seats(state)
	var komi_now := _komi_for(cfg, alive.size())
	if komi_now != 0 and alive.size() > 1:
		var n := alive.size()
		var start := alive.find(String(state["turn"]))
		if start < 0:
			start = 0
		for k in n:
			var seat := String(alive[(start + k) % n])
			var komi := int(round(float(komi_now) * float(n - 1 - k) / float(n - 1)))
			if komi == 0:
				continue
			state["players"][seat]["score"] = int(state["players"][seat]["score"]) + komi
			# Компенсация попадает в ленту отдельной записью. Без неё счёт молча
			# расходился с карточкой: игрок видел «ход 29», а счётчик показывал 37,
			# и первое, что он складывал, не сходилось.
			state["history"].append({
				"n": state["history"].size() + 1, "who": seat, "pts": komi,
				"parts": [{"t": "Ходишь раньше", "v": komi, "icon": "⏱"}], "mined": false,
			})
	state["first_seat"] = other_seat(state, String(state["first_seat"]))

# ------------------------------------------------------------- поток хода

static func other_seat(state: Dictionary, seat: String) -> String:
	var order: Array = state["order"]
	var i := order.find(seat)
	return String(order[(i + 1) % order.size()])

static func moves_left(state: Dictionary, seat: String) -> int:
	# выбывший не ходит вовсе: через это его пропускают и очередь, и конец раунда
	if is_out(state, seat):
		return 0
	return int(state["cfg"]["moves"]) - int(state["players"][seat]["moves"])

## Игрок вне игры: жизни кончились. Он не ходит, не берёт раунды и не мешает
## живым — раньше выбывший продолжал играть как ни в чём не бывало.
static func is_out(state: Dictionary, seat: String) -> bool:
	return bool(state["players"][seat].get("out", false))

## Кто ещё в игре.
static func alive_seats(state: Dictionary) -> Array:
	var out := []
	for seat in state["order"]:
		if not is_out(state, seat):
			out.append(String(seat))
	return out

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
	# Ход проверяется здесь, а не только в интерфейсе: сюда приходят и пакеты по
	# сети, и записи журнала при восстановлении партии. Без проверки разбор чужого
	# журнала клал кубы на собственные клетки — движок молча их «съедал».
	if String(state["turn"]) != seat or bool(state.get("over", false)):
		return {}
	var hand: Array = state["players"][seat]["hand"]
	if hand_idx < 0 or hand_idx >= hand.size():
		return {}
	if not Rules.legal_targets(state["board"], hand[hand_idx], seat).has(cell_idx):
		return {}
	var res := Rules.apply_move(state, seat, hand_idx, cell_idx)
	# Журнал ходов: сид плюс эта последовательность полностью восстанавливают
	# партию. Нужен для переподключения по Wi-Fi — иначе после обрыва связи
	# соперника пришлось бы начинать заново.
	state["log"].append([seat, hand_idx, cell_idx])
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

## Битва за первый ход: каждый бросает куб и накрывает стаканчиком, потом
## стаканчики поднимаются разом. У кого больше — тот и начинает; при ничьей
## переброс, и так пока не определится.
##
## Бросок идёт от сида матча, а не от случайности момента: по сети у всех
## устройств выпадает одно и то же, и обмениваться результатом не нужно.
static func roll_duel(state: Dictionary) -> Dictionary:
	var rng: RandomNumberGenerator = state["rng"]
	var rounds := []
	var winner := ""
	var guard := 0
	# Перебрасывают только те, у кого вышло поровну: остальные уже проиграли
	# битву, и держать их на экране незачем.
	var players: Array = state["order"].duplicate()
	while winner == "" and guard < 20:
		guard += 1
		var rolls := {}
		var best := 0
		var leaders := []
		for seat in players:
			var v := rng.randi_range(1, 6)
			rolls[seat] = v
			if v > best:
				best = v
				leaders = [seat]
			elif v == best:
				leaders.append(seat)
		rounds.append(rolls)
		if leaders.size() == 1:
			winner = String(leaders[0])
		else:
			players = leaders.duplicate()
	if winner == "":
		winner = String(state["order"][0])
	return {"rounds": rounds, "winner": winner}

## Поставить победителя битвы первым и переиграть первый раунд с новым порядком.
static func apply_duel(state: Dictionary, winner: String) -> void:
	state["first_seat"] = winner
	state["round"] = 0
	for seat in state["order"]:
		state["players"][seat]["score"] = 0
		state["players"][seat]["held"] = 0
	state["history"] = []
	state["log"] = []
	new_round(state)

## Кто взял раунд. Возвращает {"winner": seat|"", "detail": String}.
## Работает на любое число сидений: берём лучший показатель, а ничья объявляется,
## когда лучших несколько. Раньше сравнивались строго первые два сиденья, и с
## тремя игроками третий просто не учитывался.
static func round_outcome(state: Dictionary) -> Dictionary:
	var cfg: Dictionary = state["cfg"]
	var by_count: bool = String(cfg.get("win_by", "")) == "count"
	var best := -(1 << 30)
	var winners := []
	var named := []
	for seat in alive_seats(state):
		var v := round_value(state, String(seat))
		named.append({"seat": String(seat), "v": v})
		if v > best:
			best = v
			winners = [seat]
		elif v == best:
			winners.append(seat)
	# Ничья по удержанию — не редкость: клеток шесть, а игроков двое или четверо,
	# и раунд не доставался никому в 10% случаев вдвоём и в 21% вчетвером.
	#
	# Решают очки — и через них же наконец работает компенсация за первый ход:
	# раунд считает клетки, а компенсация платится очками, поэтому до раунда она
	# доходила только здесь. Отдавать ничью «тому, кто ходил раньше» пробовали —
	# перекос переворачивался в другую сторону (вдвоём 61% против 39%), потому что
	# ничья случается в каждом пятом раунде и уходила целиком одному.
	if by_count and winners.size() > 1:
		var best_score := -(1 << 30)
		var tie := []
		for seat in winners:
			var v := int(state["players"][seat]["score"])
			if v > best_score:
				best_score = v
				tie = [seat]
			elif v == best_score:
				tie.append(seat)
		winners = tie
	# С тремя игроками строка «11 : 34 : 32» ничего не говорила: непонятно, где
	# чей счёт. Пишем с именами и по убыванию — сразу видно, кто взял раунд.
	named.sort_custom(func(a, b): return int(a["v"]) > int(b["v"]))
	var label: String = "Удержано" if by_count else "Счёт"
	var chunks := []
	for e in named:
		chunks.append("%s %d" % [seat_name(state, String(e["seat"])), int(e["v"])])
	return {
		"winner": String(winners[0]) if winners.size() == 1 else "",
		"detail": "%s: %s" % [label, " · ".join(chunks)],
	}

## Показатель, по которому раунд считается выигранным: в «Территории» это
## накопленное удержание клеток, в остальных режимах — очки за раунд.
static func round_value(state: Dictionary, seat: String) -> int:
	var pl: Dictionary = state["players"][seat]
	if String(state["cfg"].get("win_by", "")) == "count":
		return int(pl.get("held", 0))
	# в гонке раунд решает набранное ЗА РАУНД, а не общий счёт матча
	if String(state["cfg"]["kind"]) == "race":
		return int(pl["score"]) - int(pl.get("round_from", 0))
	return int(pl["score"])

## Закрыть раунд: списать жизнь или засчитать победу в раунде. Возвращает
## {"winner": seat|"", "detail": String, "match_over": bool}.
static func close_round(state: Dictionary) -> Dictionary:
	var cfg: Dictionary = state["cfg"]
	var out := round_outcome(state)
	var kind := String(cfg["kind"])
	if kind == "lives":
		if state["order"].size() <= 2:
			if out["winner"] != "":
				var loser := other_seat(state, String(out["winner"]))
				state["players"][loser]["lives"] = int(state["players"][loser]["lives"]) - 1
		else:
			# Втроём и вчетвером жизнь теряют все, кроме взявшего раунд: раунд значит
			# одно и то же при любом числе игроков — выиграл или потерял сердце.
			if String(out["winner"]) != "":
				for seat in alive_seats(state):
					if String(seat) != String(out["winner"]):
						state["players"][seat]["lives"] = int(state["players"][seat]["lives"]) - 1
		# Жизни кончились — игрок выбывает и в следующих раундах не участвует.
		# Раньше матч просто заканчивался, едва у КОГО-ТО жизни дошли до нуля:
		# с двумя оставшимися сердцами можно было проиграть партию, а выбывший
		# продолжал ходить как ни в чём не бывало.
		for seat in state["order"]:
			if int(state["players"][seat]["lives"]) <= 0:
				state["players"][seat]["out"] = true
	elif kind == "bo3":
		if out["winner"] != "":
			var w: String = String(out["winner"])
			state["players"][w]["wins"] = int(state["players"][w]["wins"]) + 1
	# сумма очков за матч копится всегда: втроём и вчетвером жизни у нескольких
	# игроков часто равны, и без этого тай-брейка матч кончался ничьей
	for seat in state["order"]:
		state["players"][seat]["total"] = int(state["players"][seat]["total"]) + int(state["players"][seat]["score"])
	# первым в следующем раунде ходит победитель, но если он выбыл — следующий живой
	if is_out(state, String(state["first_seat"])) and not alive_seats(state).is_empty():
		state["first_seat"] = String(alive_seats(state)[0])
	# Следующий раунд начинает победитель этого. Ходить первым невыгодно: правило
	# съедения «не меньше» отдаёт преимущество отвечающему, и раньше при простом
	# чередовании в трёх раундах одно сиденье начинало дважды — режимы «до трёх
	# побед» ложились в сторону второго игрока (драфт 43% против 57%). Заодно это
	# работает как догоняющая механика. При ничьей порядок просто чередуется.
	if kind == "race":
		# В гонке счёт копится между раундами, поэтому «первым ходит победитель»
		# отдавало компенсацию тому, кто и так впереди, — снежный ком. Первым идёт
		# отстающий: это и догоняющая механика, и лечение перекоса.
		var worst := 1 << 30
		var behind := String(state["order"][0])
		for seat in state["order"]:
			var v := int(state["players"][seat]["score"])
			if v < worst:
				worst = v
				behind = String(seat)
		state["first_seat"] = behind
	elif String(out["winner"]) != "":
		state["first_seat"] = String(out["winner"])
	out["match_over"] = is_match_over(state)
	state["over"] = bool(out["match_over"])
	return out

static func is_match_over(state: Dictionary) -> bool:
	var cfg: Dictionary = state["cfg"]
	var kind := String(cfg["kind"])
	if kind == "lives":
		# матч идёт, пока в живых больше одного
		return alive_seats(state).size() <= 1
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
	# Итог считается по любому числу сидений: сравниваем нужный показатель у всех,
	# ничья — когда лучших несколько. С тремя игроками прежний код сравнивал только
	# первые два сиденья и объявлял победителем не того.
	if kind == "lives":
		# победил тот, кто остался в живых один. Ничья бывает, когда последние
		# сердца кончились у нескольких разом — тогда решают очки за матч
		var alive := alive_seats(state)
		if alive.size() == 1:
			return {"winner": String(alive[0]),
				"detail": "Жизней осталось: %d" % int(state["players"][alive[0]]["lives"])}
		if alive.size() > 1:
			var by_lives := _best_by(state, func(pl): return int(pl["lives"]), "Жизни ")
			if String(by_lives["winner"]) != "":
				return by_lives
		var by_total := _best_by(state, func(pl): return int(pl["total"]), "")
		return {
			"winner": String(by_total["winner"]),
			"detail": "Жизни кончились у всех · очки за матч %s"
				% String(by_total["detail"]).strip_edges(),
		}
	if kind == "race":
		return _best_by(state, func(pl): return int(pl["score"]), "Итог ")
	# bo3: сперва победы в раундах, при равенстве — очки за матч
	var by_wins := _best_by(state, func(pl): return int(pl["wins"]), "Победы ")
	if String(by_wins["winner"]) != "":
		return by_wins
	var by_total := _best_by(state, func(pl): return int(pl["total"]), "")
	return {
		"winner": String(by_total["winner"]),
		"detail": "%s · очки за матч %s" % [String(by_wins["detail"]),
			String(by_total["detail"]).strip_edges()],
	}

## Лучший по показателю. Ничья, если лучших несколько.
static func _best_by(state: Dictionary, pick: Callable, label: String) -> Dictionary:
	var best := -(1 << 30)
	var winners := []
	var parts := []
	for seat in state["order"]:
		var v := int(pick.call(state["players"][seat]))
		parts.append(str(v))
		if v > best:
			best = v
			winners = [seat]
		elif v == best:
			winners.append(seat)
	return {
		"winner": String(winners[0]) if winners.size() == 1 else "",
		"detail": label + " : ".join(parts),
	}
