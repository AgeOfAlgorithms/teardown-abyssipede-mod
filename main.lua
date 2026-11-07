#version 2
-- Abyssipede: a global enemy mod (PROJECT.md). The modules are global tables of callbacks: Nav (navigation),
-- Worm (the brains, server), WormView (drawing and sound, every machine). WORM_PARTS / WORM_SOUNDS are generated.

#include "wormparts.lua"
#include "wormsounds.lua"
#include "nav.lua"
#include "worm.lua"
#include "wormview.lua"

-- (test builds add their modules here)

function server.init()
	math.randomseed(GetInt("savegame.mod.seed") + 1)
	SetInt("savegame.mod.seed", (GetInt("savegame.mod.seed") + 7919) % 100000)
	Worm.serverInit()
	if WORM_TEST then WORM_TEST.serverInit() end
end

function server.tick(dt)
	Worm.serverTick(dt)
	if WORM_TEST then WORM_TEST.serverTick(dt) end
end

function server.update(dt)
	Worm.serverUpdate(dt)
	if WORM_TEST then WORM_TEST.serverUpdate(dt) end
end

function server.postUpdate()
	Worm.serverPostUpdate()
end

function client.init()
	WormView.clientInit()
	if WORM_TEST then WORM_TEST.clientInit() end
end

function client.tick(dt)
	WormView.clientTick(dt)
	if WORM_TEST then WORM_TEST.clientTick(dt) end
end

function client.draw()
	WormView.clientDraw()
end
