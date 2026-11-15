-- WormView: what each machine draws and hears of the worms (PROJECT.md: Interfaces). Every client spawns its own
-- body parts (static bodies in WORM_LAYER, colliding with nothing) and poses them along the trail the server
-- publishes in shared.worms, 1/PUBLISH_HZ s in the past so it can blend between two updates. On top, per machine:
-- the life in it (a writhe along the body and twitches and ripples, stronger when it stands still, the legs'
-- walking wave or scrabbling, antennae probing and flicking, the head looking round in jerks, the claws flicking),
-- an erratic tremor (worse when it hunts), the glow pulses travelling along its patterns (SetShapeEmissiveScale per
-- part plus a few point lights), the death throes, and the sounds.

WormView = {}

VIEW_PARK = Vec(0, -1000, 0)
WV_ZERO = {0, 0, 0}             -- (read only)
SOUND_KINDS = {"chitter", "click", "hiss", "shriek", "snap", "slither", "growl", "grab", "hurt", "death", "idle"}

local function dist(a, b) return VecLength(VecSub(a, b)) end

function wvLoadSounds()
	wvSnd = {}
	local S = WORM_SOUNDS or {}
	for _, k in ipairs(SOUND_KINDS) do
		wvSnd[k] = {}
		for _, f in ipairs(S[k] or {}) do
			if k == "slither" or k == "idle" then wvSnd[k][#wvSnd[k] + 1] = LoadLoop(f) else wvSnd[k][#wvSnd[k] + 1] = LoadSound(f) end
		end
	end
end

function wvPlay(kind, pos, vol)
	local l = wvSnd[kind]
	if not l or #l == 0 then return end
	PlaySound(l[math.random(#l)], pos, vol or 1, false, 0.88 + math.random() * 0.24)
end

-- a limb model placed with its pivot on hinge (both in the part's local metres): the <vox> element and, once
-- spawned, the record that turns it about the hinge (wvLimb)
local function limbXml(d, hinge, tag)
	return string.format("<vox tags='nocull %s' file='%s' pos='%.3f %.3f %.3f'/>", tag, d.file,
		hinge[1] - d.pivot[1], hinge[2] - d.pivot[2], hinge[3] - d.pivot[3])
end

local function limbsOf(body, defs)
	local out = {}
	for _, s in ipairs(GetBodyShapes(body)) do
		for _, d in ipairs(defs) do
			if HasTag(s, d.tag) then
				out[#out + 1] = {shape = s, rest = GetShapeLocalTransform(s), hinge = Vec(d.hinge[1], d.hinge[2], d.hinge[3]),
					sign = d.sign, k = d.k, tw = 0, twA = 0, twB = 0}
			end
		end
	end
	return out
end

-- turn a limb about its hinge by R (rotations in its part's frame)
function wvLimb(l, R)
	SetShapeLocalTransform(l.shape, Transform(VecAdd(l.hinge, QuatRotateVec(R, VecSub(l.rest.pos, l.hinge))),
		QuatRotateQuat(R, l.rest.rot)))
end

-- the parts of one worm: {head = body, jaws, ants = {limb}, segs = {{body, shapes, arc, len, legs = {limb}}}}
function wvSpawn()
	local P = WORM_PARTS
	local v = {segs = {}, jaws = {}, ants = {}, phase = math.random() * 100, flick = {}, travel = 0, idlePh = 0,
		still = 0, tw = {}, look = {y = 0, p = 0, ty = 0, tp = 0, next = 0}}
	local function spawnBody(xml)
		local ents = Spawn(xml, Transform(VIEW_PARK), true)
		for _, e in ipairs(ents or {}) do
			if GetEntityType(e) == "body" then
				for _, s in ipairs(GetBodyShapes(e)) do SetShapeCollisionFilter(s, WORM_LAYER, 0) end
				return e
			end
		end
		return 0
	end
	if P then
		local h = P.head
		local xml = "<body tags='abyssipedeview nocull'><vox tags='nocull bobhead' file='" .. h.file .. "'/>"
		local jawDefs, antDefs = {}, {}
		for _, side in ipairs({"l", "r"}) do
			local sign = side == "l" and 1 or -1
			local j, hinge = P["jaw_" .. side], h["hinge_" .. side]
			if j and hinge then
				xml = xml .. limbXml(j, hinge, "bobjaw" .. side)
				jawDefs[#jawDefs + 1] = {tag = "bobjaw" .. side, hinge = hinge, sign = sign}
			end
			local a, sock = P["antenna_" .. side], h["ant_" .. side]
			if a and sock then
				xml = xml .. limbXml(a, sock, "bobant" .. side)
				antDefs[#antDefs + 1] = {tag = "bobant" .. side, hinge = sock, sign = sign}
			end
		end
		v.head = spawnBody(xml .. "</body>")
		v.headLen = h.len or 1
		v.jaws = limbsOf(v.head, jawDefs)
		v.ants = limbsOf(v.head, antDefs)
		local arc = v.headLen / 2
		local list = {}
		for _, s in ipairs(P.segments) do list[#list + 1] = s end
		if P.tail then list[#list + 1] = P.tail end
		local pair = 0
		for i, s in ipairs(list) do
			arc = arc + s.len / 2
			local xml = "<body tags='abyssipedeview nocull'><vox tags='nocull' file='" .. s.file .. "'/>"
			local defs = {}
			local L, R = nil, nil
			if s.leg and P.legs and P.legs[s.leg] then L, R = P.legs[s.leg].l, P.legs[s.leg].r end
			if s.ult_l then L, R = s.ult_l, s.ult_r end
			if L and s.hip then
				pair = pair + 1
				local hl, hr = s.hip, {-s.hip[1], s.hip[2], s.hip[3]}
				xml = xml .. limbXml(L, hl, "boblegl") .. limbXml(R, hr, "boblegr")
				defs = {{tag = "boblegl", hinge = hl, sign = 1, k = pair}, {tag = "boblegr", hinge = hr, sign = -1, k = pair}}
			end
			local b = spawnBody(xml .. "</body>")
			v.segs[i] = {body = b, shapes = GetBodyShapes(b), arc = arc, len = s.len, r = s.radius or 0.25,
				legs = limbsOf(b, defs), ult = s.ult_l ~= nil}
			arc = arc + s.len / 2
		end
	else                                                         -- (no model: plain boxes, for tests)
		v.head = spawnBody("<body tags='abyssipedeview'><voxbox size='6 6 10' pos='-0.3 -0.3 -0.5' color='0.1 0.05 0.12'/></body>")
		v.headLen = 1
		local arc = 0.5
		for i = 1, 40 do
			arc = arc + 0.19
			local b = spawnBody("<body tags='abyssipedeview'><voxbox size='5 5 4' pos='-0.25 -0.25 -0.2' color='0.1 0.05 0.12'/></body>")
			v.segs[i] = {body = b, shapes = GetBodyShapes(b), arc = arc, len = 0.38, r = 0.25}
			arc = arc + 0.19
		end
	end
	for i = 1, #v.segs do v.flick[i] = {phase = math.random() * 6.28, off = 0} end
	return v
end

function wvDelete(v)
	if v.head and v.head ~= 0 then Delete(v.head) end
	for _, s in ipairs(v.segs) do if s.body ~= 0 then Delete(s.body) end end
end

-- position and forward (toward the head) at arc length s along a flat trail list
function wvAt(tr, s)
	local n = #tr / 3
	if n < 2 then
		local p = Vec(tr[1] or 0, tr[2] or 0, tr[3] or 0)
		return p, Vec(0, 0, 1)
	end
	local acc = 0
	for k = 1, n - 1 do
		local a = Vec(tr[3 * k - 2], tr[3 * k - 1], tr[3 * k])
		local b = Vec(tr[3 * k + 1], tr[3 * k + 2], tr[3 * k + 3])
		local l = dist(a, b)
		if acc + l >= s or k == n - 1 then
			local f = l > 0.0001 and math.min(1, math.max(0, (s - acc) / l)) or 0
			local fw = l > 0.0001 and VecScale(VecSub(a, b), 1 / l) or Vec(0, 0, 1)
			return VecLerp(a, b, f), fw
		end
		acc = acc + l
	end
end

-- a rotation whose local +z is fwd (the models' front), rolled by `roll` radians about it
function wvRot(fwd, roll)
	local fx, fy, fz = fwd[1], fwd[2], fwd[3]
	local x1, x2, x3                                             -- x = normalize(up x fwd), y = fwd x x
	if math.abs(fy) > 0.97 then x1, x2, x3 = 0, -fz, fy else x1, x2, x3 = fz, 0, -fx end
	local l = math.sqrt(x1 * x1 + x2 * x2 + x3 * x3)
	if l < 1e-9 then l = 1 end
	x1, x2, x3 = x1 / l, x2 / l, x3 / l
	local y1, y2, y3 = fy * x3 - fz * x2, fz * x1 - fx * x3, fx * x2 - fy * x1
	local c, s = math.cos(roll), math.sin(roll)
	return QuatAlignXZ({x1 * c + y1 * s, x2 * c + y2 * s, x3 * c + y3 * s}, fwd)
end

-- The trail walked once per frame for every body part (wvAt started at the head again for each of the 42 parts
-- and made vectors at every step: the biggest share of the pose's cost, measured in-game 2026-11-11): wvWalk
-- measures the trail's legs once, wvAtW keeps its place between calls (the parts come in rising arc length; a
-- smaller s starts over). Position and forward (toward the head) at arc length s, as wvAt gives them.
function wvWalk(tr)
	local n = math.floor(#tr / 3)
	local L = {}
	for k = 1, n - 1 do
		local i = 3 * k
		local dx, dy, dz = tr[i - 2] - tr[i + 1], tr[i - 1] - tr[i + 2], tr[i] - tr[i + 3]
		L[k] = math.sqrt(dx * dx + dy * dy + dz * dz)
	end
	return {tr = tr, n = n, L = L, k = 1, acc = 0}
end

function wvAtW(wk, s)
	local tr, n, L = wk.tr, wk.n, wk.L
	if n < 2 then return {tr[1] or 0, tr[2] or 0, tr[3] or 0}, {0, 0, 1} end
	if s < wk.acc then wk.k, wk.acc = 1, 0 end
	local k, acc = wk.k, wk.acc
	while k < n - 1 and acc + L[k] < s do
		acc = acc + L[k]
		k = k + 1
	end
	wk.k, wk.acc = k, acc
	local l = L[k]
	local i = 3 * k
	local ax, ay, az, bx, by, bz = tr[i - 2], tr[i - 1], tr[i], tr[i + 1], tr[i + 2], tr[i + 3]
	if l <= 0.0001 then return {ax, ay, az}, {0, 0, 1} end
	local f = (s - acc) / l
	if f < 0 then f = 0 elseif f > 1 then f = 1 end
	return {ax + (bx - ax) * f, ay + (by - ay) * f, az + (bz - az) * f}, {(ax - bx) / l, (ay - by) / l, (az - bz) / l}
end

-- wvAtW without tables: x, y, z, fx, fy, fz
function wvAtN(wk, s)
	local tr, n, L = wk.tr, wk.n, wk.L
	if n < 2 then return tr[1] or 0, tr[2] or 0, tr[3] or 0, 0, 0, 1 end
	if s < wk.acc then wk.k, wk.acc = 1, 0 end
	local k, acc = wk.k, wk.acc
	while k < n - 1 and acc + L[k] < s do
		acc = acc + L[k]
		k = k + 1
	end
	wk.k, wk.acc = k, acc
	local l = L[k]
	local i = 3 * k
	local ax, ay, az, bx, by, bz = tr[i - 2], tr[i - 1], tr[i], tr[i + 1], tr[i + 2], tr[i + 3]
	if l <= 0.0001 then return ax, ay, az, 0, 0, 1 end
	local f = (s - acc) / l
	if f < 0 then f = 0 elseif f > 1 then f = 1 end
	return ax + (bx - ax) * f, ay + (by - ay) * f, az + (bz - az) * f, (ax - bx) / l, (ay - by) / l, (az - bz) / l
end

-- blend two published trails (same order: head first)
function wvBlend(a, b, f)
	if not a then return b end
	local out = {}
	for i = 1, #b do
		local x = a[i]
		out[i] = x and (x + (b[i] - x) * f) or b[i]
	end
	return out
end

function WormView.clientInit()
	wvViews = {}
	wvLastN = -1
	wvW, wvTook, wvFrame, wvCam = false, false, 0, Vec(0, 0, 0)
	wvSnaps = {}
	wvLoadSounds()
end

function wvTake()
	wvTook = false
	if shared.wormsN == wvLastN then return end                  -- (a number: reading shared.worms copies all of it)
	local W = shared.worms   -- (the one read of the table, when it changed)
	if not W or W.n == wvLastN then return end
	wvLastN = W.n
	wvW, wvTook = W, true
	local t = GetTime()
	for i = 1, #W do
		local w = W[i]
		local s = wvSnaps[w.id] or {}
		s.prev = s.cur
		s.prevT = s.curT
		local c = {}
		for k, x in pairs(w) do c[k] = x end                       -- (copy: shared hands out copies, keep ours)
		s.cur = c
		s.curT = t
		s.seen = t
		wvSnaps[w.id] = s
	end
end

function wvSounds(v, w, s, head, dt)
	local t = GetTime()
	local prev = v.ev or {}
	local function fired(k) return (w[k] or 0) > (prev[k] or 0) end
	if v.ev then
		if fired("bite") then
			wvPlay("snap", head, 1)
			local d = dist(GetCameraTransform().pos, head)
			if d < 12 then ShakeCamera(0.5 * (1 - d / 12)) end
		end
		if fired("lunge") then wvPlay("shriek", head, 1) end
		if fired("hiss") then wvPlay("hiss", head, 0.9) end
		if fired("grabs") then wvPlay("grab", head, 1) end
		if fired("hurts") and t - (v.hurtSndT or 0) > 0.3 then v.hurtSndT = t; wvPlay("hurt", head, 0.9) end
		if fired("die") then wvPlay("death", head, 1) end
	end
	v.ev = {bite = w.bite, lunge = w.lunge, hiss = w.hiss, grabs = w.grabs, hurts = w.hurts, die = w.die}
	if not w.alive then return end
	local loop = wvSnd.slither and wvSnd.slither[1]
	if loop then PlayLoop(loop, head, math.min(1, 0.15 + (w.speed or 0) / 8), false) end
	local idle = wvSnd.idle and wvSnd.idle[1]
	if idle then PlayLoop(idle, head, 0.5, false) end
	if t > (v.nextVoice or 0) then
		local st = w.state
		local gap = st == "lurk" and 4 + math.random() * 8 or (st == "stalk" and 2 + math.random() * 3 or 1 + math.random() * 2)
		v.nextVoice = t + gap
		local r = math.random()
		if st == "lurk" and r < 0.12 then wvPlay("growl", head, 1)
		elseif r < 0.55 then wvPlay("chitter", head, st == "lurk" and 0.6 or 0.85)
		else wvPlay("click", head, st == "lurk" and 0.55 or 0.8) end
	end
end

-- a puff of its green ichor where it was hit (bigger for a bigger hit): a faintly glowing cloud that swells and
-- hangs in the water, and a spray of droplets
local function rnd() return Vec(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5) end

function wvIchor(pos, dmg)
	local k = math.min(1, 0.3 + dmg / 30)
	ParticleReset()
	ParticleType("smoke")
	ParticleColor(0.2, 0.6, 0.12, 0.04, 0.14, 0.03)
	ParticleRadius(0.12 + 0.15 * k, 0.4 + 0.5 * k, "easeout")
	ParticleAlpha(0.9, 0, "easein")
	ParticleEmissive(0.5, 0, "easeout")
	ParticleGravity(-0.1)
	ParticleDrag(0.7)
	ParticleCollide(0)
	for _ = 1, math.floor(4 + 8 * k) do
		SpawnParticle(VecAdd(pos, VecScale(rnd(), 0.3)), VecScale(rnd(), 1.5 + 2 * k), 2 + 2.5 * math.random())
	end
	ParticleReset()
	ParticleType("plain")
	ParticleColor(0.3, 0.9, 0.2, 0.05, 0.25, 0.04)
	ParticleRadius(0.035, 0.015)
	ParticleAlpha(1, 0)
	ParticleEmissive(1, 0)
	ParticleGravity(-2.5)
	ParticleDrag(0.4)
	for _ = 1, math.floor(6 + 14 * k) do
		SpawnParticle(pos, VecScale(rnd(), 4 + 6 * k), 0.5 + 0.7 * math.random())
	end
end

-- the hits since the last snapshot (the server keeps the last few: hits = {seq, x, y, z, damage, ...})
function wvHits(v, w)
	local h = w.hits
	if not h then v.hitSeq = v.hitSeq or 0; return end
	local last = v.hitSeq or -1
	for i = 1, #h, 5 do
		if h[i] > last then
			if v.hitSeq then wvIchor(Vec(h[i + 1], h[i + 2], h[i + 3]), h[i + 4]) end   -- (none for hits from before we came)
			last = math.max(last, h[i])
		end
	end
	v.hitSeq = math.max(last, v.hitSeq or 0)
end

-- a burst of life somewhere along the body: a jerk sideways or up that snaps out and eases back, or (run > 0) a
-- bulge rippling toward the tail
function wvNewTwitch(v, len, still, agit)
	local tw = {c = 0.3 + math.random() * math.max(0.5, len - 0.3), wd = 0.6 + math.random() * 1.8,
		amp = (0.05 + math.random() * 0.1) * (0.6 + 0.6 * still + 0.4 * agit), a = math.random() * 6.283,
		t0 = GetTime(), dur = 0.15 + math.random() * 0.3, run = 0}
	if math.random() < 0.3 then
		tw.run = 4 + math.random() * 5
		tw.c = math.random() * 2
		tw.dur = math.max(0.5, len - tw.c) / tw.run
	end
	v.tw[#v.tw + 1] = tw
end

function wvTwitchAt(tw, s, t)
	local u = (t - tw.t0) / tw.dur
	if u < 0 or u > 1 then return 0 end
	local e = (s - tw.c - tw.run * (t - tw.t0)) / tw.wd
	if e > 3 or e < -3 then return 0 end
	local f
	if tw.run > 0 then f = math.sin(math.pi * u) elseif u < 0.2 then f = u / 0.2 else f = ((1 - u) / 0.8) ^ 2 end
	return tw.amp * f * math.exp(-e * e)
end

-- a ring's legs: a walking wave along the body driven by how far it has moved; when it stands still (stuck,
-- frozen, waiting) the legs keep scrabbling, faster when it hunts; single legs jerk on their own; the tail's long
-- ultimate legs sway; dead, they flail and then curl under
WV_LEG_STEPS = 64                                              -- steps of the baked walking cycle
WV_LEG_K = WV_LEG_STEPS / (2 * math.pi)
WV_JIT = {}                                                    -- baked jitter offsets (a ring picks one per pose)
for k = 1, 256 do
	local a = 6.28 * math.random()
	WV_JIT[k] = {math.cos(a) * math.random(), math.random() - 0.5, math.sin(a) * math.random()}
end

function wvLegs(v, s, t, dt, agit, still, dead, thrash, slump)
	for _, l in ipairs(s.legs) do
		local sg = l.sign
		local sweep, lift
		if s.ult then
			sweep = 8 * math.sin(t * 1.1 + sg) + 6 * math.sin(t * 2.7 + sg * 2) * (0.3 + agit)
			lift = 4 * math.sin(t * 0.8 + sg)
		else
			local ph = v.travel * 2.8 + v.idlePh - l.k * 0.7 + (sg < 0 and math.pi or 0)
			l.ph = ph
			if t < l.tw or dead then                                   -- (only the live path needs the angles)
				sweep = 22 * math.sin(ph)
				lift = 13 * math.max(0, math.cos(ph)) - 2
			end
		end
		local live = s.ult or dead
		if t < l.tw then
			sweep = sweep + l.twA; lift = lift + l.twB
			live = true
		elseif math.random() < dt * (0.15 + 1.2 * still + 0.6 * agit) then
			l.tw = t + 0.08 + math.random() * 0.22; l.twA = (math.random() - 0.5) * 50; l.twB = 10 + math.random() * 30
		end
		if dead then
			sweep = 35 * thrash * math.sin(t * 23 + l.k * 1.3 + sg)
			lift = -40 * slump + 25 * thrash * math.sin(t * 17 + l.k)
		end
		if live then
			-- (+sweep = forward: the left leg (+x) turns toward +z about -y; +lift = up)
			wvLimb(l, QuatRotateQuat(QuatEuler(0, -sg * sweep, 0), QuatEuler(0, 0, sg * lift)))
		else
			-- the walking cycle replayed: this leg's finished transform at each of WV_LEG_STEPS steps of the cycle,
			-- made the first time the step comes up (the maths and seven engine calls a leg, once instead of every pose)
			local idx = math.floor(l.ph * WV_LEG_K) % WV_LEG_STEPS
			local bk = l.bake
			if not bk then bk = {}; l.bake = bk end
			local T = bk[idx]
			if not T then
				local ph = (idx + 0.5) / WV_LEG_K
				local R = QuatRotateQuat(QuatEuler(0, -sg * 22 * math.sin(ph), 0), QuatEuler(0, 0, sg * (13 * math.max(0, math.cos(ph)) - 2)))
				T = Transform(VecAdd(l.hinge, QuatRotateVec(R, VecSub(l.rest.pos, l.hinge))), QuatRotateQuat(R, l.rest.rot))
				bk[idx] = T
			end
			SetShapeLocalTransform(l.shape, T)
		end
	end
end

-- side and up vectors of a part facing fwd (as wvRot builds them)
local function sideUp(f)
	local fx, fy, fz = f[1], f[2], f[3]
	local x1, x2, x3
	if math.abs(fy) > 0.97 then x1, x2, x3 = 0, -fz, fy else x1, x2, x3 = fz, 0, -fx end
	local l = math.sqrt(x1 * x1 + x2 * x2 + x3 * x3)
	if l < 1e-9 then l = 1 end
	x1, x2, x3 = x1 / l, x2 / l, x3 / l
	return {x1, x2, x3}, {fy * x3 - fz * x2, fz * x1 - fx * x3, fx * x2 - fy * x1}
end

function wvPose(v, w, tr, dt)
	local t = GetTime()
	v.poseN = (v.poseN or 0) + 1                                 -- (poses of this worm: far ones skip frames)
	local speed = w.speed or 0
	v.phase = v.phase + dt * (0.8 + speed * 0.6)
	local agit = (w.state == "chase" or w.state == "drag" or w.state == "windup" or w.state == "lunge") and 1 or
		(w.state == "stalk" and 0.5 or 0.15)
	local dead = not w.alive
	local dt0 = dead and (t - (v.diedT or t)) or 0
	if dead and not v.diedT then v.diedT = t end
	local thrash = dead and math.max(0, 1 - dt0 / 3.5) or 0
	local slump = dead and math.min(1, math.max(0, (dt0 - 2.5) / 4)) or 0
	local len = w.len or 0
	-- standing still (stuck, frozen, waiting) the body comes alive instead of freezing
	v.still = v.still + ((speed < 0.6 and 1 or 0) - v.still) * math.min(1, dt * 2.5)
	local still = dead and 0 or v.still
	v.travel = v.travel + speed * dt
	v.idlePh = v.idlePh + dt * (0.6 + 6 * agit) * still
	if not dead and t > (v.nextTw or 0) then
		v.nextTw = t + (0.15 + math.random() * 0.9) / (0.4 + still + 0.5 * agit)
		wvNewTwitch(v, len, still, agit)
	end
	for k = #v.tw, 1, -1 do if t > v.tw[k].t0 + v.tw[k].dur then table.remove(v.tw, k) end end
	-- the head
	local walk = wvWalk(tr)
	local hp, hf = wvAtW(walk, 0)
	if w.fx then hf = VecNormalize(Vec(w.fx, w.fy, w.fz)) end
	local camD = dist(wvCam, hp)
	local limbs = camD < 80                                    -- (limbs only move where someone could see them)
	local legEvery = camD < 25 and 1 or 2                      -- (farther off the legs turn every 2nd frame, ring by ring)
	local jit = 0.01 + 0.025 * agit
	local function shake(i)
		local a = 6.28 * math.random()
		return {math.cos(a) * jit * math.random(), (math.random() - 0.5) * jit, math.sin(a) * jit * math.random()}
	end
	local function fall(p, i)
		if slump <= 0 then return p end
		v.ground = v.ground or {}
		if not v.ground[i] then
			QueryCollisionMask(WORM_QUERY_MASK)
			local hit, d = QueryRaycast(p, Vec(0, -1, 0), 40)
			v.ground[i] = hit and (p[2] - d + 0.25) or (p[2] - 2)
		end
		return Vec(p[1], p[2] + (v.ground[i] - p[2]) * slump, p[3])
	end
	local thr = function(i)
		if thrash <= 0 then return WV_ZERO end
		local a = math.sin(t * 17 + i * 0.9) * thrash * 0.35
		return Vec(a * math.cos(i), math.sin(t * 13 + i) * thrash * 0.2, a * math.sin(i))
	end
	-- a slow sinuous writhe along the body (stronger when still) plus the twitches, at arc length s
	local undA = 0.03 + 0.07 * still + 0.02 * agit
	local undW = 1.4 + 2.2 * agit + 0.8 * still
	local function life(s, f)
		if dead then return WV_ZERO end
		local x, y = sideUp(f)
		local env = math.min(1, s / 1.2)
		local a = undA * env * math.sin(s * 2.1 - t * undW)
		local b = 0.4 * undA * env * math.sin(s * 1.3 + t * 1.1)
		for _, tw in ipairs(v.tw) do
			local m = wvTwitchAt(tw, s, t)
			if m ~= 0 then a, b = a + math.cos(tw.a) * m, b + math.sin(tw.a) * m end
		end
		return {x[1] * a + y[1] * b, x[2] * a + y[2] * b, x[3] * a + y[3] * b}
	end
	local headPos = fall(VecAdd(VecAdd(VecAdd(hp, shake(0)), thr(0)), life(0.25, hf)), 0)
	-- it looks around in jerks (more when still; not while it strikes)
	local L = v.look
	local aim = w.state == "windup" or w.state == "lunge" or w.state == "drag"
	if t > L.next or (aim and L.ty ~= 0) then
		local k = (dead or aim) and 0 or (0.25 + 0.75 * still)
		L.ty = (math.random() - 0.5) * 70 * k
		L.tp = (math.random() - 0.5) * 36 * k
		L.next = t + 0.2 + math.random() * (0.4 + 0.8 * (1 - agit))
	end
	local kk = math.min(1, dt * 16)
	L.y = L.y + (L.ty - L.y) * kk
	L.p = L.p + (L.tp - L.p) * kk
	local roll0 = math.sin(v.phase * 1.3) * 0.12 * agit + (math.random() - 0.5) * 0.05 * agit
	SetBodyTransform(v.head, Transform(headPos, QuatRotateQuat(wvRot(hf, roll0), QuatEuler(L.p, L.y, 0))))
	-- the venom claws: as the server says, plus small flicks of their own
	local open = math.max(0, math.min(1, w.mouth or 0))
	if w.state == "windup" then open = math.min(1, open + 0.15 * math.sin(t * 40)) end
	if not dead then
		if t > (v.jawNext or 0) then
			v.jawNext = t + 0.4 + math.random() * (2.5 - 1.8 * still)
			v.jawTw = t + 0.08 + math.random() * 0.15
			v.jawTwA = 0.15 + math.random() * 0.45
		end
		if t < (v.jawTw or 0) then open = math.max(open, v.jawTwA) end
	else
		open = 0.6 * thrash + 0.25
	end
	for _, j in ipairs(v.jaws) do wvLimb(j, QuatEuler(0, j.sign * open * 45, 0)) end
	-- the antennae: probing sweeps, sudden flicks, drooping when dead (+pitch = down)
	if limbs then
		for _, a in ipairs(v.ants) do
			local sg = a.sign
			local spd = 1 + 2 * agit + still
			local yaw = 6 + 16 * math.sin(t * 1.3 * spd + sg * 1.7) + 8 * math.sin(t * 3.1 * spd + sg)
			local pitch = -4 - 12 * math.sin(t * 0.9 * spd + sg * 2.3)
			if t < a.tw then
				yaw = yaw + a.twA; pitch = pitch + a.twB
			elseif math.random() < dt * (0.6 + 2.5 * still + 2 * agit) then
				a.tw = t + 0.08 + math.random() * 0.2; a.twA = (math.random() - 0.5) * 70; a.twB = (math.random() - 0.5) * 50
			end
			if dead then yaw = 10 + 25 * thrash * math.sin(t * 19 + sg); pitch = 15 + 30 * slump end
			wvLimb(a, QuatRotateQuat(QuatEuler(0, sg * yaw, 0), QuatEuler(pitch, 0, 0)))
		end
	end
	-- the body: positions first, then each ring faces along its neighbours (so writhes and twitches bend it)
	local glowBase = w.glow or 0.3
	if dead then glowBase = math.max(0, 0.8 - dt0 / 7) * (math.random() < 0.15 and 0.2 or 1) end
	local speedW = (w.state == "lurk") and 2.2 or (w.state == "stalk" and 4 or 7.5)
	local pos = {}
	local fw = v.fw
	if not fw then fw = {}; v.fw = fw end                        -- (each ring's forward along the trail, flat, kept)
	local strobe = w.state == "windup" or w.state == "lunge"
	-- what all rings share this pose: the writhe's two waves at this time, and the twitches under way
	-- (sin(a - b) = sin a cos b - cos a sin b: each ring keeps the sines of its own place, made once)
	local sU, cU = math.sin(t * undW), math.cos(t * undW)
	local sV, cV = math.sin(t * 1.1), math.cos(t * 1.1)
	local twC, twW, twA, twB = v.twC, v.twW, v.twA, v.twB
	if not twC then twC, twW, twA, twB = {}, {}, {}, {}; v.twC, v.twW, v.twA, v.twB = twC, twW, twA, twB end
	local nTw = 0
	if not dead then
		for _, tw in ipairs(v.tw) do
			local u = (t - tw.t0) / tw.dur
			if u >= 0 and u <= 1 then
				local f
				if tw.run > 0 then f = math.sin(math.pi * u) elseif u < 0.2 then f = u / 0.2 else f = ((1 - u) / 0.8) ^ 2 end
				local m = tw.amp * f
				nTw = nTw + 1
				twC[nTw], twW[nTw], twA[nTw], twB[nTw] = tw.c + tw.run * (t - tw.t0), tw.wd, math.cos(tw.a) * m, math.sin(tw.a) * m
			end
		end
	end
	local exp, abs, sqrt, random = math.exp, math.abs, math.sqrt, math.random
	for i, s in ipairs(v.segs) do
		local arc = s.arc
		if arc > len + 0.3 and not dead then
			if not s.parked then SetBodyTransform(s.body, Transform(VIEW_PARK)); s.parked = true end
		else
			s.parked = false
			local px, py, pz, fx, fy, fz = wvAtN(walk, arc)
			fw[3 * i - 2], fw[3 * i - 1], fw[3 * i] = fx, fy, fz
			local jv = WV_JIT[random(256)]
			px, py, pz = px + jv[1] * jit, py + jv[2] * jit, pz + jv[3] * jit
			if dead then
				if thrash > 0 then
					local th = thr(i)
					px, py, pz = px + th[1], py + th[2], pz + th[3]
				end
			else
				if not s.s21 then
					s.s21, s.c21, s.s13, s.c13 = math.sin(arc * 2.1), math.cos(arc * 2.1), math.sin(arc * 1.3), math.cos(arc * 1.3)
					s.env = math.min(1, arc / 1.2)
				end
				local a = undA * s.env * (s.s21 * cU - s.c21 * sU)
				local b = 0.4 * undA * s.env * (s.s13 * cV + s.c13 * sV)
				for j = 1, nTw do
					local e = (arc - twC[j]) / twW[j]
					if e < 3 and e > -3 then
						local g = exp(-e * e)
						a, b = a + twA[j] * g, b + twB[j] * g
					end
				end
				-- side (x) and up (y) of a part facing f, as sideUp gives them
				local x1, x2, x3
				if abs(fy) > 0.97 then x1, x2, x3 = 0, -fz, fy else x1, x2, x3 = fz, 0, -fx end
				local l = sqrt(x1 * x1 + x2 * x2 + x3 * x3)
				if l < 1e-9 then l = 1 end
				x1, x2, x3 = x1 / l, x2 / l, x3 / l
				px = px + x1 * a + (fy * x3 - fz * x2) * b
				py = py + x2 * a + (fz * x1 - fx * x3) * b
				pz = pz + x3 * a + (fx * x2 - fy * x1) * b
			end
			local p = {px, py, pz}
			if slump > 0 then p = fall(p, i) end
			pos[i] = p
		end
	end
	local sP, cP = math.sin(v.phase * 1.3), math.cos(v.phase * 1.3)
	local rollA = 0.06 + 0.14 * agit
	for i, s in ipairs(v.segs) do
		if pos[i] then
			local a = (i == 1) and headPos or pos[i - 1]
			local fx, fy, fz = fw[3 * i - 2], fw[3 * i - 1], fw[3 * i]
			if a and pos[i + 1] then
				local q = pos[i + 1]
				local dx, dy, dz = a[1] - q[1], a[2] - q[2], a[3] - q[3]
				local dl = sqrt(dx * dx + dy * dy + dz * dz)
				if dl > 0.05 then fx, fy, fz = dx / dl, dy / dl, dz / dl end
			end
			if not s.rs then s.rs, s.rc = math.sin(i * 0.35), math.cos(i * 0.35) end
			local roll = (sP * s.rc - cP * s.rs) * rollA + (random() - 0.5) * 0.04 * agit
			-- (wvRot, without a call or a table for the forward: x = normalize(up x fwd), y = fwd x x, rolled)
			local x1, x2, x3
			if abs(fy) > 0.97 then x1, x2, x3 = 0, -fz, fy else x1, x2, x3 = fz, 0, -fx end
			local xl = sqrt(x1 * x1 + x2 * x2 + x3 * x3)
			if xl < 1e-9 then xl = 1 end
			x1, x2, x3 = x1 / xl, x2 / xl, x3 / xl
			local y1, y2, y3 = fy * x3 - fz * x2, fz * x1 - fx * x3, fx * x2 - fy * x1
			local rc, rs = math.cos(roll), math.sin(roll)
			SetBodyTransform(s.body, Transform(pos[i], QuatAlignXZ({x1 * rc + y1 * rs, x2 * rc + y2 * rs, x3 * rc + y3 * rs}, {fx, fy, fz})))
			if limbs and s.legs and #s.legs > 0 and (legEvery == 1 or (v.poseN + i) % 2 == 0) then
				wvLegs(v, s, t, dt * legEvery, agit, still, dead, thrash, slump)
			end
			-- glow: a pulse running down the body, each part flickering on its own
			-- (every 3rd frame per ring, the rings taking turns; every frame while it strobes before a strike)
			if strobe or (wvFrame + i) % 3 == 0 then
				local fl = v.flick[i]
				if math.random() < 0.03 * (1 + 3 * agit) then fl.off = t + 0.05 + math.random() * 0.25 end
				local wave = math.max(0, math.sin(t * speedW - i * 0.45 + fl.phase * 0.15)) ^ 4
				local g = glowBase * (0.3 + 0.9 * wave)
				if w.state == "windup" or w.state == "lunge" then g = (math.floor(t * 18 + i * 0.5) % 2 == 0) and 1.6 or 0.2 end
				if t < fl.off then g = g * 0.05 end
				if WV_NOGLOW then g = 0 end
				for _, sh in ipairs(s.shapes) do SetShapeEmissiveScale(sh, g) end
			end
		end
	end
	if wvFrame % 3 == 0 then
		for _, sh in ipairs(GetBodyShapes(v.head)) do SetShapeEmissiveScale(sh, dead and glowBase or (0.5 + 0.5 * glowBase)) end
	end
	-- light on its surroundings: the head, the mouth, three spots along the body
	if glowBase > 0.02 and not WV_NOLIGHTS then
		local hpos = GetBodyTransform(v.head).pos
		PointLight(hpos, 1.0, 0.18, 0.1, 0.25 + 0.5 * glowBase)                -- (its red eyes)
		if open > 0.15 then PointLight(VecAdd(hpos, VecScale(hf, 0.5)), 1.0, 0.25, 0.05, 3 * open) end
		for _, k in ipairs({8, 18, 30}) do
			local s = v.segs[k]
			if s and not s.parked then
				local pulse = math.max(0, math.sin(t * speedW - k * 0.45)) ^ 3
				PointLight(GetBodyTransform(s.body).pos, 0.3, 1.0, 0.85, glowBase * (0.3 + 1.2 * pulse))
			end
		end
	end
	return headPos
end

function WormView.clientTick(dt)
	wvTake()
	local t = GetTime()
	wvFrame = wvFrame + 1
	wvCam = GetCameraTransform().pos
	for id, s in pairs(wvSnaps) do
		if t - (s.seen or 0) > 3 then                              -- (gone from the server's list)
			if wvViews[id] then wvDelete(wvViews[id]); wvViews[id] = nil end
			wvSnaps[id] = nil
		else
			local w = s.cur
			local v = wvViews[id]
			if not v then v = wvSpawn(); wvViews[id] = v end
			local f = 1
			if s.prev and s.prevT and s.curT > s.prevT then f = math.min(1, (t - s.curT) / (s.curT - s.prevT)) end
			-- far from the camera the body is posed every 2nd / 4th frame (the pose is Lua maths for every ring)
			local hd = dist(wvCam, Vec(w.trail[1] or 0, w.trail[2] or 0, w.trail[3] or 0))
			local every = hd < 70 and 1 or (hd < 140 and 2 or 4)
			v.lodDt = (v.lodDt or 0) + dt
			local head = v.headPos
			if not head or every == 1 or (wvFrame + id) % every == 0 then
				local tr = wvBlend(s.prev and s.prev.trail, w.trail, f)
				head = wvPose(v, w, tr, v.lodDt)
				v.headPos, v.lodDt = head, 0
			end
			wvSounds(v, w, s, head, dt)
			wvHits(v, w)
		end
	end
	-- the server's list no longer has it: published lists are complete, so drop ids not in the newest one
	local W = wvW
	if W and wvTook then
		local live = {}
		for i = 1, #W do live[W[i].id] = true end
		for id in pairs(wvViews) do
			if not live[id] then wvDelete(wvViews[id]); wvViews[id] = nil; wvSnaps[id] = nil end
		end
	end
end

function WormView.clientDraw()
	local me = GetLocalPlayer()
	local W = wvW
	if not W then return end
	-- the spawn menu's markers: the seconds until a worm comes out
	local marks = W.marks
	if marks then
		for i = 1, #marks, 4 do
			local x, y, d = UiWorldToPixel(Vec(marks[i], marks[i + 1] + 0.7, marks[i + 2]))
			if d > 0 and d < 80 then
				UiPush()
				UiTranslate(x, y)
				UiAlign("center middle")
				UiFont("bold.ttf", 44)
				UiColor(0, 0, 0, 0.8)
				UiTranslate(2, 2)
				UiText(tostring(math.ceil(marks[i + 3])))
				UiTranslate(-2, -2)
				UiColor(0.8, 0.4, 1, 0.6 + 0.4 * math.sin(GetTime() * 8))
				UiText(tostring(math.ceil(marks[i + 3])))
				UiPop()
			end
		end
	end
	for i = 1, #W do
		local w = W[i]
		if w.alive and w.grab == me and me ~= 0 then
			UiPush()
			UiTranslate(UiCenter(), UiHeight() * 0.72)
			UiAlign("center middle")
			UiFont("bold.ttf", 34)
			UiColor(1, 0.25, 0.2, 0.75 + 0.25 * math.sin(GetTime() * 12))
			UiText("SEIZED - HURT IT TO BREAK FREE")
			UiTranslate(0, 40)
			UiColor(0, 0, 0, 0.6)
			UiRect(420, 16)
			UiAlign("left middle")
			UiTranslate(-210, 0)
			UiColor(1, 0.3, 0.2, 0.9)
			UiRect(420 * math.min(1, w.esc or 0), 16)               -- (the damage taken while it holds you)
			UiPop()
			ShakeCamera(0.25)
		end
	end
end
