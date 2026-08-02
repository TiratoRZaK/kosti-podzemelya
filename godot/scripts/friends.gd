class_name Friends
extends RefCounted

## С кем уже играли по Wi-Fi.
##
## Список лежит в `user://friends.cfg` рядом с именем игрока. Хранится немного:
## имя, последний адрес, когда играли в последний раз и сколько партий вместе.
## Адрес нужен, чтобы позвать знакомого напрямую — в домашней сети он обычно
## тот же самый, а если сменился, знакомого всё равно найдёт обычный поиск игр,
## и запись обновится.
##
## Чего здесь принципиально нет и не будет без сервера в интернете: доставки
## приглашения в **закрытую** игру. Разбудить приложение на другом телефоне может
## только push-уведомление, а для него нужны сервер и учётные записи. Поэтому
## приглашение долетает, пока у соперника игра открыта и он в той же сети.

const PATH := "user://friends.cfg"
const MAX_KEPT := 12          # больше в списке всё равно не найти глазами

## Все знакомые, свежие сверху: [{name, address, last_seen, games}].
static func all() -> Array:
	var cfg := ConfigFile.new()
	if cfg.load(PATH) != OK:
		return []
	var out := []
	for key in cfg.get_sections():
		out.append({
			"name": String(cfg.get_value(key, "name", key)),
			"address": String(cfg.get_value(key, "address", "")),
			"last_seen": int(cfg.get_value(key, "last_seen", 0)),
			"games": int(cfg.get_value(key, "games", 0)),
		})
	out.sort_custom(func(a, b): return int(a["last_seen"]) > int(b["last_seen"]))
	return out

## Запомнить, что сыграли вместе. Ключ — имя: адрес в домашней сети меняется, а
## имя игрок задаёт сам и меняет редко.
static func remember(player: String, address: String, now: int) -> void:
	var name_clean := Profile.sanitize(player)
	if name_clean == "" or name_clean == Profile.display_name():
		return
	var cfg := ConfigFile.new()
	cfg.load(PATH)      # файла может не быть — это нормально
	var key := _key(name_clean)
	var games := int(cfg.get_value(key, "games", 0)) + 1
	cfg.set_value(key, "name", name_clean)
	if address != "":
		cfg.set_value(key, "address", address)
	cfg.set_value(key, "last_seen", now)
	cfg.set_value(key, "games", games)
	_trim(cfg)
	cfg.save(PATH)

## Обновить адрес, когда знакомый нашёлся в сети, но играть ещё не сели.
static func seen(player: String, address: String, now: int) -> void:
	var name_clean := Profile.sanitize(player)
	if name_clean == "" or address == "":
		return
	var cfg := ConfigFile.new()
	if cfg.load(PATH) != OK:
		return
	var key := _key(name_clean)
	if not cfg.has_section(key):
		return
	cfg.set_value(key, "address", address)
	cfg.set_value(key, "last_seen", now)
	cfg.save(PATH)

static func forget(player: String) -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PATH) != OK:
		return
	var key := _key(player)
	if cfg.has_section(key):
		cfg.erase_section(key)
		cfg.save(PATH)

## «Играли только что» / «вчера» / «три дня назад». Точная дата тут не нужна —
## нужен ответ на вопрос «этот человек ещё рядом?».
static func when_text(last_seen: int, now: int) -> String:
	var days := int(floor(float(maxi(now - last_seen, 0)) / 86400.0))
	if days <= 0:
		return "сегодня"
	if days == 1:
		return "вчера"
	if days < 7:
		return "%d дн. назад" % days
	if days < 30:
		return "%d нед. назад" % int(days / 7)
	return "давно"

static func _key(player: String) -> String:
	# в имени бывают пробелы, а секция ConfigFile их переживает плохо
	return player.to_lower().replace(" ", "_")

## Держим только последних: список нужен, чтобы ткнуть в знакомого, а не вести
## архив.
static func _trim(cfg: ConfigFile) -> void:
	var rows := []
	for key in cfg.get_sections():
		rows.append({"key": key, "last_seen": int(cfg.get_value(key, "last_seen", 0))})
	if rows.size() <= MAX_KEPT:
		return
	rows.sort_custom(func(a, b): return int(a["last_seen"]) > int(b["last_seen"]))
	for i in range(MAX_KEPT, rows.size()):
		cfg.erase_section(String(rows[i]["key"]))
