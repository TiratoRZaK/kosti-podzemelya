class_name Lan
extends Node

## Игра с другом рядом по локальной сети.
##
## Модель: **хост-авторитет по раздаче, ходы транслируются**. Хост создаёт матч,
## сообщает клиенту сид и режим — и оба собирают одинаковое состояние, потому что
## вся случайность идёт от сида. Дальше по сети ходят только сами ходы
## (`{seat, hand, cell}`), а применяет их каждый у себя той же `apply_move`.
## Так пакеты крошечные и рассинхрон невозможен, пока логика детерминирована.
##
## Скрытые кубы при этом лежат на обоих устройствах: у соперника технически есть
## возможность подсмотреть мины через память. Для игры с другом это принято
## сознательно — сервер, который прятал бы карты, отложен до публичной игры.
##
## Обнаружение: хост слушает UDP-порт и отвечает на широковещательный запрос
## клиента. Так второй телефон находит первый сам, без ввода адреса.

signal peer_connected                     ## соединение установилось
signal peer_lost                          ## соединение оборвалось
signal hosts_found(list: Array)           ## найденные хосты: [{name, address}]
signal match_started(mode: String, seed_value: int)   ## хост задал партию
signal move_received(seat: String, hand_idx: int, cell_idx: int)
signal next_round_received
## Соперник вышел из партии в меню: ждать его хода или «Ещё раз» больше нечего.
signal match_left
## Хост присылает партию заново после переподключения: режим, сид, журнал ходов.
signal resync_received(mode: String, seed_value: int, log: Array)
## Действие Дуракуба: attack/defend по индексу куба в руке, bito/take без индекса.
signal durak_action_received(seat: String, act: String, hand_idx: int)
## Соперник представился: имя его устройства. Нужно, чтобы вместо IP-адреса и
## безликого «Соперника» в игре стояло понятное имя.
signal peer_named(name_of_peer: String)

const GAME_PORT := 8177
const DISCOVERY_PORT := 8178
const DISCOVERY_MAGIC := "kosti-podzemelya-v1"

const ANNOUNCE_EVERY := 0.8        # как часто хост объявляет о себе

var is_host := false
var connected := false
var player_name := "Игрок"
var discovery_ok := true           # удалось ли занять порт обнаружения
var _announce_wait := 0.0

var _peer: ENetMultiplayerPeer
var _udp: PacketPeerUDP
var _discovering := false
var _found: Array = []

## Имя узла задаётся жёстко, и это обязательно: сетевой вызов адресуется по пути
## узла в дереве, а безымянному узлу Godot присваивает имя со счётчиком, которое
## на двух устройствах может не совпасть. Тогда соединение есть, но пакеты
## отбрасываются с «Requested node was not found», и партия не начинается.
const NODE_NAME := "Lan"

func _init() -> void:
	name = NODE_NAME

func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)

# ------------------------------------------------------------------- хост

func start_host(name_of_player: String) -> bool:
	stop()
	player_name = name_of_player
	_peer = ENetMultiplayerPeer.new()
	var err := _peer.create_server(GAME_PORT, 1)   # соперник ровно один
	if err != OK:
		push_warning("Не удалось поднять хост: %s" % err)
		return false
	multiplayer.multiplayer_peer = _peer
	is_host = true
	# Слушаем запросы «кто здесь хост». Ошибку bind раньше не проверяли: порт мог
	# быть занят, хост поднимался, а найти его было нельзя — и понять, почему,
	# тоже нельзя.
	_udp = PacketPeerUDP.new()
	_udp.set_broadcast_enabled(true)
	discovery_ok = _udp.bind(DISCOVERY_PORT) == OK
	if not discovery_ok:
		push_warning("Порт обнаружения занят: %d" % DISCOVERY_PORT)
	set_process(true)
	return true

# ------------------------------------------------------------------ клиент

## Разослать запрос «кто здесь хост». Ответы придут в hosts_found.
##
## Широковещательному запросу доверять нельзя: Android в целях экономии батареи
## отбрасывает входящие broadcast-пакеты на Wi-Fi, да и роутеры их иногда не
## пересылают. Из-за этого выходило несимметрично — тот, кто *создавал* игру, не
## находился, а сам находил других: клиент рассылает broadcast и получает
## обычный ответ, а обычные пакеты не фильтруются никогда.
##
## Поэтому кроме broadcast мы обходим подсеть **поимённо**: посылаем запрос на
## каждый адрес /24. Это 254 крошечных пакета, уходят за один кадр, и до хоста
## доходят гарантированно.
func discover() -> void:
	_found.clear()
	_discovering = true
	var udp := PacketPeerUDP.new()
	udp.set_broadcast_enabled(true)
	# слушаем и порт обнаружения — на случай, если хост объявит себя сам
	if udp.bind(DISCOVERY_PORT) != OK:
		udp.bind(0)
	_udp = udp
	set_process(true)
	var ask := ("%s?" % DISCOVERY_MAGIC).to_utf8_buffer()
	for addr in _broadcast_targets():
		udp.set_dest_address(addr, DISCOVERY_PORT)
		udp.put_packet(ask)
	for addr in _subnet_targets():
		udp.set_dest_address(addr, DISCOVERY_PORT)
		udp.put_packet(ask)
	# ждём ответы недолго: игра идёт в одной комнате, задержки мизерные
	await get_tree().create_timer(1.5).timeout
	_discovering = false
	hosts_found.emit(_found.duplicate())

## Свои адреса в локальной сети: IPv4, без петли и самоназначенных.
static func local_ipv4() -> Array:
	var out := []
	for a in IP.get_local_addresses():
		var s := String(a)
		if s.contains(":") or s.begins_with("127.") or s.begins_with("169.254."):
			continue
		out.append(s)
	return out

## Куда шлём широковещательный запрос: общий адрес и адрес своей подсети.
## Второй иногда доходит там, где первый режется.
func _broadcast_targets() -> Array:
	var out := ["255.255.255.255"]
	for ip in local_ipv4():
		var parts: PackedStringArray = ip.split(".")
		if parts.size() == 4:
			out.append("%s.%s.%s.255" % [parts[0], parts[1], parts[2]])
	return out

## Все адреса своей подсети, кроме собственного: обычные пакеты Android не
## фильтрует, поэтому такой обход находит хост даже когда broadcast не работает.
func _subnet_targets() -> Array:
	var out := []
	for ip in local_ipv4():
		var parts: PackedStringArray = ip.split(".")
		if parts.size() != 4:
			continue
		var prefix := "%s.%s.%s." % [parts[0], parts[1], parts[2]]
		var mine := int(parts[3])
		for i in range(1, 255):
			if i != mine:
				out.append(prefix + str(i))
	return out

## Адрес хоста запоминаем: после обрыва к нему можно вернуться, не заходя в лобби.
var last_address := ""

func join(address: String) -> bool:
	last_address = address
	stop()
	_peer = ENetMultiplayerPeer.new()
	var err := _peer.create_client(address, GAME_PORT)
	if err != OK:
		push_warning("Не удалось подключиться: %s" % err)
		return false
	multiplayer.multiplayer_peer = _peer
	is_host = false
	return true

func stop() -> void:
	if _udp != null:
		_udp.close()
		_udp = null
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null
	_peer = null
	is_host = false
	connected = false
	set_process(false)

# --------------------------------------------------------------- обнаружение

func _process(dt: float) -> void:
	if _udp == null:
		return
	# Хост объявляет себя сам, не дожидаясь запроса: если broadcast до него не
	# доходит, зато уходит от него — второй телефон всё равно узнает об игре.
	if is_host and not connected:
		_announce_wait -= dt
		if _announce_wait <= 0.0:
			_announce_wait = ANNOUNCE_EVERY
			var hi := ("%s!%s" % [DISCOVERY_MAGIC, player_name]).to_utf8_buffer()
			for addr in _broadcast_targets():
				_udp.set_dest_address(addr, DISCOVERY_PORT)
				_udp.put_packet(hi)
	while _udp.get_available_packet_count() > 0:
		var data := _udp.get_packet().get_string_from_utf8()
		var from_ip := _udp.get_packet_ip()
		if is_host and data == "%s?" % DISCOVERY_MAGIC:
			# отвечаем спросившему: имя хоста, чтобы игрок узнал устройство
			var reply := PacketPeerUDP.new()
			reply.set_dest_address(from_ip, _udp.get_packet_port())
			reply.put_packet(("%s!%s" % [DISCOVERY_MAGIC, player_name]).to_utf8_buffer())
			reply.close()
		elif _discovering and data.begins_with("%s!" % DISCOVERY_MAGIC):
			var host_name := data.substr(DISCOVERY_MAGIC.length() + 1)
			var known := false
			for h in _found:
				if String(h["address"]) == from_ip:
					known = true
			if not known:
				_found.append({"name": host_name, "address": from_ip})

# -------------------------------------------------------------- соединение

## ENet считает соединение мёртвым слишком быстро: на телефоне достаточно, чтобы
## Android на секунду придержал Wi-Fi (экран притух, пришло уведомление) — и
## партия обрывалась на «стабильной» сети. Поднимаем терпение до 30 секунд.
const TIMEOUT_LIMIT := 32          # во сколько раз ping может превысить средний
const TIMEOUT_MIN_MS := 8000       # минимум ожидания перед разрывом
const TIMEOUT_MAX_MS := 30000      # максимум — после него соединение точно мёртвое

func _patient_timeout(id: int) -> void:
	if _peer == null:
		return
	var p := _peer.get_peer(id)
	if p != null:
		p.set_timeout(TIMEOUT_LIMIT, TIMEOUT_MIN_MS, TIMEOUT_MAX_MS)

func _on_peer_connected(id: int) -> void:
	connected = true
	_patient_timeout(id)
	_stop_discovery()          # хост нашли, слушать широковещалку больше незачем
	peer_connected.emit()

func _on_connected_to_server() -> void:
	connected = true
	_patient_timeout(1)        # у клиента сервер всегда под номером 1
	_stop_discovery()
	peer_connected.emit()

## Discovery-сокет живёт только до соединения: держать его открытым всю партию
## незачем, а на Android лишний UDP-сокет — лишний повод для системы вмешаться.
func _stop_discovery() -> void:
	if _udp != null:
		_udp.close()
		_udp = null
	_discovering = false
	set_process(false)

func _on_peer_disconnected(_id: int) -> void:
	# после send_leave разрыв — запланированное завершение, а не потеря соперника:
	# о нём не сигналим, иначе ушедший сам увидел бы «СВЯЗЬ ПОТЕРЯНА» поверх меню
	var was := connected
	connected = false
	if was:
		peer_lost.emit()

func _on_connection_failed() -> void:
	connected = false
	peer_lost.emit()

# ------------------------------------------------------------------ обмен

## Хост объявляет партию: режим и сид. Раздача у обоих совпадёт.
func send_start(mode: String, seed_value: int) -> void:
	if not connected:
		return
	_remote_start.rpc(mode, seed_value)

## Ход отправляется как данные, а не как состояние: три числа вместо всей доски.
func send_move(seat: String, hand_idx: int, cell_idx: int) -> void:
	if not connected:
		return
	_remote_move.rpc(seat, hand_idx, cell_idx)

func send_next_round() -> void:
	if not connected:
		return
	_remote_next_round.rpc()

## Выходим из партии в меню: сопернику уходит «вышел», а соединение закрывается
## вежливо — peer_disconnect_later сперва довозит очередь пакетов (само
## сообщение) и только потом рвёт связь. Жёсткий stop() сразу после отправки
## терял пакет прямо в очереди — сообщение не доходило, это проверено тестом.
## Хост отдаёт партию целиком: режим, сид и все сделанные ходы. Клиент собирает
## её с нуля и повторяет ходы — так связь можно поднять посреди партии, а не
## начинать заново.
func send_resync(mode: String, seed_value: int, log: Array) -> void:
	if not connected:
		return
	_remote_resync.rpc(mode, seed_value, log)

func send_leave() -> void:
	if not connected:
		return
	_remote_leave.rpc()
	if _peer != null and _peer.host != null:
		for p in _peer.host.get_peers():
			p.peer_disconnect_later(0)
	connected = false

## Дуракуб ходит теми же данными: что сделали и каким кубом руки. Раздача у обоих
## одна (сид), поэтому индекса достаточно — состояние сходится само.
func send_durak_action(seat: String, act: String, hand_idx: int = -1) -> void:
	if not connected:
		return
	_remote_durak.rpc(seat, act, hand_idx)

## Представиться сопернику именем устройства.
func send_hello() -> void:
	if not connected:
		return
	_remote_hello.rpc(player_name)

## Имя этого устройства: на телефоне — модель («Redmi Note 12»), на компьютере —
## имя системы. Показывать сопернику IP-адрес незачем, он ни о чём не говорит.
static func device_name() -> String:
	var model := OS.get_model_name()
	if model != "" and model != "GenericDevice":
		return model
	var host := OS.get_environment("COMPUTERNAME")
	if host == "":
		host = OS.get_environment("HOSTNAME")
	return host if host != "" else OS.get_name()

@rpc("any_peer", "call_remote", "reliable")
func _remote_start(mode: String, seed_value: int) -> void:
	match_started.emit(mode, seed_value)

@rpc("any_peer", "call_remote", "reliable")
func _remote_move(seat: String, hand_idx: int, cell_idx: int) -> void:
	move_received.emit(seat, hand_idx, cell_idx)

@rpc("any_peer", "call_remote", "reliable")
func _remote_next_round() -> void:
	next_round_received.emit()

@rpc("any_peer", "call_remote", "reliable")
func _remote_leave() -> void:
	match_left.emit()

@rpc("any_peer", "call_remote", "reliable")
func _remote_durak(seat: String, act: String, hand_idx: int) -> void:
	durak_action_received.emit(seat, act, hand_idx)

@rpc("any_peer", "call_remote", "reliable")
func _remote_resync(mode: String, seed_value: int, log: Array) -> void:
	resync_received.emit(mode, seed_value, log)

@rpc("any_peer", "call_remote", "reliable")
func _remote_hello(name_of_peer: String) -> void:
	peer_named.emit(name_of_peer)
