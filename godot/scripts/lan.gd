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
## Действие Дуракуба: attack/defend по индексу куба в руке, bito/take без индекса.
signal durak_action_received(seat: String, act: String, hand_idx: int)
## Соперник представился: имя его устройства. Нужно, чтобы вместо IP-адреса и
## безликого «Соперника» в игре стояло понятное имя.
signal peer_named(name_of_peer: String)

const GAME_PORT := 8177
const DISCOVERY_PORT := 8178
const DISCOVERY_MAGIC := "kosti-podzemelya-v1"

var is_host := false
var connected := false
var player_name := "Игрок"

var _peer: ENetMultiplayerPeer
var _udp: PacketPeerUDP
var _discovering := false
var _found: Array = []

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
	# слушаем широковещательные запросы, чтобы второй телефон нас нашёл
	_udp = PacketPeerUDP.new()
	_udp.bind(DISCOVERY_PORT)
	set_process(true)
	return true

# ------------------------------------------------------------------ клиент

## Разослать запрос «кто здесь хост». Ответы придут в hosts_found.
func discover() -> void:
	_found.clear()
	_discovering = true
	var udp := PacketPeerUDP.new()
	udp.set_broadcast_enabled(true)
	udp.bind(0)
	udp.set_dest_address("255.255.255.255", DISCOVERY_PORT)
	udp.put_packet(("%s?" % DISCOVERY_MAGIC).to_utf8_buffer())
	_udp = udp
	set_process(true)
	# ждём ответы недолго: игра идёт в одной комнате, задержки мизерные
	await get_tree().create_timer(1.2).timeout
	_discovering = false
	hosts_found.emit(_found.duplicate())

func join(address: String) -> bool:
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

func _process(_dt: float) -> void:
	if _udp == null:
		return
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
	connected = false
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
func _remote_durak(seat: String, act: String, hand_idx: int) -> void:
	durak_action_received.emit(seat, act, hand_idx)

@rpc("any_peer", "call_remote", "reliable")
func _remote_hello(name_of_peer: String) -> void:
	peer_named.emit(name_of_peer)
