-- The body is shorter than the model was generated (wormparts.lua: 40 rings): the rings of WORM_DROP are taken
-- out here, in pairs (a ring with legs and the one behind it without), so the legs still alternate and the taper
-- stays. Included right after wormparts.lua, on the server and the clients alike.
WORM_DROP = {15, 16, 23, 24}

do
	local drop, keep = {}, {}
	for _, i in ipairs(WORM_DROP) do drop[i] = true end
	for i, s in ipairs(WORM_PARTS.segments) do
		if not drop[i] then keep[#keep + 1] = s end
	end
	WORM_PARTS.segments = keep
end
