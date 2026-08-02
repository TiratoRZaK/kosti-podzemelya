extends SceneTree

## Ивенты: предложения, оплата, оберег и поведение бота.
##
## Запуск:
##   ...console.exe --headless --path godot --script tests/test_events.gd

var fails := 0

func _init() -> void:
	print("")
	print("--- предложения ---")
	print("")
	roll_case()
	print("")
	print("--- покупки ---")
	print("")
	buy_case()
	reroll_case()
	spy_case()
	swap_case()
	print("")
	print("--- оберег ---")
	print("")
	ward_case()
	print("")
	print("--- бот ---")
	print("")
	bot_case()

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

func party(n: int, seed_value: int = 4242) -> Dictionary:
	var roster := []
	for i in n:
		roster.append({"kind": "bot", "local": false, "name": "Бот %d" % (i + 1)})
	return MatchState.new_match("classic", seed_value, "roster", "p", "", "Ты", [], roster)

# ----------------------------------------------------------------- сценарии

## В первом раунде ивентов нет, дальше выпадают, и у всех от одного сида
## одинаково: по сети это позволяет не пересылать предложения.
func roll_case() -> void:
	var a := party(3)
	var first := Events.roll(a)
	check(first.is_empty(), "в первом раунде предложений нет", "выпало %d" % first.size())

	a["round"] = 3
	var b := party(3)
	b["round"] = 3
	var ra := Events.roll(a)
	var rb := Events.roll(b)
	var same := JSON.stringify(ra) == JSON.stringify(rb)
	check(same, "тот же сид — те же предложения", "%d против %d" % [ra.size(), rb.size()])

	var kinds_ok := true
	for seat in ra:
		if not Events.KINDS.has(String(ra[seat]["kind"])):
			kinds_ok = false
		if String(ra[seat]["kind"]) == "buy" and ra[seat]["offer"].size() != 3:
			kinds_ok = false
	check(kinds_ok, "предложения знакомого вида, у торговца три куба",
		"выпало %d предложений" % ra.size())

	# выбывшим не предлагают
	var c := party(3)
	c["round"] = 4
	c["players"]["e"]["out"] = true
	var rc := Events.roll(c)
	check(not rc.has("e"), "выбывшему предложение не выпадает")

func buy_case() -> void:
	var s := party(2)
	s["players"]["p"]["total"] = 100
	var was: int = s["players"]["p"]["hand"].size()
	var offer := [{"value": 2, "type": "basic"}, {"value": 6, "type": "shield"}]
	var res := Events.apply_buy(s, "p", offer, 1)
	var hand: Array = s["players"]["p"]["hand"]
	var ok: bool = bool(res["ok"]) and hand.size() == was + 1 \
		and int(hand[hand.size() - 1]["value"]) == 6 \
		and int(s["players"]["p"]["total"]) == 100 - Events.cost_of("buy")
	check(ok, "торговец кладёт куб в руку и берёт плату",
		"рука %d → %d | очки %d" % [was, hand.size(), int(s["players"]["p"]["total"])])

func reroll_case() -> void:
	var s := party(2)
	s["players"]["p"]["total"] = 100
	s["players"]["p"]["hand"][0] = {"value": 1, "type": "basic"}
	var res := Events.apply_reroll(s, "p", 0, 6)
	var ok: bool = bool(res["ok"]) and int(s["players"]["p"]["hand"][0]["value"]) == 6 \
		and int(s["players"]["p"]["total"]) == 100 - Events.cost_of("reroll")
	check(ok, "точильщик меняет значение куба", "было %d стало %d | очки %d" % [
		int(res["was"]), int(res["now"]), int(s["players"]["p"]["total"])])

	# тип куба при этом сохраняется: точат грани, а не подменяют куб
	var s2 := party(2)
	s2["players"]["p"]["total"] = 100
	s2["players"]["p"]["hand"][0] = {"value": 2, "type": "mine"}
	Events.apply_reroll(s2, "p", 0, 5)
	check(String(s2["players"]["p"]["hand"][0]["type"]) == "mine",
		"точильщик не трогает способность куба")

func spy_case() -> void:
	var s := party(2)
	s["players"]["p"]["total"] = 100
	var res := Events.apply_spy(s, "p", "e")
	var ok: bool = bool(res["ok"]) and not bool(res["blocked"]) \
		and res["hand"].size() == s["players"]["e"]["hand"].size() \
		and int(s["players"]["p"]["total"]) == 100 - Events.cost_of("spy")
	check(ok, "соглядатай показывает руку соперника",
		"кубов видно %d | очки %d" % [res["hand"].size(), int(s["players"]["p"]["total"])])

func swap_case() -> void:
	var s := party(2)
	s["players"]["p"]["total"] = 100
	s["players"]["p"]["hand"][0] = {"value": 1, "type": "basic"}
	s["players"]["e"]["hand"][0] = {"value": 6, "type": "warlock"}
	var res := Events.apply_swap(s, "p", 0, "e", 0)
	var ok: bool = bool(res["ok"]) and not bool(res["blocked"]) \
		and int(s["players"]["p"]["hand"][0]["value"]) == 6 \
		and String(s["players"]["p"]["hand"][0]["type"]) == "warlock" \
		and int(s["players"]["e"]["hand"][0]["value"]) == 1
	check(ok, "меняла обменивает кубы местами", "у меня %d, у него %d" % [
		int(s["players"]["p"]["hand"][0]["value"]), int(s["players"]["e"]["hand"][0]["value"])])

## Оберег закрывает руку и от подглядывания, и от обмена — и сгорает.
func ward_case() -> void:
	var s := party(2)
	s["players"]["p"]["total"] = 200
	s["players"]["e"]["total"] = 200
	Events.apply_ward(s, "e")
	var paid: bool = int(s["players"]["e"]["total"]) == 200 - Events.WARD_COST
	var spy := Events.apply_spy(s, "p", "e")
	var blocked: bool = bool(spy["blocked"]) and spy["hand"].is_empty()
	# сгорел — второй раз уже не спасёт
	var spy2 := Events.apply_spy(s, "p", "e")
	var burned: bool = not bool(spy2["blocked"])
	check(paid and blocked and burned, "оберег закрывает руку один раз и сгорает",
		"оплачен=%s закрыл=%s сгорел=%s" % [str(paid), str(blocked), str(burned)])

	var s2 := party(2)
	s2["players"]["p"]["total"] = 200
	s2["players"]["e"]["total"] = 200
	s2["players"]["p"]["hand"][0] = {"value": 1, "type": "basic"}
	s2["players"]["e"]["hand"][0] = {"value": 6, "type": "basic"}
	Events.apply_ward(s2, "e")
	var sw := Events.apply_swap(s2, "p", 0, "e", 0)
	var kept: bool = bool(sw["blocked"]) and int(s2["players"]["p"]["hand"][0]["value"]) == 1
	check(kept, "оберег не даёт обменяться", "мой куб остался %d" % int(s2["players"]["p"]["hand"][0]["value"]))

	# платит даже тот, кого закрыли: ходил — плати
	var s3 := party(2)
	s3["players"]["p"]["total"] = 100
	s3["players"]["e"]["total"] = 200
	Events.apply_ward(s3, "e")
	Events.apply_spy(s3, "p", "e")
	check(int(s3["players"]["p"]["total"]) == 100 - Events.cost_of("spy"),
		"за неудачную вылазку тоже платят")

## Бот не спускает всё на первый же ивент и не покупает бесполезное.
func bot_case() -> void:
	var rng := MatchState.make_rng(7)
	var s := party(2)
	s["players"]["p"]["total"] = 50      # хватает на buy (40), но это больше половины
	var poor := Events.bot_choice(s, "p", {"kind": "buy", "offer": [
		{"value": 6, "type": "basic"}]}, rng)
	check(poor.is_empty(), "бот не тратит больше половины накопленного",
		"очки=50, цена=%d" % Events.cost_of("buy"))

	s["players"]["p"]["total"] = 200
	var rich := Events.bot_choice(s, "p", {"kind": "buy", "offer": [
		{"value": 2, "type": "basic"}, {"value": 6, "type": "basic"},
		{"value": 3, "type": "basic"}]}, rng)
	check(not rich.is_empty() and int(rich["idx"]) == 1, "бот берёт самый крупный куб",
		str(rich))

	var spy := Events.bot_choice(s, "p", {"kind": "spy", "offer": []}, rng)
	check(spy.is_empty(), "бот не покупает подглядывание: он всё равно не помнит руку")

	s["players"]["p"]["hand"][0] = {"value": 1, "type": "basic"}
	var sharp := Events.bot_choice(s, "p", {"kind": "reroll", "offer": []}, rng)
	check(not sharp.is_empty() and int(sharp["value"]) == 6, "бот точит слабый куб до шестёрки",
		str(sharp))
