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

func _on_peer_connected(_id: int) -> void:
	connected = true
	peer_connected.emit()

func _on_connected_to_server() -> void:
	connected = true
	peer_connected.emit()

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

@rpc("any_peer", "call_remote", "reliable")
func _remote_start(mode: String, seed_value: int) -> void:
	match_started.emit(mode, seed_value)

@rpc("any_peer", "call_remote", "reliable")
func _remote_move(seat: String, hand_idx: int, cell_idx: int) -> void:
	move_received.emit(seat, hand_idx, cell_idx)

@rpc("any_peer", "call_remote", "reliable")
func _remote_next_round() -> void:
	next_round_received.emit()
