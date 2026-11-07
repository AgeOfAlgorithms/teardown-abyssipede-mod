-- Abyssipede options (Mod Manager): how many abyssipedes hunt on a map.

function draw()
	local n = GetInt("savegame.mod.count")
	if n < 1 then n = 1 end
	UiTranslate(UiCenter(), 300)
	UiAlign("center middle")
	UiFont("bold.ttf", 48)
	UiText("Abyssipede")
	UiTranslate(0, 90)
	UiFont("regular.ttf", 28)
	UiText("Abyssipedes on each map")
	UiTranslate(0, 60)
	UiFont("bold.ttf", 40)
	UiPush()
	for i = 1, 3 do
		UiPush()
		UiTranslate((i - 2) * 110, 0)
		if i == n then UiColor(1, 0.4, 0.3) else UiColor(0.8, 0.8, 0.8) end
		if UiTextButton(tostring(i), 80, 60) then SetInt("savegame.mod.count", i) end
		UiPop()
	end
	UiPop()
	UiTranslate(0, 80)
	UiFont("regular.ttf", 22)
	UiColor(0.8, 0.8, 0.8)
	UiText("More can be placed from the spawn menu (up to 6).")
	UiTranslate(0, 100)
	UiColor(1, 1, 1)
	UiFont("bold.ttf", 32)
	if UiTextButton("Close", 200, 50) then Menu() end
end
