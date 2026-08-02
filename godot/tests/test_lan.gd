extends SceneTree

## Проверка локальной сети: хост и клиент в одном процессе — два SceneTree в
## Godot не поднять, поэтому берём два ENet-пира напрямую и гоняем через них тот
## же обмен, что делает Lan: сид партии и ходы.
##
## Ключевое, что проверяем: после обмена ходами состояния у обоих совпадают. Если
## разъедутся — сеть бессмысленна, игроки увидят разные доски.

const PORT := 8179

var fails := 0

func _init() -> void:
	print("")
	print("--- локальная сеть: соединение и синхронность ---")
	print("")
	await run()
	print("")
	if fails > 0:
		print("ПРОВАЛОВ: %d" % fails)
	else:
		print("ВСЕ ПРОВЕРКИ ПРОЙДЕНЫ")
	print("")
	quit(1 if fails > 0 else 0)

func check(ok: bool, title: String, detail: String = "") -> void:
	if not ok:
		fails += 1
	print("%s%s" % ["  OK  " if ok else " FAIL ", title])
	if detail != "":
		print("        %s" % detail)

func run() -> void:
	var server := ENetMultiplayerPeer.new()
	var err_s := server.create_server(PORT, 1)
	var client := ENetMultiplayerPeer.new()
	var err_c := client.create_client("127.0.0.1", PORT)
	check(err_s == OK and err_c == OK, "хост поднялся и клиент начал подключение",
		"server=%d client=%d" % [err_s, err_c])

	# крутим оба пира, пока не установится связь
	var connected := false
	for i in 200:
		server.poll()
		client.poll()
		if client.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
			connected = true
			break
		await create_timer(0.02)
	check(connected, "соединение установилось",
		"статус клиента=%d" % client.get_connection_status())

	# сид передаётся один раз, дальше раздача совпадает без пересылки состояния
	var seed_value := 4242
	var host_state := MatchState.new_match("classic", seed_value, "remote", "p")
	var client_state := MatchState.new_match("classic", seed_value, "remote", "e")
	var same_deal := _hand(host_state, "p") == _hand(client_state, "p") \
		and _hand(host_state, "e") == _hand(client_state, "e")
	check(same_deal, "из одного сида собралась одна и та же раздача",
		"хост p=[%s] клиент p=[%s]" % [_hand(host_state, "p"), _hand(client_state, "p")])

	# сиденья зеркальны: у каждого своё — local, чужое — remote
	var seats_ok := MatchState.seat_local(host_state, "p") and not MatchState.seat_local(host_state, "e") \
		and MatchState.seat_local(client_state, "e") and not MatchState.seat_local(client_state, "p") \
		and MatchState.seat_kind(host_state, "e") == "remote"
	check(seats_ok, "сиденья зеркальны: своё локальное, чужое удалённое",
		"хост: p=%s/%s e=%s/%s | клиент: p=%s/%s e=%s/%s" % [
			MatchState.seat_kind(host_state, "p"), str(MatchState.seat_local(host_state, "p")),
			MatchState.seat_kind(host_state, "e"), str(MatchState.seat_local(host_state, "e")),
			MatchState.seat_kind(client_state, "p"), str(MatchState.seat_local(client_state, "p")),
			MatchState.seat_kind(client_state, "e"), str(MatchState.seat_local(client_state, "e"))])

	# ширмы в сетевой игре быть не должно: чужое сиденье не локальное
	var no_veil := not MatchState.shared_device(host_state) and not MatchState.needs_veil(host_state, "p")
	check(no_veil, "по сети ширма не нужна и не просится")

	# играем несколько ходов «через сеть»: ход выбирает владелец, применяют оба
	var rng := MatchState.make_rng(7)
	var moves_done := 0
	for step in 6:
		var seat := String(host_state["turn"])
		if not MatchState.has_legal(host_state, seat):
			MatchState.advance(host_state)
			MatchState.advance(client_state)
			continue
		var mv := Bot.choose_move(host_state, seat, rng)
		if mv.is_empty():
			break
		# так же, как в игре: ход уходит данными, каждый применяет у себя
		MatchState.play(host_state, seat, int(mv["hand"]), int(mv["cell"]))
		MatchState.play(client_state, seat, int(mv["hand"]), int(mv["cell"]))
		MatchState.advance(host_state)
		MatchState.advance(client_state)
		moves_done += 1

	var synced := _board(host_state) == _board(client_state) \
		and int(host_state["players"]["p"]["score"]) == int(client_state["players"]["p"]["score"]) \
		and int(host_state["players"]["e"]["score"]) == int(client_state["players"]["e"]["score"])
	check(synced, "после %d ходов состояния совпадают" % moves_done,
		"хост: %s | клиент: %s" % [_board(host_state), _board(client_state)])

	# путь узла — часть сетевого протокола: разойдётся, и пакеты будут отброшены
	var probe := Lan.new()
	check(probe.name == Lan.NODE_NAME, "у узла сети постоянное имя, а не автоматическое",
		"имя=%s" % probe.name)
	probe.free()

	resync_case()
	party_case()
	party_resync_case()

	durak_case()
	durak_party_case()

	client.close()
	server.close()

	await leave_case()

## Выход из партии: сообщение обязано дойти до соперника раньше, чем закроется
## соединение, — иначе тот вечно ждёт хода или «Ещё раз» на экране исхода.
## Тут два настоящих Lan-узла: у каждого свой MultiplayerAPI со своим корнем,
## пути узлов «Lan» совпадают относительно корней — как на двух устройствах.
## В script-режиме SceneTree кастомные API сам не опрашивает — опрашиваем руками.
func leave_case() -> void:
	# дерево оживает только после первого кадра: до него root ещё не в дереве,
	# add_child не даёт узлам ни пути, ни multiplayer — а весь тест до этого
	# места может пройти синхронно, не уступив движку ни разу
	await process_frame
	var root_a := Node.new()
	root_a.name = "A"
	root.add_child(root_a)
	var root_b := Node.new()
	root_b.name = "B"
	root.add_child(root_b)
	set_multiplayer(MultiplayerAPI.create_default_interface(), root_a.get_path())
	set_multiplayer(MultiplayerAPI.create_default_interface(), root_b.get_path())
	var api_a := get_multiplayer(root_a.get_path())
	var api_b := get_multiplayer(root_b.get_path())
	var lan_a := Lan.new()
	root_a.add_child(lan_a)
	var lan_b := Lan.new()
	root_b.add_child(lan_b)

	var hosted := lan_a.start_host("Хост")
	var joined := lan_b.join("127.0.0.1")
	var linked := false
	for i in 200:
		api_a.poll()
		api_b.poll()
		if lan_a.connected and lan_b.connected:
			linked = true
			break
		await create_timer(0.02)
	check(hosted and joined and linked, "Lan-узлы соединились в одном процессе",
		"хост=%s клиент=%s связь=%s" % [str(hosted), str(joined), str(linked)])

	var got := {"left": false}
	lan_b.match_left.connect(func(): got["left"] = true)
	lan_a.send_leave()
	for i in 200:
		api_a.poll()
		api_b.poll()
		if got["left"]:
			break
		await create_timer(0.02)
	check(got["left"] and not lan_a.connected,
		"«вышел из партии» дошло, а связь у ушедшего закрылась",
		"дошло=%s связь ушедшего=%s" % [str(got["left"]), str(lan_a.connected)])

	lan_b.stop()
	root_a.queue_free()
	root_b.queue_free()

## Дуракуб по сети. Действий четыре, и каждое сериализуется тремя значениями:
## сиденье, что сделал, индекс куба в руке. Гоняем целый кон крест-накрест и
## сверяем руки, стол, колоду и отбой: разъедутся — игроки увидят разные столы.
func durak_case() -> void:
	var host := Durak.new_game(31337, "remote", "p")
	var client := Durak.new_game(31337, "remote", "e")
	var deal_ok := _dhand(host, "p") == _dhand(client, "p") \
		and _dhand(host, "e") == _dhand(client, "e") and int(host["trump"]) == int(client["trump"])
	check(deal_ok, "дуракуб: из одного сида одна раздача и один козырь",
		"хост p=[%s] клиент p=[%s] козырь=%s" % [_dhand(host, "p"), _dhand(client, "p"),
			Durak.SUITS[int(host["trump"])]])

	var acts := 0
	var guard := 0
	while not bool(host["over"]) and guard < 400:
		guard += 1
		var seat := Durak.actor(host)
		if seat == "":
			break
		# действие выбирает тот, за чьим сиденьем сидят, применяют оба
		var forced := Durak.forced_action(host, seat)
		var act := {"act": forced} if forced != "" else Durak.bot_action(host)
		if act.is_empty():
			break
		var idx: int = int(act.get("hand", -1))
		_dapply(host, seat, String(act["act"]), idx)
		_dapply(client, seat, String(act["act"]), idx)
		acts += 1

	var same: bool = _dhand(host, "p") == _dhand(client, "p") \
		and _dhand(host, "e") == _dhand(client, "e") \
		and _dtable(host) == _dtable(client) \
		and host["talon"].size() == client["talon"].size() \
		and int(host["discard"]) == int(client["discard"]) \
		and String(host["phase"]) == String(client["phase"]) \
		and String(host["attacker"]) == String(client["attacker"])
	check(same and acts > 5, "дуракуб: после %d действий состояния совпадают" % acts,
		"хост: руки %d:%d колода=%d отбой=%d | клиент: руки %d:%d колода=%d отбой=%d" % [
			Durak.hand_of(host, "p").size(), Durak.hand_of(host, "e").size(),
			host["talon"].size(), int(host["discard"]),
			Durak.hand_of(client, "p").size(), Durak.hand_of(client, "e").size(),
			client["talon"].size(), int(client["discard"])])

	# чужим сиденьем по сети не походишь: то же правило, что и вживую
	var h2 := Durak.new_game(555, "remote", "p")
	var att := String(h2["attacker"])
	var thief := Durak.attack(h2, Durak.other_seat(h2, att), 0)
	check(thief.is_empty(), "дуракуб: чужое действие по сети отбрасывается")

func _dapply(st: Dictionary, seat: String, act: String, idx: int) -> void:
	match act:
		"attack": Durak.attack(st, seat, idx)
		"defend": Durak.defend(st, seat, idx)
		"bito": Durak.bito(st, seat)
		"take": Durak.take(st, seat)

func _dhand(st: Dictionary, seat: String) -> String:
	var out := []
	for d in Durak.hand_of(st, seat):
		out.append(Durak.die_label(d))
	return ",".join(out)

func _dtable(st: Dictionary) -> String:
	var out := []
	for pair in st["table"]:
		out.append("%s/%s" % [Durak.die_label(pair["a"]),
			"—" if pair["d"] == null else Durak.die_label(pair["d"])])
	return " ".join(out)

func _hand(st: Dictionary, seat: String) -> String:
	var out := []
	for d in st["players"][seat]["hand"]:
		out.append("%d%s" % [int(d["value"]), String(d["type"]).substr(0, 2)])
	return ",".join(out)

func _board(st: Dictionary) -> String:
	var out := []
	for cell in st["board"]:
		out.append("-" if cell == null else "%s%d" % [String(cell["owner"]), int(cell["v"])])
	return ",".join(out)

## Восстановление партии после обрыва: собираем от того же сида и повторяем
## журнал ходов. Если состояния разойдутся, вернувшийся игрок увидит другую доску.
func resync_case() -> void:
	var seed_value := 24680
	var host := MatchState.new_match("classic", seed_value, "remote", "p")
	# живая партия всегда проходит битву за первый ход — она забирает броски из
	# того же генератора и заново раздаёт раунд. `replay` делает то же самое,
	# поэтому и оригинал в тесте обязан начинаться с неё
	MatchState.apply_duel(host, String(MatchState.roll_duel(host)["winner"]))
	var rng := MatchState.make_rng(99)
	var played := 0
	for step in 9:
		var seat := String(host["turn"])
		if MatchState.moves_left(host, seat) <= 0 or not MatchState.has_legal(host, seat):
			var ev := MatchState.advance(host)
			if String(ev["event"]) == "round_end":
				var out := MatchState.close_round(host)
				if bool(out["match_over"]):
					break
				MatchState.new_round(host)
			continue
		var mv := Bot.choose_move(host, seat, rng)
		if mv.is_empty():
			break
		MatchState.play(host, seat, int(mv["hand"]), int(mv["cell"]))
		played += 1
		var ev2 := MatchState.advance(host)
		if String(ev2["event"]) == "round_end":
			var out2 := MatchState.close_round(host)
			if bool(out2["match_over"]):
				break
			MatchState.new_round(host)

	# клиент вернулся: у него только сид, режим и журнал
	var back := MatchState.replay("classic", seed_value, "remote", "e", "Хост", "Ты", [], host["log"])
	var same: bool = _board(back) == _board(host) 		and int(back["players"]["p"]["score"]) == int(host["players"]["p"]["score"]) 		and int(back["players"]["e"]["score"]) == int(host["players"]["e"]["score"]) 		and int(back["round"]) == int(host["round"]) 		and String(back["turn"]) == String(host["turn"]) 		and _hand(back, "p") == _hand(host, "p") and _hand(back, "e") == _hand(host, "e")
	check(same and played >= 6, "партия восстанавливается из сида и журнала ходов",
		"ходов в журнале=%d | доска %s против %s | ход у %s против %s" % [host["log"].size(),
			_board(host), _board(back), String(host["turn"]), String(back["turn"])])

## Партия на троих по сети: у каждого свой взгляд на один и тот же стол. Ход
## делает владелец сиденья, применяют все трое — состояния обязаны совпасть.
func party_case() -> void:
	var seed_value := 13579
	var roster := [
		{"kind": "human", "name": "Хозяин"},
		{"kind": "human", "name": "Гость"},
		{"kind": "bot", "name": "Костолом"},
	]
	var ids := MatchState.seat_ids(roster.size())
	var views := {}
	for i in ids.size():
		var mine := []
		for k in roster.size():
			var d: Dictionary = roster[k]
			var kind := String(d["kind"])
			var is_me: bool = k == i
			if kind == "human" and not is_me:
				kind = "remote"
			mine.append({"kind": kind, "local": is_me, "name": String(d["name"])})
		views[String(ids[i])] = MatchState.new_match("classic", seed_value, "remote",
			String(ids[i]), "Соперник", String(roster[i]["name"]), [], mine)

	var lead: Dictionary = views[String(ids[0])]
	var rng := MatchState.make_rng(4242)
	var moves := 0
	for step in 12:
		var seat := String(lead["turn"])
		if MatchState.moves_left(lead, seat) <= 0 or not MatchState.has_legal(lead, seat):
			for v in views.values():
				MatchState.advance(v)
			continue
		var mv := Bot.choose_move(lead, seat, rng)
		if mv.is_empty():
			break
		# ход уходит всем и применяется каждым у себя
		for v in views.values():
			MatchState.play(v, seat, int(mv["hand"]), int(mv["cell"]))
			MatchState.advance(v)
		moves += 1

	var same := true
	var detail := ""
	for id in ids:
		var v: Dictionary = views[String(id)]
		if _board(v) != _board(lead) or String(v["turn"]) != String(lead["turn"]):
			same = false
		detail += "%s:%s " % [String(id), _board(v)]
	# сиденья зеркальны: у каждого местное только своё
	var seats_ok := true
	for i in ids.size():
		var v: Dictionary = views[String(ids[i])]
		for k in ids.size():
			var should_be_local: bool = k == i
			if MatchState.seat_local(v, String(ids[k])) != should_be_local and String(roster[k]["kind"]) == "human":
				seats_ok = false
	check(same and seats_ok and moves >= 8,
		"партия на троих: три взгляда на один стол совпадают после %d ходов" % moves, detail)

## Возврат в партию на троих: вернувшемуся приходят состав, его место и журнал.
## Если состав потерять, сидений «c» и «d» не будет и ходы применить некому.
func party_resync_case() -> void:
	var seed_value := 4711
	var roster := [
		{"kind": "human", "name": "Хозяин"},
		{"kind": "human", "name": "Гость"},
		{"kind": "bot", "name": "Костолом"},
	]
	var host_roster := []
	for i in roster.size():
		host_roster.append({"kind": String(roster[i]["kind"]), "local": i == 0,
			"name": String(roster[i]["name"])})
	var host := MatchState.new_match("classic", seed_value, "remote", "p", "Соперник",
		"Хозяин", [], host_roster)
	# как и в живой партии, начинаем с битвы за первый ход
	MatchState.apply_duel(host, String(MatchState.roll_duel(host)["winner"]))
	var rng := MatchState.make_rng(555)
	for step in 10:
		var seat := String(host["turn"])
		if MatchState.moves_left(host, seat) <= 0 or not MatchState.has_legal(host, seat):
			MatchState.advance(host)
			continue
		var mv := Bot.choose_move(host, seat, rng)
		if mv.is_empty():
			break
		MatchState.play(host, seat, int(mv["hand"]), int(mv["cell"]))
		MatchState.advance(host)

	# гость возвращается: у него сиденье «e», состав и журнал
	var guest_roster := []
	for i in roster.size():
		var kind := String(roster[i]["kind"])
		if kind == "human" and i != 1:
			kind = "remote"
		guest_roster.append({"kind": kind, "local": i == 1, "name": String(roster[i]["name"])})
	var back := MatchState.replay("classic", seed_value, "remote", "e", "Хозяин", "Гость",
		[], host["log"], guest_roster)
	var same: bool = _board(back) == _board(host) and String(back["turn"]) == String(host["turn"]) 		and back["order"].size() == 3 and _hand(back, "c") == _hand(host, "c")
	check(same, "возврат в партию на троих: доска, очередь и рука третьего совпали",
		"ходов=%d | хост %s | вернувшийся %s" % [host["log"].size(), _board(host), _board(back)])

## Дуракуб втроём по сети: у каждого свой взгляд, действия применяются всеми.
func durak_party_case() -> void:
	var roster := [
		{"kind": "human", "local": false, "name": "Хозяин"},
		{"kind": "human", "local": false, "name": "Гость"},
		{"kind": "bot", "local": false, "name": "Костолом"},
	]
	var ids := MatchState.seat_ids(roster.size())
	var views := {}
	for i in ids.size():
		var mine := []
		for k in roster.size():
			var d: Dictionary = roster[k]
			var kind := String(d["kind"])
			if kind == "human" and k != i:
				kind = "remote"
			mine.append({"kind": kind, "local": k == i, "name": String(d["name"])})
		views[String(ids[i])] = Durak.new_game(777001, "remote", String(ids[i]), "Соперник",
			String(roster[i]["name"]), mine)

	var lead: Dictionary = views[String(ids[0])]
	var acts := 0
	var guard := 0
	while not bool(lead["over"]) and guard < 400:
		guard += 1
		var seat := Durak.actor(lead)
		if seat == "":
			break
		var forced := Durak.forced_action(lead, seat)
		var act := {"act": forced} if forced != "" else Durak.bot_action(lead)
		if act.is_empty():
			break
		var idx: int = int(act.get("hand", -1))
		for v in views.values():
			_dapply(v, seat, String(act["act"]), idx)
		acts += 1

	var same := true
	for id in ids:
		var v: Dictionary = views[String(id)]
		if _dtable(v) != _dtable(lead) or String(v["attacker"]) != String(lead["attacker"]):
			same = false
		for sid in ids:
			if _dhand(v, String(sid)) != _dhand(lead, String(sid)):
				same = false
	check(same and acts > 10, "дуракуб втроём: три взгляда совпали после %d действий" % acts,
		"руки %d/%d/%d | колода=%d" % [Durak.hand_of(lead, "p").size(),
			Durak.hand_of(lead, "e").size(), Durak.hand_of(lead, "c").size(), lead["talon"].size()])
