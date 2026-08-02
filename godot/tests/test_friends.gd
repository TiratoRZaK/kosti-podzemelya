extends SceneTree

## Список знакомых по Wi-Fi: запоминание, обновление адреса, порядок и обрезка.
##
## Запуск:
##   ...console.exe --headless --path godot --script tests/test_friends.gd

var fails := 0

func _init() -> void:
	print("")
	print("--- знакомые ---")
	print("")
	# файл общий с профилем игрока, поэтому перед прогоном чистим
	DirAccess.remove_absolute(Friends.PATH)
	remember_case()
	order_case()
	trim_case()
	seen_case()
	when_case()
	DirAccess.remove_absolute(Friends.PATH)

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

func remember_case() -> void:
	Friends.remember("Костя", "192.168.1.5", 1000)
	Friends.remember("Костя", "192.168.1.7", 2000)
	var all := Friends.all()
	var ok: bool = all.size() == 1 and String(all[0]["address"]) == "192.168.1.7" \
		and int(all[0]["games"]) == 2
	check(ok, "повторная партия обновляет адрес и считает встречи",
		"записей=%d адрес=%s партий=%d" % [all.size(), String(all[0]["address"]),
			int(all[0]["games"])])

	# сам себя в знакомые не записываем
	Friends.remember(Profile.display_name(), "192.168.1.9", 3000)
	check(Friends.all().size() == 1, "себя в список не добавляем")

func order_case() -> void:
	Friends.remember("Аня", "192.168.1.8", 5000)
	Friends.remember("Дима", "192.168.1.3", 4000)
	var all := Friends.all()
	var names := []
	for f in all:
		names.append(String(f["name"]))
	check(names[0] == "Аня", "свежие сверху", str(names))

func trim_case() -> void:
	for i in 20:
		Friends.remember("Гость %d" % i, "10.0.0.%d" % i, 10000 + i)
	var all := Friends.all()
	check(all.size() == Friends.MAX_KEPT, "список не растёт бесконечно",
		"записей=%d при пределе %d" % [all.size(), Friends.MAX_KEPT])

func seen_case() -> void:
	Friends.remember("Ваня", "192.168.1.20", 20000)
	Friends.seen("Ваня", "192.168.1.44", 21000)
	var found := {}
	for f in Friends.all():
		if String(f["name"]) == "Ваня":
			found = f
	var ok: bool = String(found.get("address", "")) == "192.168.1.44" \
		and int(found.get("games", 0)) == 1
	check(ok, "встреча в сети обновляет адрес, но не счётчик партий", str(found))

	# незнакомого «увидели» — в список он не попадает
	Friends.seen("Прохожий", "192.168.1.99", 21000)
	var has := false
	for f in Friends.all():
		if String(f["name"]) == "Прохожий":
			has = true
	check(not has, "просто увиденный в сети знакомым не становится")

func when_case() -> void:
	var now := 1000000
	var ok: bool = Friends.when_text(now, now) == "сегодня" \
		and Friends.when_text(now - 86400, now) == "вчера" \
		and Friends.when_text(now - 86400 * 3, now) == "3 дн. назад" \
		and Friends.when_text(now - 86400 * 40, now) == "давно"
	check(ok, "давность пишется по-человечески",
		"%s / %s / %s" % [Friends.when_text(now - 86400, now),
			Friends.when_text(now - 86400 * 3, now), Friends.when_text(now - 86400 * 40, now)])
