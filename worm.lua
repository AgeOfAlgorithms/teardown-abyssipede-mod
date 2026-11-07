-- Worm: the abyssipedes' brains and bodies on the server (PROJECT.md: Interfaces). Each worm is a head that moves
-- freely in 3D (water and air alike) and a trail of the head's past positions that the body lies along, so the body
-- never passes through anything the head did not. The server publishes the trails in shared.worms; each client draws
-- its own body parts along them (wormview.lua).
--
-- States: lurk (wanders, long freezes, drifts toward life), stalk (heads for where it last sensed someone), chase
-- (sees its prey), windup + lunge (jaws wide, a shriek, a straight strike), drag (a seized player is hauled to its
-- lair), flee (hurt: back to the lair), dead. Its tempo is erratic in every state: freezes, creeping, glides, darts,
-- twitches and recoils, picked at random with weights per state. It senses light (flashlights), sound
-- (GetLastSound), movement close by and sight in the dark only up close. Whatever blocks it, it bites through
-- (MakeHole): when the planner routes it through a wall, or when it is stuck.

Worm = {}

WORM_LAYER = 64               -- the hit boxes' and the drawn body's collision layer (nothing collides with them;
WORM_QUERY_MASK = 63          -- players' CollisionMask leaves it out); our queries skip it and Dive's fish (128)
WORM_MAX = 6                  -- worms at most (the count option + spawn-menu worms)
TRAIL_STEP = 0.15             -- m between recorded head positions
TRAIL_PUB = 0.5               -- m between the published trail's points
TRAIL_SPARE = 6               -- m of trail kept behind the tail (for recoils)
PUBLISH_HZ = 12
HEAD_R = 0.24                 -- m: the head's clearance in its own moves (sphere casts)
TIGHT_R = 0.12                -- m: ... on legs through gaps players proved passable (Nav's tight legs: 0.15 m clear)
BODY_LEN = 16                 -- m (from WORM_PARTS when present)
HP = 160
SENSE_HZ = 5
NEAR_SENSE = 7                -- m: felt whatever it does (the water/air moving)
MOVE_SENSE = 14               -- m: felt when it moves fast
LIGHT_SENSE = 38              -- m: a flashlight in its line of sight
DARK_SIGHT = 9                -- m: seen without light
HEAR_K = 55                   -- m of hearing per unit of GetLastSound volume
FORGET_T = 14                 -- s: a stalk gives up this long after the last sensing
LUNGE_RANGE = 4.5
LUNGE_SPEED = 17
LUNGE_T = 0.45
WINDUP_T = 0.38
LUNGE_CD = 2.4
GRAB_R = 1.35
DRAG_SPEED = 4.2
DRAG_MAX = 16                 -- s until a dragged player dies, if the lair is not reached first
DRAG_HURT = 0.035             -- health per second while held
RELEASE_DMG = 26              -- damage taken during a drag that makes it let go
BITE_CD = 1.2
HARD_BITE = 25              -- voxels: a bite cutting fewer met something it can't bite (and backs out)
HARD_BACK = 2.5             -- m it backs out along its body
BITE_R = {1.7, 1.25, 0.75}    -- MakeHole radii (soft, medium, hard): the "super destructive" bite
STUCK_T = 1.4
RESPAWN_T = 150
CORPSE_T = 25
SPAWN_DELAY = 18
SPEED = {lurk = 2.6, roam = 6.5, stalk = 4.2, chase = 6.0, drag = 4.2, flee = 8.5}
ROAM_D = 45                   -- m: farther than this from every player, a lurking worm roams toward them
WATER_SLOW = 0.8              -- in water a bit slower (divers swim ~3 m/s)
-- erratic tempo: {weight, speed factor, min s, max s} per state
TEMPO = {
	lurk = {{0.35, 0, 1.0, 4.0}, {0.40, 0.35, 1.0, 3.0}, {0.20, 1.0, 0.5, 2.0}, {0.05, 2.3, 0.2, 0.5}},
	stalk = {{0.25, 0, 0.4, 1.8}, {0.25, 0.4, 0.5, 1.5}, {0.30, 1.0, 0.5, 1.6}, {0.20, 2.1, 0.2, 0.6}},
	chase = {{0.08, 0, 0.15, 0.5}, {0.40, 1.0, 0.3, 1.0}, {0.52, 1.8, 0.2, 0.8}},
	drag = {{0.15, 0, 0.2, 0.6}, {0.85, 1.0, 0.5, 1.5}},
	flee = {{1.0, 1.0, 1.0, 2.0}},
}
TWITCH = {lurk = 0.5, stalk = 1.3, chase = 1.0, drag = 1.5, flee = 0.6}     -- twitches per second

local function now() return GetTime() end
local function vlen(v) return VecLength(v) end
local function dist(a, b) return VecLength(VecSub(a, b)) end

function wormFilter()
	QueryRequire("physical static")
	QueryCollisionMask(WORM_QUERY_MASK)
end

-- sphere cast from a to b; true when clear
function wormClear(a, b, r)
	local d = VecSub(b, a)
	local l = VecLength(d)
	if l < 0.001 then return true end
	wormFilter()
	local hit = QueryRaycast(a, VecScale(d, 1 / l), l, r or HEAD_R)
	return not hit
end

function wormFree(p, r)
	wormFilter()
	local hit = QueryClosestPoint(p, r)
	return not hit
end

function wormChest(p)
	return VecAdd(GetPlayerTransform(p).pos, Vec(0, 1.1, 0))
end

local function pick(list)
	local r, acc = math.random(), 0
	for _, e in ipairs(list) do
		acc = acc + e[1]
		if r <= acc then return e end
	end
	return list[#list]
end

----- trail: trail[1] oldest .. trail[#trail] newest (next to the head) -----

function wormTrailLen(w)
	local L, t = 0, w.trail
	for i = #t, 2, -1 do L = L + dist(t[i], t[i - 1]) end
	return L + dist(w.pos, t[#t])
end

function wormRecord(w)
	local t = w.trail
	local d = dist(w.pos, t[#t])
	if d >= TRAIL_STEP then
		t[#t + 1] = VecCopy(w.pos)
		w.trailLen = w.trailLen + d
		local keep = BODY_LEN + TRAIL_SPARE
		while #t > 2 and w.trailLen > keep do
			w.trailLen = w.trailLen - dist(t[1], t[2])
			table.remove(t, 1)
		end
	end
end

-- move the head back along its own trail by d m (a recoil: always free, the head has been there)
function wormRecoil(w, d)
	local t = w.trail
	while d > 0 and #t > 2 do
		local last = t[#t]
		local step = dist(w.pos, last)
		if step > d then
			w.pos = VecAdd(w.pos, VecScale(VecNormalize(VecSub(last, w.pos)), d))
			d = 0
		else
			w.pos = VecCopy(last)
			d = d - step
			t[#t] = nil
			w.trailLen = math.max(0, w.trailLen - step)
		end
	end
	if #t >= 2 then w.fwd = VecNormalize(VecSub(w.pos, t[#t - 1])) end
end

-- points along the body from the head back, every `step` m, up to `len` m (flat x, y, z list)
function wormSample(w, step, len)
	local out = {w.pos[1], w.pos[2], w.pos[3]}
	local t = w.trail
	local prev, want, acc = w.pos, step, 0
	for i = #t, 1, -1 do
		local q = t[i]
		local seg = dist(prev, q)
		while seg > 0 and acc + seg >= want and want <= len do
			local f = (want - acc) / seg
			local p = VecLerp(prev, q, f)
			out[#out + 1] = p[1]; out[#out + 1] = p[2]; out[#out + 1] = p[3]
			want = want + step
		end
		acc = acc + seg
		prev = q
		if want > len then break end
	end
	return out
end

----- spawning -----

function wormMapBounds()
	local lo, hi = GetBodyBounds(GetWorldBody())
	if not lo or (hi[1] - lo[1]) < 10 then
		local p = GetAllPlayers()[1]
		local c = p and GetPlayerTransform(p).pos or Vec(0, 0, 0)
		return VecAdd(c, Vec(-120, -20, -120)), VecAdd(c, Vec(120, 40, 120))
	end
	return lo, hi
end

-- a random lair candidate and its score (nil: unusable)
function wormCandidate(lo, hi, minD)
	local p = Vec(lo[1] + math.random() * (hi[1] - lo[1]), lo[2] + math.random() * (hi[2] - lo[2]),
		lo[3] + math.random() * (hi[3] - lo[3]))
	if not wormFree(p, 0.9) then return nil end
	wormFilter()
	local down, dd = QueryRaycast(p, Vec(0, -1, 0), 30)
	local water = IsPointInWater(p)
	if not down and not water then return nil end              -- not hanging in the open sky
	local score = 0
	for _, q in ipairs(GetAllPlayers()) do
		local e = GetPlayerEyeTransform(q).pos
		local d = dist(e, p)
		if d < minD then return nil end
		if d < 70 and wormClear(e, p, 0.05) then return nil end   -- not in anyone's sight
		score = score + math.min(d, 150) * 0.01
	end
	wormFilter()
	local up, du = QueryRaycast(p, Vec(0, 1, 0), 14)
	if up then score = score + 2 end                           -- under cover: dark
	if water then score = score + 2 end
	if down and dd < 6 then score = score + 1 end
	return p, score
end

function wormNew(lair)
	local w = {
		id = wormNextId, pos = VecCopy(lair), fwd = Vec(1, 0, 0), vel = Vec(0, 0, 0), speed = 0,
		trail = {VecCopy(lair)}, trailLen = 0, lair = VecCopy(lair),
		alive = true, hp = HP, state = "lurk", t0 = now(), stateT = now(),
		tempo = nil, tempoUntil = 0, twitchUntil = 0, twitchDir = nil,
		target = 0, known = nil, knownT = -100, aware = {},
		goal = nil, path = nil, pathI = 1, planT = -100, planGoal = nil, digs = nil,
		lungeCd = 0, biteT = -100, stuckT = now(), stuckD = 1e9,
		grab = 0, grabT = 0, dmgInDrag = 0,
		mouth = 0, glow = 0.3, hurtT = -100, ev = {bite = 0, lunge = 0, hiss = 0, grab = 0, hurt = 0, die = 0},
		boxes = {}, deadT = 0, wanderT = 0, hits = {}, hitSeq = 0,
	}
	wormNextId = wormNextId + 1
	wormBoxesSpawn(w)
	return w
end

----- hit boxes (server): invisible, in WORM_LAYER, mask 0 (bullets find them by query) -----

HIT_BOXES = 9
HIT_SPACING = 1.8

function wormBoxesSpawn(w)
	w.boxes = {}
	for i = 1, HIT_BOXES do
		local s = i == 1 and 8 or 6
		local xml = string.format("<body tags='abyssipedehit'><voxbox tags='invisible unbreakable' pos='%.2f %.2f %.2f' size='%d %d %d' color='0 0 0'/></body>",
			-s * 0.05, -s * 0.05, -s * 0.05, s, s, s)
		local ents = Spawn(xml, Transform(Vec(0, -500, 0)))
		for _, e in ipairs(ents or {}) do
			if GetEntityType(e) == "body" then
				for _, sh in ipairs(GetBodyShapes(e)) do
					SetShapeCollisionFilter(sh, WORM_LAYER, 0)
					wormHitShapes[sh] = {w = w, head = i == 1}
				end
				w.boxes[#w.boxes + 1] = e
			end
		end
	end
end

function wormBoxesDelete(w)
	for _, b in ipairs(w.boxes) do
		for _, sh in ipairs(GetBodyShapes(b)) do wormHitShapes[sh] = nil end
		Delete(b)
	end
	w.boxes = {}
end

function wormBoxesMove(w)
	local pts = wormSample(w, HIT_SPACING, HIT_SPACING * (HIT_BOXES - 1))
	for i, b in ipairs(w.boxes) do
		local k = (i - 1) * 3
		local p = pts[k + 1] and Vec(pts[k + 1], pts[k + 2], pts[k + 3]) or Vec(0, -500, 0)
		SetBodyTransform(b, Transform(p))
	end
	w.boxPts = pts                                                 -- (the boxes in use, for the registry API)
end

----- the registry API (any mod; PROJECT.md: Interfaces) -----
-- Scripts can't call each other, so other mods' projectiles meet the worm through two registry strings:
-- abyssipede.hitpoints (written here every tick): "id x y z r head;" per live hit box, head to tail, for their own tests;
-- abyssipede.damage (a queue they append to, read and cleared here every tick): "x y z amount;" per hit.

API_HIT_R = {0.6, 0.5}       -- m: the published radius of the head's box (0.4 m half-size) and the body's (0.3 m)
API_DAMAGE_D = 1.5           -- m: a damage point counts for the nearest live worm whose body passes this close
API_DAMAGE_MAX = 32          -- entries taken per tick (the rest are dropped with the queue)

function wormPublishHitpoints()
	local out, n = {}, 0
	for _, w in ipairs(wormList) do
		local pts = w.alive and w.boxPts
		if pts then
			for k = 1, math.min(#pts, HIT_BOXES * 3), 3 do
				n = n + 1
				local head = k == 1
				out[n] = string.format("%d %.2f %.2f %.2f %.2f %d;", w.id, pts[k], pts[k + 1], pts[k + 2],
					API_HIT_R[head and 1 or 2], head and 1 or 0)
			end
		end
	end
	local s = table.concat(out)
	if s ~= wormHitpointsLast then
		SetString("abyssipede.hitpoints", s)
		wormHitpointsLast = s
	end
end

local function finite(x) return x and x == x and x > -1e9 and x < 1e9 end

function wormTakeApiDamage()
	local q = GetString("abyssipede.damage")
	if q == "" then return end
	SetString("abyssipede.damage", "")
	local taken = 0
	for entry in string.gmatch(q, "[^;]+") do
		if taken >= API_DAMAGE_MAX then break end
		taken = taken + 1
		local x, y, z, a = string.match(entry, "^%s*(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s*$")
		x, y, z, a = tonumber(x), tonumber(y), tonumber(z), tonumber(a)
		if finite(x) and finite(y) and finite(z) and finite(a) and a > 0 then
			local p = Vec(x, y, z)
			local best, bestD = nil, API_DAMAGE_D
			for _, w in ipairs(wormList) do
				if w.alive then
					local pts = wormSample(w, 0.5, BODY_LEN)
					for k = 1, #pts, 3 do
						local d = dist(p, Vec(pts[k], pts[k + 1], pts[k + 2]))
						if d < bestD then best, bestD = w, d end
					end
				end
			end
			if best then wormDamage(best, math.min(a, HP), "api", p) end
		end
	end
end

----- damage -----

HITS_KEPT = 6                -- the last hits per worm, published for the clients' ichor puffs (shared.worms[i].hits)

-- point: where it was hit (nil: the head)
function wormDamage(w, d, kind, point)
	if not w.alive or d <= 0 then return end
	local p = point or w.pos
	w.hitSeq = w.hitSeq + 1
	local h = w.hits
	h[#h + 1] = w.hitSeq; h[#h + 1] = p[1]; h[#h + 1] = p[2]; h[#h + 1] = p[3]; h[#h + 1] = d
	while #h > HITS_KEPT * 5 do
		for _ = 1, 5 do table.remove(h, 1) end
	end
	w.hp = w.hp - d
	w.hurtT = now()
	w.ev.hurt = w.ev.hurt + 1
	if w.state == "drag" then w.dmgInDrag = w.dmgInDrag + d end
	if w.hp <= 0 then
		wormDie(w)
	elseif d >= 6 and w.state ~= "drag" then
		wormRecoil(w, math.min(2.5, 0.6 + d * 0.06))
		if w.hp < HP * 0.3 and w.state ~= "flee" then wormSetState(w, "flee") end
	end
end

function wormDie(w)
	if w.grab ~= 0 then wormRelease(w) end
	w.alive = false
	w.state = "dead"
	w.deadT = now()
	w.ev.die = w.ev.die + 1
	wormBoxesDelete(w)
	Nav.cancel(w.id)
end

function wormTakeHits()
	for i = 1, GetEventCount("projectilehit") do
		local shape, point = GetEvent("projectilehit", i)
		local h = wormHitShapes[shape]
		if h then wormDamage(h.w, h.head and 7 or 3, "bullet", point) end
	end
	for i = 1, GetEventCount("explosion") do
		local point, strength = GetEvent("explosion", i)
		strength = strength or 1
		for _, w in ipairs(wormList) do
			if w.alive then
				local pts = wormSample(w, 1.0, BODY_LEN)
				local best, bestP = 1e9, nil
				for k = 1, #pts, 3 do
					local q = Vec(pts[k], pts[k + 1], pts[k + 2])
					local d = dist(point, q)
					if d < best then best, bestP = d, q end
				end
				local r = 3.5 * strength
				if best < r then wormDamage(w, 70 * strength * (1 - best / r), "explosion", bestP) end
			end
		end
	end
	for _, q in ipairs(GetAllPlayers()) do                      -- sledge swings at the head
		if GetPlayerTool(q) == "sledge" and InputPressed("usetool", q) and GetPlayerHealth(q) > 0 then
			local eye = GetPlayerEyeTransform(q)
			for _, w in ipairs(wormList) do
				if w.alive then
					local v = VecSub(w.pos, eye.pos)
					local d = vlen(v)
					if d < 3 and VecDot(VecScale(v, 1 / math.max(d, 0.01)), TransformToParentVec(eye, Vec(0, 0, -1))) > 0.6 then
						wormDamage(w, 10, "sledge", w.pos)
					end
				end
			end
		end
	end
end

----- the bite -----

function wormBite(w, dir)
	if now() - w.biteT < BITE_CD then return false end
	w.biteT = now()
	w.mouth = 1
	w.ev.bite = w.ev.bite + 1
	local d = dir or w.fwd
	local p = VecAdd(w.pos, VecScale(d, 0.8))
	local cut = (MakeHole(p, BITE_R[1], BITE_R[2], BITE_R[3]) or 0)
		+ (MakeHole(VecAdd(p, VecScale(d, 0.9)), BITE_R[1] * 0.8, BITE_R[2] * 0.8, BITE_R[3] * 0.7, true) or 0)
	Nav.forget(p, 3)
	-- next to nothing cut and still no way ahead: something it can't bite (hard metal, an unbreakable wall). Mark it
	-- for the navigation (no dig through it again), back out along the body and plan another way
	if cut < HARD_BITE and not wormClear(w.pos, VecAdd(p, VecScale(d, 1.0)), HEAD_R * 0.8) then
		Nav.markHard(VecAdd(p, VecScale(d, 0.5)), 1.2)
		wormRecoil(w, HARD_BACK)
		w.goal, w.path, w.planGoal = nil, nil, nil
		w.ev.hard = (w.ev.hard or 0) + 1
	end
	return true
end

-- open space under what lies below p within 6 m (a deck, a floor, a roof): biting down goes somewhere. Solid ground
-- (the map's terrain, the sea floor) has none, and the worm never digs into it
function wormFloorBelow(p)
	wormFilter()
	local hit, d = QueryRaycast(p, Vec(0, -1, 0), 6, 0)
	if not hit then return false end
	for _, extra in ipairs({1.0, 2.0}) do
		local q = VecAdd(p, Vec(0, -(d + extra), 0))
		if wormFree(q, 0.6) then return true end
	end
	return false
end

----- grab and drag -----

function wormGrab(w, p)
	w.grab = p
	w.grabT = now()
	w.dmgInDrag = 0
	w.ev.grab = w.ev.grab + 1
	w.mouth = 0.35
	wormGrabbed[p] = w
	wormSetState(w, "drag")
end

function wormRelease(w)
	if w.grab ~= 0 then wormGrabbed[w.grab] = nil end
	w.grab = 0
	w.mouth = 1
	w.lungeCd = now() + 3
	wormRecoil(w, 2)
end

function wormJaw(w)
	return VecAdd(w.pos, VecScale(w.fwd, 0.55))
end

----- states -----

function wormSetState(w, s)
	if w.state == s then return end
	if (s == "chase" and w.state ~= "windup" and w.state ~= "lunge") then w.ev.hiss = w.ev.hiss + 1 end
	w.state = s
	w.stateT = now()
	w.tempoUntil = 0
	w.path = nil
	w.planGoal = nil
end

function wormSense(w)
	local best, bestS = 0, 0
	local vol, spos
	local heard = wormHeard                                        -- (the loudest sound since the last sensing)
	vol, spos = heard and heard.vol, heard and heard.pos
	local own = false                                             -- (its own bites are loud: not prey)
	if vol and spos then
		for _, o in ipairs(wormList) do if o.alive and dist(spos, o.pos) < 4 then own = true end end
	end
	if vol and vol > 0.04 and spos and not own then
		local d = dist(spos, w.pos)
		if d < vol * HEAR_K then
			w.known = VecCopy(spos)
			w.knownT = now()
			if w.state == "lurk" then wormSetState(w, "stalk") end
		end
	end
	for _, p in ipairs(GetAllPlayers()) do
		if GetPlayerHealth(p) > 0 and not wormGrabbed[p] then
			local c = wormChest(p)
			local d = dist(c, w.pos)
			local s = 0
			if d < NEAR_SENSE then s = 3 end
			if d < MOVE_SENSE and vlen(GetPlayerVelocity(p)) > 2.5 then s = math.max(s, 2) end
			if d < LIGHT_SENSE then
				local fl = GetFlashlight(p)
				local lit = fl ~= 0 and IsLightActive(fl)
				if (lit or d < DARK_SIGHT) and wormClear(w.pos, c, 0.05) then s = math.max(s, lit and 4 or 3) end
			end
			if s > 0 then s = s + 1 / (1 + d) end
			if s > bestS then best, bestS = p, s end
		end
	end
	if best ~= 0 then
		w.target = best
		w.known = wormChest(best)
		w.knownT = now()
		local d = dist(w.known, w.pos)
		if bestS >= 3 and (w.state == "lurk" or w.state == "stalk") then
			wormSetState(w, "chase")
		elseif w.state == "lurk" then
			wormSetState(w, "stalk")
		end
		w.seeing = bestS >= 3
	else
		w.seeing = false
		if (w.state == "chase" or w.state == "stalk") and now() - w.knownT > FORGET_T then
			wormSetState(w, "lurk")
		elseif w.state == "chase" and now() - w.knownT > 2.5 then
			wormSetState(w, "stalk")
		end
	end
end

-- a goal it may wander to: free, and in water or within 10 m above something (it keeps out of the open sky)
function wormGoalOk(g)
	if not Nav.free(g) then return false end
	if IsPointInWater(g) then return true end
	wormFilter()
	return (QueryRaycast(g, Vec(0, -1, 0), 10))
end

-- a lurk goal: somewhere free nearby, or now and then toward the players (it drifts toward life)
function wormWanderGoal(w)
	-- drawn to life: mostly somewhere near the nearest living player (closer each time it comes back to them)
	local best, bd = nil, 1e9
	for _, p in ipairs(GetAllPlayers()) do
		if GetPlayerHealth(p) > 0 then
			local d = dist(wormChest(p), w.pos)
			if d < bd then best, bd = p, d end
		end
	end
	if best and math.random() < ((w.far or 0) > ROAM_D and 0.9 or 0.6) then
		local c = wormChest(best)
		local spread = math.max(6, math.min(24, bd * 0.4))
		for _ = 1, 6 do
			local g = VecAdd(c, Vec((math.random() - 0.5) * 2 * spread, (math.random() - 0.5) * 4, (math.random() - 0.5) * 2 * spread))
			if wormGoalOk(g) then return g end
		end
	end
	for _ = 1, 8 do
		local g = VecAdd(w.pos, Vec((math.random() - 0.5) * 30, (math.random() - 0.5) * 8, (math.random() - 0.5) * 30))
		if wormGoalOk(g) then return g end
	end
	return VecCopy(w.lair)
end

-- the current goal per state
function wormGoal(w)
	if w.state == "lurk" then
		if not w.goal or now() > w.wanderT or dist(w.goal, w.pos) < 1.5 then
			w.goal = wormWanderGoal(w)
			w.wanderT = now() + 8 + math.random() * 22
		end
		return w.goal
	elseif w.state == "stalk" or w.state == "chase" then
		return w.known or w.pos
	elseif w.state == "drag" or w.state == "flee" then
		return w.lair
	end
	return w.pos
end

-- plan to the goal (Nav), straight when clear
function wormSteerTarget(w, goal)
	w.legR = HEAD_R
	if wormClear(w.pos, goal, HEAD_R) and dist(goal, w.pos) < 40 then
		w.path = nil
		return goal
	end
	local replan = not w.planGoal or dist(w.planGoal, goal) > math.max(3, 0.15 * dist(goal, w.pos)) or now() - w.planT > 4
	if replan and now() >= (w.planHold or 0) then
		Nav.request(w.id, w.pos, goal)                                  -- (it bites through whatever is in its way)
		w.planGoal = VecCopy(goal)
		w.planT = now()
		w.planning = true
	end
	if w.planning then
		local r = Nav.result(w.id)
		if r then
			w.planning = false
			w.planInfo = (r.source or "?") .. (r.ok and "" or "-x") .. (r.partial and "-part" or "") .. (r.dig and "-dig" or "")
			w.path = r.points
			w.pathI = 1
			w.digs = {}                                          -- (leg i: points[i] -> points[i + 1])
			for _, i in ipairs(r.digs or {}) do w.digs[i] = true end
			w.tight = r.tight or {}
			local useful = false
			for _, p in ipairs(r.points or {}) do if dist(p, w.pos) > 0.9 then useful = true end end
			if not useful then                                  -- (nowhere to go from here: no plan loop)
				w.path = nil
				w.planHold = now() + 2.5
				if w.state == "lurk" then w.goal = nil else w.direct = now() + 2.5 end
			end
		end
	end
	if w.path then
		while w.pathI <= #w.path and dist(w.path[w.pathI], w.pos) < 0.6 do w.pathI = w.pathI + 1 end
		local wp = w.path[w.pathI]
		if wp then
			local leg = w.pathI - 1
			w.legR = (w.tight and w.tight[leg]) and TIGHT_R or HEAD_R
			if w.digs[leg] and not wormClear(w.pos, wp, w.legR) then wormBite(w, VecNormalize(VecSub(wp, w.pos))) end
			return wp
		end
		w.path = nil                                             -- (the plan ran out short of the goal: plan again)
		w.planGoal = nil
	end
	-- no plan (yet): hunting, straight at it (blocked, the stuck check bites through); otherwise creep toward it
	if now() < (w.direct or 0) or w.state ~= "lurk" then return goal end
	w.creep = true
	return goal
end

function wormTempo(w)
	local tab = TEMPO[(w.state == "lurk" and (w.far or 0) > ROAM_D) and "stalk" or w.state]
	if not tab then return 1 end
	if now() >= w.tempoUntil then
		local e = pick(tab)
		w.tempo = e[2]
		w.tempoUntil = now() + e[3] + math.random() * (e[4] - e[3])
	end
	return w.tempo
end

-- metres to the nearest living player
function wormNearest(w)
	local best = 1e9
	for _, p in ipairs(GetAllPlayers()) do
		if GetPlayerHealth(p) > 0 then best = math.min(best, dist(wormChest(p), w.pos)) end
	end
	return best
end

function wormMove(w, dt)
	local goal = wormGoal(w)
	w.creep = false
	local aim = wormSteerTarget(w, goal)
	local base = SPEED[w.state] or 0
	if w.state == "lurk" and (w.far or 0) > ROAM_D then base = SPEED.roam end    -- (far from everyone: it travels)
	if IsPointInWater(w.pos) then base = base * WATER_SLOW end
	if w.creep then base = base * 0.4 end
	local want = aim and base * wormTempo(w) or 0
	local tw = TWITCH[w.state] or 0
	if now() > w.twitchUntil and math.random() < tw * dt then
		local side = VecNormalize(VecCross(w.fwd, Vec(0, 1, 0)))
		if vlen(side) < 0.5 then side = Vec(1, 0, 0) end
		w.twitchDir = VecNormalize(VecAdd(w.fwd, VecScale(side, (math.random() < 0.5 and -1 or 1) * (0.5 + math.random() * 0.6))))
		w.twitchUntil = now() + 0.08 + math.random() * 0.2
		if math.random() < 0.3 then wormRecoil(w, 0.3 + math.random() * 0.9) end
	end
	local k = want > w.speed and 10 or 14                         -- (snappy starts, dead stops)
	w.speed = w.speed + (want - w.speed) * math.min(1, k * dt)
	local dir = w.fwd
	if aim then
		local to = VecSub(aim, w.pos)
		if vlen(to) > 0.05 then
			local d = VecNormalize(to)
			local rate = (w.tempo or 1) > 1.5 and 9 or 4.5
			dir = VecNormalize(VecLerp(w.fwd, d, math.min(1, rate * dt)))
		end
	end
	if now() < w.twitchUntil and w.twitchDir then dir = VecNormalize(VecLerp(dir, w.twitchDir, 0.6)) end
	local step = w.speed * dt
	if step < 0.0005 then
		w.vel = Vec(0, 0, 0)
		return
	end
	-- the step, or else a slide: level, then up, then down (along floors, over sills, under lintels)
	local moved = false
	local tries = {dir}
	local flat = Vec(dir[1], 0, dir[3])
	if vlen(flat) > 0.2 then
		flat = VecNormalize(flat)
		tries[2] = flat
		tries[3] = VecNormalize(VecAdd(flat, Vec(0, 0.8, 0)))
		tries[4] = VecNormalize(VecAdd(flat, Vec(0, -0.8, 0)))
	else
		tries[2] = VecNormalize(VecAdd(dir, Vec(0.7, 0, 0)))
	end
	-- (a cast that starts touching something hits it: when the head is closer than its radius to a surface, cast with
	-- the clearance it has, so it can always back out)
	local r = w.legR or HEAD_R
	wormFilter()
	local hit, cp = QueryClosestPoint(w.pos, r)
	local touch = nil                                             -- (the clearance it has, when below its radius)
	if hit then
		touch = dist(cp, w.pos)
		r = math.max(0.01, touch - 0.02)
		local away = VecNormalize(VecSub(w.pos, cp))
		if vlen(away) > 0.5 then table.insert(tries, 2, VecNormalize(VecAdd(dir, VecScale(away, 1.2)))) end
	end
	for k, d0 in ipairs(tries) do
		local s = k == 1 and step or step * 0.7
		local nxt = VecAdd(w.pos, VecScale(d0, s))
		local ok = wormClear(w.pos, nxt, r)
		if ok then
			w.vel = VecScale(d0, s / dt)
			w.pos = nxt
			w.fwd = VecNormalize(VecLerp(w.fwd, d0, k == 1 and 1 or 0.5))
			wormRecord(w)
			moved = true
			break
		end
	end
	w.touch = touch
	w.blocked = not moved
	if not moved then
		w.vel = Vec(0, 0, 0)
		w.speed = w.speed * 0.3
	end
	-- stuck: no headway toward the aim for a while -> bite through when hunting (down only through a floor with space
	-- under it, never into the ground); a lurking worm just picks somewhere else
	local d = aim and dist(aim, w.pos) or 0
	if aim and d < w.stuckD - 0.3 then
		w.stuckD = d
		w.stuckT = now()
	elseif aim and want > 0.5 and now() - w.stuckT > STUCK_T then
		local bd = VecNormalize(VecSub(aim, w.pos))
		if w.state ~= "lurk" and (bd[2] > -0.6 or wormFloorBelow(w.pos)) then wormBite(w, bd) else w.goal = nil end
		w.stuckT = now()
		w.stuckD = 1e9
		w.planGoal = nil
	end
	if aim and d > w.stuckD + 2 then w.stuckD = d end
end

function wormUpdate(w, dt)
	if not w.alive then return end
	w.mouth = math.max(0, w.mouth - dt * 1.6)
	if w.state == "windup" then
		w.mouth = math.min(1, 0.2 + (now() - w.stateT) / WINDUP_T)
		w.speed = 0
		if w.target ~= 0 and IsPlayerValid(w.target) then
			w.fwd = VecNormalize(VecLerp(w.fwd, VecNormalize(VecSub(wormChest(w.target), w.pos)), math.min(1, 10 * dt)))
		end
		if now() - w.stateT > WINDUP_T then
			wormSetState(w, "lunge")
			w.ev.lunge = w.ev.lunge + 1
		end
		return
	elseif w.state == "lunge" then
		w.mouth = 1
		local tgt = (w.target ~= 0 and IsPlayerValid(w.target)) and wormChest(w.target) or VecAdd(w.pos, w.fwd)
		local d = VecNormalize(VecSub(tgt, w.pos))
		w.fwd = VecNormalize(VecLerp(w.fwd, d, math.min(1, 6 * dt)))
		local nxt = VecAdd(w.pos, VecScale(w.fwd, LUNGE_SPEED * dt))
		if wormClear(w.pos, nxt, HEAD_R * 0.8) then
			w.pos = nxt
			wormRecord(w)
		else
			wormBite(w, w.fwd)                                      -- (it strikes through cover)
		end
		if w.target ~= 0 and IsPlayerValid(w.target) and GetPlayerHealth(w.target) > 0 and not wormGrabbed[w.target]
			and dist(wormJaw(w), tgt) < GRAB_R then
			if GetPlayerVehicle(w.target) ~= 0 then
				wormBite(w, w.fwd)
				wormSetState(w, "chase")
			else
				wormGrab(w, w.target)
			end
		elseif now() - w.stateT > LUNGE_T then
			w.ev.bite = w.ev.bite + 1                               -- (the jaws snap shut on nothing)
			w.lungeCd = now() + LUNGE_CD
			wormSetState(w, "chase")
			wormRecoil(w, 1.5 + math.random() * 1.5)
		end
		return
	elseif w.state == "drag" then
		local p = w.grab
		if p == 0 or not IsPlayerValid(p) or GetPlayerHealth(p) <= 0 then
			wormRelease(w)
			wormSetState(w, "lurk")
		else
			SetPlayerHealth(math.max(0, GetPlayerHealth(p) - DRAG_HURT * dt), p)
			if w.dmgInDrag >= RELEASE_DMG then            -- (the only way out: hurting it; no struggling free)
				wormRelease(w)
				wormSetState(w, "flee")
			elseif dist(w.pos, w.lair) < 2.5 or now() - w.grabT > DRAG_MAX then
				SetPlayerHealth(0, p)
				w.ev.bite = w.ev.bite + 1
				wormRelease(w)
				wormSetState(w, "lurk")
				w.tempoUntil = now() + 6                            -- (it feeds: a long stillness)
				w.tempo = 0
			end
		end
	elseif w.state == "flee" then
		if dist(w.pos, w.lair) < 3 then wormSetState(w, "lurk") end
	elseif w.state == "lurk" then
		w.hp = math.min(HP, w.hp + 1.5 * dt)
	end
	if w.state == "chase" and w.target ~= 0 and IsPlayerValid(w.target) and now() > w.lungeCd and w.seeing then
		local c = wormChest(w.target)
		if dist(c, w.pos) < LUNGE_RANGE and wormClear(w.pos, c, 0.1) then
			wormSetState(w, "windup")
			return
		end
	end
	wormMove(w, dt)
end

-- the victim is held in the jaws (after physics, over Dive's swimming and the player's own moves)
function wormHold(w)
	local p = w.grab
	if p == 0 or not IsPlayerValid(p) then return end
	local jaw = wormJaw(w)
	local t = GetPlayerTransform(p)
	local feet = VecSub(jaw, Vec(0, 1.1, 0))
	SetPlayerTransform(Transform(feet, t.rot), p)
	SetPlayerVelocity(w.vel, p)
end

----- publishing -----

function wormPublish()
	wormSeq = wormSeq + 1
	local out = {n = wormSeq}
	for i, w in ipairs(wormList) do
		local glow = 0.3
		if w.state == "stalk" then glow = 0.6 elseif w.state == "chase" or w.state == "drag" then glow = 0.9
		elseif w.state == "windup" or w.state == "lunge" then glow = 1 elseif w.state == "flee" then glow = 0.45
		elseif w.state == "dead" then glow = 0 end
		out[i] = {id = w.id, alive = w.alive, state = w.state, trail = wormSample(w, TRAIL_PUB, BODY_LEN + 1),
			len = math.min(w.trailLen + dist(w.pos, w.trail[#w.trail]), BODY_LEN), mouth = w.mouth, glow = glow,
			hurt = w.hurtT, grab = w.grab, t = now(), speed = w.speed, deadT = w.deadT,
			bite = w.ev.bite, lunge = w.ev.lunge, hiss = w.ev.hiss, grabs = w.ev.grab, hurts = w.ev.hurt,
			die = w.ev.die, fx = w.fwd[1], fy = w.fwd[2], fz = w.fwd[3], esc = w.dmgInDrag / RELEASE_DMG,
			hits = w.hits or {}}
	end
	shared.worms = out
end

----- callbacks -----

function Worm.serverInit()
	wormList = {}
	wormHitShapes = {}
	wormGrabbed = {}
	wormNextId = 1
	wormSeq = 0
	wormPubT = 0
	wormSenseT = 0
	wormMaskT = 0
	wormLearnT = 0
	wormSpawnSearch = nil
	wormRespawnAt = {}
	wormHitpointsLast = nil
	SetString("abyssipede.hitpoints", "")
	SetString("abyssipede.damage", "")
	local c = GetInt("savegame.mod.count")
	if c < 1 then c = 1 end
	WORM_COUNT = math.min(3, c)
	if WORM_PARTS then
		local L = WORM_PARTS.head.len or 1
		for _, s in ipairs(WORM_PARTS.segments) do L = L + s.len end
		BODY_LEN = L + ((WORM_PARTS.tail and WORM_PARTS.tail.len) or 0)
	end
	for _, b in ipairs(FindBodies("abyssipedehit", true) or {}) do Delete(b) end
	Nav.init({cell = 0.5, radius = 0.3, budget = 300, maxNodes = 6000, mask = WORM_QUERY_MASK})
	for i = 1, WORM_COUNT do wormRespawnAt[#wormRespawnAt + 1] = SPAWN_DELAY + (i - 1) * 6 end
	shared.worms = {n = 0}
end

-- look for a lair over a few frames: 24 candidates per frame, the best after 2 s
function wormSpawnTick()
	local t = now()
	if not wormSpawnSearch then
		local due = false
		for _, at in ipairs(wormRespawnAt) do if t >= at then due = true end end
		if not due or #GetAllPlayers() == 0 then return end
		local lo, hi = wormMapBounds()
		local diag = dist(lo, hi)
		wormSpawnSearch = {lo = lo, hi = hi, minD = math.min(60, 0.3 * diag), best = nil, score = -1, untilT = t + 2}
	end
	local s = wormSpawnSearch
	for _ = 1, 24 do
		local p, sc = wormCandidate(s.lo, s.hi, s.minD)
		if p and sc > s.score then s.best, s.score = p, sc end
	end
	if t >= s.untilT then
		if s.best then
			table.remove(wormRespawnAt, 1)
			wormList[#wormList + 1] = wormNew(s.best)
			wormSpawnSearch = nil
		else
			s.minD = s.minD * 0.7                                  -- (a small map: closer)
			s.untilT = t + 2
		end
	end
end

-- spawn-menu worms: the marker prefab (prefab/spawner.xml) becomes a worm where it was put
function wormSpawnMenu()
	for _, b in ipairs(FindBodies("abyssipedespawn", true) or {}) do
		local p = VecAdd(GetBodyTransform(b).pos, Vec(0, 1.0, 0))
		Delete(b)
		local alive = 0
		for _, w in ipairs(wormList) do if w.alive then alive = alive + 1 end end
		if alive < WORM_MAX then wormList[#wormList + 1] = wormNew(p) end
	end
end

function Worm.serverTick(dt)
	local t = now()
	Nav.tick()
	wormSpawnTick()
	if math.floor(t * 2) ~= math.floor((t - dt) * 2) then wormSpawnMenu() end
	wormTakeHits()
	wormTakeApiDamage()
	-- GetLastSound is the loudest sound of the last frame only: listen every frame, keep the loudest until the senses
	local sv, sp = GetLastSound()
	if sv and sv > 0.04 and sp and (not wormHeard or sv > wormHeard.vol) then wormHeard = {vol = sv, pos = VecCopy(sp)} end
	local sense = t - wormSenseT > 1 / SENSE_HZ
	if sense then wormSenseT = t end
	for i = #wormList, 1, -1 do
		local w = wormList[i]
		if w.alive then
			if sense then
				wormSense(w)
				w.far = wormNearest(w)
			end
			wormBoxesMove(w)
		elseif t - w.deadT > CORPSE_T then
			table.remove(wormList, i)
			wormRespawnAt[#wormRespawnAt + 1] = t + RESPAWN_T
		end
	end
	if sense then wormHeard = nil end
	wormPublishHitpoints()
	if t - wormMaskT > 0.25 then                                   -- players pass through the worms' layer
		wormMaskT = t
		for _, p in ipairs(GetAllPlayers()) do
			local m = GetPlayerParam("CollisionMask", p)
			if type(m) == "number" and math.floor(m / WORM_LAYER) % 2 == 1 then SetPlayerParam("CollisionMask", m - WORM_LAYER, p) end
		end
	end
	if t - wormLearnT > 0.5 then                                   -- where a player has been, the worm can go
		wormLearnT = t
		for _, p in ipairs(GetAllPlayers()) do
			if GetPlayerHealth(p) > 0 and GetPlayerVehicle(p) == 0 then Nav.markFree(wormChest(p)) end
		end
	end
	if t - wormPubT >= 1 / PUBLISH_HZ then
		wormPubT = t
		wormPublish()
	end
end

function Worm.serverUpdate(dt)
	for _, w in ipairs(wormList) do wormUpdate(w, dt) end
end

function Worm.serverPostUpdate()
	for _, w in ipairs(wormList) do
		if w.alive and w.grab ~= 0 then wormHold(w) end
	end
end
