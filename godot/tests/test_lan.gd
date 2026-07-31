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

	client.close()
	server.close()

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
