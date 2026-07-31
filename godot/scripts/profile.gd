class_name Profile
extends RefCounted

## Имя игрока: спрашивается один раз при первом запуске и дальше стоит везде —
## в своей зоне на экране, в фразах хотсита, в списке игр по Wi-Fi и в лобби.
##
## Хранится в `user://profile.cfg` — это внутренняя память приложения на телефоне.
## Веб-прототипу хранилище запрещено (он открывается в предпросмотрах без него), а
## здесь спрашивать имя каждый запуск было бы издевательством.

const PATH := "user://profile.cfg"
const MAX_LEN := 16
const FALLBACK := "Игрок"

static var _cached := ""
static var _loaded := false

## Имя из файла; пустая строка означает «ещё не спрашивали».
static func player_name() -> String:
	if not _loaded:
		_loaded = true
		var cfg := ConfigFile.new()
		if cfg.load(PATH) == OK:
			_cached = sanitize(String(cfg.get_value("profile", "name", "")))
	return _cached

## Имя для показа: если не задано, всё равно должно быть чем подписать зону.
static func display_name() -> String:
	var n := player_name()
	return n if n != "" else FALLBACK

static func has_name() -> bool:
	return player_name() != ""

static func save_name(raw: String) -> bool:
	var n := sanitize(raw)
	if n == "":
		return false
	_cached = n
	_loaded = true
	var cfg := ConfigFile.new()
	cfg.set_value("profile", "name", n)
	return cfg.save(PATH) == OK

## Имя уезжает по сети и подставляется в тексты, поэтому режем пробелы, переводы
## строк и длину: «Игрок 1 берёт раунд» не должно превращаться в простыню.
static func sanitize(raw: String) -> String:
	var n := raw.strip_edges()
	n = n.replace("\n", " ").replace("\t", " ").replace("\r", "")
	while n.contains("  "):
		n = n.replace("  ", " ")
	if n.length() > MAX_LEN:
		n = n.substr(0, MAX_LEN).strip_edges()
	return n
