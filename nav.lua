-- nav.lua: Nav, the abyssipede's 3D navigation (server). Contract: worm/PROJECT.md "Navigation" and "Interfaces".
-- Included by main.lua (no #version line here). One global: Nav. Everything else is file-local.
--
-- Only the head plans; it moves in full 3D (water or air, no gravity), on any map. A request runs through
-- stages, spread over frames by Nav.tick(): per frame a query budget (opts.budget) and a Lua work budget
-- (opts.work, ~us of LuaJIT -joff time) shared round-robin by all pending requests; no stage issues a query the
-- budget cannot pay for, and every stage pauses and resumes exactly where it was.
--   line    one sphere cast from -> to (radius RAD): clear = done (the common case in open water / air).
--   open    14 short rays around the goal and the start: both open (few hits) -> engine, else -> grid.
--   engine  the engine's planner ("water" when the start is in water, else "flying"), one planner per agent,
--           up to ENGINE_TICKS frames (it times out on every enclosed target in the wreck). Its path is
--           resampled every 1 m, each sample pushed off surfaces, then string-pulled; any problem -> grid.
--   grid    weighted A* (W) on a lazy sparse grid (CELL cells, 26 neighbours, no corner cutting). Start and goal
--           snap to the nearest free cell within SNAP m. A flood from the goal cell (face neighbours) first
--           detects sealed goals (exhausted within PROBE_N cells: the search is then cut to SEALED_NODES for
--           its partial); the flood keeps growing a cell per A* expansion (up to PROBE_MAX), and A* ends as soon
--           as the two meet (a cheap bidirectional search: basins such as the deck under the goal). A buried
--           goal (no free cell within SNAP) gets the short search too. Goals farther than HORIZON m: the search
--           stays within HORIZON of the start and ends at the first cell it pops on that boundary (far = true:
--           the brain replans as it goes, plans stay local on huge maps).
--   dig     the worm bites through walls: when the grid search fails (sealed / partial) or every remaining
--           path is > DETOUR x the straight line and > DETOUR_MIN m (checked as it searches: the detour search
--           is paused, and resumed if digging fails), a dig search may pass blocked cells (face moves only) at
--           +digCost per cell, at most maxDig m of them; it is kept when it is cheaper.
--   smooth  the cell path is string-pulled with sphere casts: every returned leg is clear by RAD (by SQZ next
--           to cells players proved passable), or it is a dig leg. A raw leg that fails gets a midpoint pushed
--           off the surface (twice at most); else that grid edge is banned and A* runs again.
--
-- Cells: a cell is free when nothing static and physical (QueryRequire "physical static", QueryCollisionMask
-- MASK) lies within RT = radius + margin of its representative point: the cell centre, or, when the centre is
-- too close to a surface, the centre pushed straight away from the nearest surface point (QueryClosestPoint
-- gives it) up to NUDGE times, staying within 0.3 m of the centre. The first query of a cell uses a larger
-- radius (PROBE): when the nearest surface is d away, every cell centre within d - RT of this centre is free
-- too (the distance to geometry changes at most 1:1), and those cells are cached for free (open water / air).
-- Edges: centre-to-centre edges are trusted; an edge with a pushed end is checked when A* pops it (or the flood
-- crosses it): a sphere cast, else a path through midpoints pushed off the surface (vias, depth 2), cached.
-- Doors narrower than the grid: a 0.7 m door is free only within +-0.02 m of its axis at RT 0.33; the jambs push
-- cell points near the axis, and the vias line the edge up through the opening.
-- Cache: two generations of at most maxCells / 2 entries each (the older one is dropped when the newer one
-- fills); cached values: false = blocked, true = free at the centre, {x, y, z, proven} = free at that point.

Nav = {}

local sqrt, floor, abs, ceil, max, min = math.sqrt, math.floor, math.abs, math.ceil, math.max, math.min

local S = 131072            -- 2^17 cells per axis in a key: +-32 km at 0.5 m cells; keys stay below 2^51 (exact)
local S2 = S * S
local OFF = 65536
local NUDGE = 3             -- pushes per cell test / point
local TESTCOST = NUDGE + 1  -- the most queries one cell test can take
local NUDGE_EPS = 0.01
local FILL_MARGIN = 0.05
local MAXLEG = 20           -- m: longest smoothed leg
local MAXDEPTH = 2          -- midpoint insertions per raw leg
local MAXREPLAN = 6
local OPEN_LEN = 8          -- m: rays of the open-space check
local OPEN_HITS = 5         -- at most this many of 14 rays may hit for "open"
local ENGINE_STEP = 1.0     -- m: resampling of engine paths
local ENGINE_SLACK = 0.12    -- m: engine samples are pushed to RT + this (slack for the legs round corners)
local EDGECOST = 19         -- the most queries one edge connection can take (cast, pushed midpoints, depth 2)
-- Lua work per frame is capped (opts.work, units of ~1 us of LuaJIT -joff time, measured offline):
local WORK_NODE = 5         -- one node expansion (26 neighbour lookups)
local WORK_PUSH = 0.7       -- each neighbour pushed into the open list
local WORK_QUERY = 2.5      -- the Lua side of one query (cell test logic, pushes, casts)
local WORK_FILL = 0.15      -- each cell filled by a free probe
local WORK_PROBE = 3        -- one goal-flood cell

local CELL, RAD, MARGIN, RT, PROBE, SQZ, MASK, BUDGET, NODES_TICK, MAXNODES, W
local PROBE_MAX, PROBE_N, SEALED_NODES, ENGINE_TICKS, ENGINE_ON, ENGINE_TR, SNAP, HORIZON
local DIG_COST, MAX_DIG, DETOUR, DETOUR_MIN

-- the cache: each generation is NSH tables (by key % NSH): a Lua table that doubles rehashes all its entries
-- at once (3 ms for 131k entries in LuaJIT -joff); 16 shards keep each such pause ~16 times smaller
local NSH = 16
local function nav_shards()
	local t = {}
	for i = 1, NSH do t[i] = {} end
	return t
end
local C1, C0, n1, n0, GEN = nav_shards(), nav_shards(), 0, 0, 100000
local BAD, nBad = {}, 0
local GOOD, nGood = {}, 0
local HARD = {}             -- cells round where a bite cut nothing (hard metal...): no dig move into them (Nav.markHard)
local REQ, ORDER, PLANNER = {}, {}, {}
local qLeft, nLeft = 0, 0
local CUR = nil
local ST = {queries = 0, nodes = 0, ticks = 0, lastQueries = 0, lastNodes = 0, direct = 0, swaps = 0}
local FK, FD = {}, {}

-- the 26 neighbours: offsets, key deltas, step costs (cells), and for each the neighbours a move needs free
-- (its orthogonal components: no corner cutting); F6 = the face neighbours
local DX, DY, DZ, DK, DC, DEP, F6 = {}, {}, {}, {}, {}, {}, {}
do
	local n = 0
	for dx = -1, 1 do
		for dy = -1, 1 do
			for dz = -1, 1 do
				if dx ~= 0 or dy ~= 0 or dz ~= 0 then
					n = n + 1
					DX[n], DY[n], DZ[n] = dx, dy, dz
					DK[n] = dx * S2 + dy * S + dz
					DC[n] = sqrt(dx * dx + dy * dy + dz * dz)
					if abs(dx) + abs(dy) + abs(dz) == 1 then F6[#F6 + 1] = n end
				end
			end
		end
	end
	for i = 1, 26 do
		local d = {}
		for j = 1, 26 do
			if j ~= i and (DX[j] == 0 or DX[j] == DX[i]) and (DY[j] == 0 or DY[j] == DY[i])
				and (DZ[j] == 0 or DZ[j] == DZ[i]) then
				d[#d + 1] = j
			end
		end
		DEP[i] = d
	end
end

local OPEN_DIRS = {}
do
	local s3 = 1 / sqrt(3)
	local d = {{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}}
	for a = -1, 1, 2 do
		for b = -1, 1, 2 do
			for c = -1, 1, 2 do d[#d + 1] = {a * s3, b * s3, c * s3} end
		end
	end
	OPEN_DIRS = d
end

local function nav_key(ix, iy, iz)
	return ((ix + OFF) * S + (iy + OFF)) * S + (iz + OFF)
end

local function nav_decode(k)
	local a = floor(k / S2)
	local r = k - a * S2
	local b = floor(r / S)
	return a - OFF, b - OFF, r - b * S - OFF
end

local function nav_swap()
	C0, n0 = C1, n1
	C1, n1 = nav_shards(), 0
	ST.swaps = ST.swaps + 1
end

local function nav_get(k)
	local sh = k % NSH + 1
	local v = C1[sh][k]
	if v == nil then
		v = C0[sh][k]
		if v ~= nil then
			C1[sh][k] = v
			n1 = n1 + 1
			if n1 >= GEN then nav_swap() end
		end
	end
	return v
end

local function nav_set(k, v)
	local t = C1[k % NSH + 1]
	if t[k] == nil then n1 = n1 + 1 end
	t[k] = v
	if n1 >= GEN then nav_swap() end
end

local function nav_del(k)
	local sh = k % NSH + 1
	if C1[sh][k] ~= nil then C1[sh][k] = nil; n1 = n1 - 1 end
	if C0[sh][k] ~= nil then C0[sh][k] = nil; n0 = n0 - 1 end
end

-- query arguments: reused tables (a Vec is a plain {x, y, z}; the engine only reads it), no garbage per query
local QA, QB = {0, 0, 0}, {0, 0, 0}

local function nav_count()
	if CUR then CUR.queries = CUR.queries + 1 end
	qLeft = qLeft - 1
	nLeft = nLeft - WORK_QUERY
	ST.queries = ST.queries + 1
end

-- closest static surface point within r: hit, distance, point
local function nav_cp(x, y, z, r)
	QueryRequire("physical static")
	QueryCollisionMask(MASK)
	nav_count()
	QA[1], QA[2], QA[3] = x, y, z
	local hit, p = QueryClosestPoint(QA, r)
	if not hit then return false end
	local hx, hy, hz = p[1], p[2], p[3]
	local dx, dy, dz = x - hx, y - hy, z - hz
	return true, sqrt(dx * dx + dy * dy + dz * dz), hx, hy, hz
end

-- sphere cast a -> b with radius r: true when clear
local function nav_cast(ax, ay, az, bx, by, bz, r)
	local dx, dy, dz = bx - ax, by - ay, bz - az
	local L = sqrt(dx * dx + dy * dy + dz * dz)
	if L < 1e-6 then return true end
	QueryRequire("physical static")
	QueryCollisionMask(MASK)
	nav_count()
	QA[1], QA[2], QA[3] = ax, ay, az
	QB[1], QB[2], QB[3] = dx / L, dy / L, dz / L
	local hit = QueryRaycast(QA, QB, L, r)
	return not hit
end

local function nav_ray(x, y, z, d, len)
	QueryRequire("physical static")
	QueryCollisionMask(MASK)
	nav_count()
	QA[1], QA[2], QA[3] = x, y, z
	local hit = QueryRaycast(QA, d, len)
	return hit
end

-- push (x, y, z), whose nearest surface point (hx, hy, hz) is d away, until nothing is within rt; stays within
-- lim (per axis) of (cx, cy, cz). Up to NUDGE queries. Returns ok, x, y, z.
local function nav_push(x, y, z, d, hx, hy, hz, rt, lim, cx, cy, cz)
	for _ = 1, NUDGE do
		if d < 0.002 then return false end
		local s = (rt + NUDGE_EPS - d) / d
		x, y, z = x + (x - hx) * s, y + (y - hy) * s, z + (z - hz) * s
		if abs(x - cx) > lim or abs(y - cy) > lim or abs(z - cz) > lim then return false end
		local hit
		hit, d, hx, hy, hz = nav_cp(x, y, z, rt)
		if not hit then return true, x, y, z end
	end
	return false
end

-- test cell k (coords ix, iy, iz): costs 1..TESTCOST queries; caches and returns its value
local function nav_test(k, ix, iy, iz)
	local cx, cy, cz = (ix + 0.5) * CELL, (iy + 0.5) * CELL, (iz + 0.5) * CELL
	local hit, d, hx, hy, hz = nav_cp(cx, cy, cz, PROBE)
	if not hit then d = PROBE end
	if d >= RT then
		nav_set(k, true)
		local reach = d - RT - FILL_MARGIN
		local i = 1
		while i <= #FK and FD[i] <= reach do
			local nk = k + FK[i]
			local sh = nk % NSH + 1
			if C1[sh][nk] == nil and C0[sh][nk] == nil then nav_set(nk, true) end
			i = i + 1
		end
		nLeft = nLeft - (i - 1) * WORK_FILL
		return true
	end
	local ok, px, py, pz = nav_push(cx, cy, cz, d, hx, hy, hz, RT, CELL * 0.5 + 0.05, cx, cy, cz)
	if ok then
		local v = {px, py, pz, false}
		nav_set(k, v)
		return v
	end
	nav_set(k, false)
	return false
end

-- connect a -> b for a body of radius r: a sphere cast, else through midpoints pushed off the surface (to rt),
-- recursively (depth 2). Appends the via points to out; at most EDGECOST queries.
local function nav_connect(ax, ay, az, bx, by, bz, r, rt, depth, out)
	if nav_cast(ax, ay, az, bx, by, bz, r) then return true end
	if depth >= 2 then return false end
	local mx, my, mz = (ax + bx) * 0.5, (ay + by) * 0.5, (az + bz) * 0.5
	local hit, d, hx, hy, hz = nav_cp(mx, my, mz, rt)
	if hit then
		local ok
		ok, mx, my, mz = nav_push(mx, my, mz, d, hx, hy, hz, rt, CELL * 0.5, mx, my, mz)
		if not ok then return false end
	end
	if not nav_connect(ax, ay, az, mx, my, mz, r, rt, depth + 1, out) then return false end
	out[#out + 1], out[#out + 2], out[#out + 3] = mx, my, mz
	return nav_connect(mx, my, mz, bx, by, bz, r, rt, depth + 1, out)
end

local function nav_cellof(x, y, z)
	local ix, iy, iz = floor(x / CELL), floor(y / CELL), floor(z / CELL)
	return nav_key(ix, iy, iz), ix, iy, iz
end

local function nav_rep(k, v)
	if type(v) == "table" then return v[1], v[2], v[3] end
	local ix, iy, iz = nav_decode(k)
	return (ix + 0.5) * CELL, (iy + 0.5) * CELL, (iz + 0.5) * CELL
end

-- a validated edge a -> b: true, or its via points {x1, y1, z1, x2, ...} in order from a to b
local function nav_good(a, b, via)
	if nGood > 200000 then GOOD, nGood = {}, 0 end
	local fwd, back = true, true
	if via and #via > 0 then
		fwd, back = via, {}
		for i = #via - 2, 1, -3 do
			back[#back + 1], back[#back + 2], back[#back + 3] = via[i], via[i + 1], via[i + 2]
		end
	end
	GOOD[a] = GOOD[a] or {}
	GOOD[a][b] = fwd
	GOOD[b] = GOOD[b] or {}
	GOOD[b][a] = back
	nGood = nGood + 1
end

local function nav_ban(a, b)
	if nBad > 100000 then BAD, nBad = {}, 0 end
	nBad = nBad + 1
	if GOOD[a] then GOOD[a][b] = nil end
	if GOOD[b] then GOOD[b][a] = nil end
	BAD[a] = BAD[a] or {}
	BAD[a][b] = true
	BAD[b] = BAD[b] or {}
	BAD[b][a] = true
end

-- the open list (per request): a bucket queue, f quantised to 1/BUCKETS cell, last in first out within a bucket
-- (O(1) per push: in open space every expansion pushes up to 26 cells). q.hB = buckets, q.hN = their sizes,
-- q.hm = the lowest bucket that may be non-empty, q.hn = entries.
local BUCKETS = 4

local function nav_hpush(q, k, f)
	local b = floor(f * BUCKETS)
	local B, N = q.hB, q.hN
	local t = B[b]
	if not t then t = {}; B[b] = t; N[b] = 0 end
	local n = N[b] + 1
	N[b] = n
	t[n] = k
	if b < q.hm then q.hm = b end
	q.hn = q.hn + 1
end

-- the top entry (nil when empty); moves q.hm to its bucket
local function nav_hpeek(q)
	if q.hn == 0 then return nil end
	local N = q.hN
	local b = q.hm
	while (N[b] or 0) == 0 do b = b + 1 end
	q.hm = b
	return q.hB[b][N[b]]
end

local function nav_hpop(q)
	if nav_hpeek(q) == nil then return end
	local b = q.hm
	local n = q.hN[b]
	q.hB[b][n] = nil
	q.hN[b] = n - 1
	q.hn = q.hn - 1
end

---------------------------------------------------------------------------------------------------------------
-- request stages

local STEP = {}

local function nav_dist(ax, ay, az, bx, by, bz)
	local dx, dy, dz = bx - ax, by - ay, bz - az
	return sqrt(dx * dx + dy * dy + dz * dz)
end

local function nav_finish(q)
	local o = q.out
	local last = o[#o]
	local res = {
		ok = q.reached and true or false, partial = not q.reached, points = o, tight = q.tight or {},
		digs = q.digs or {}, dig = (q.digs and #q.digs > 0) and true or false,
		source = q.src, far = (q.far and not q.reached) and true or false, sealed = q.sealed or false,
		queries = q.queries, nodes = q.nodesAll, ticks = q.ticks,
		gap = nav_dist(last[1], last[2], last[3], q.tx, q.ty, q.tz),
	}
	q.result = res
	q.g, q.par, q.cl, q.hB, q.hN, q.du, q.keys = nil, nil, nil, nil, nil, nil, nil
	q.pv, q.pd, q.saved, q.normKeys, q.pq, q.meet = nil, nil, nil, nil, nil, nil
	q.X, q.Y, q.Z, q.P, q.D, q.K, q.M, q.G, q.DE, q.digEdge = nil, nil, nil, nil, nil, nil, nil, nil, nil, nil
	return false
end

local function nav_emit(q, i, tight, dig)
	local o = q.out
	local last = o[#o]
	local x, y, z = q.X[i], q.Y[i], q.Z[i]
	if nav_dist(last[1], last[2], last[3], x, y, z) < 1e-6 then return end
	local leg = #o
	if tight then q.tight[leg] = true end
	if dig then q.digs[#q.digs + 1] = leg end
	o[leg + 1] = Vec(x, y, z)
end

local function nav_smoothstart(q)
	q.sa, q.sb = 1, 1
	q.tA = q.P[1]
	q.out = {Vec(q.X[1], q.Y[1], q.Z[1])}
	q.tight, q.digs = {}, {}
	q.st = "smooth"
end

-- raw points from the grid path (q.keys), with the request's start and goal unless dropped
local function nav_rawgrid(q)
	local X, Y, Z, P, D, K, M, G = {}, {}, {}, {}, {}, {}, {}, {}
	local DE = {}
	local n = 0
	if not q.noStart then
		n = 1
		X[1], Y[1], Z[1], P[1], D[1], K[1], M[1], G[1] = q.fx, q.fy, q.fz, false, 0, false, "s", false
	end
	local keys = q.keys
	local prevP = false
	for i = 1, #keys do
		local k = keys[i]
		local v = nav_get(k)
		local x, y, z = nav_rep(k, v)
		local pk = (type(v) == "table" and v[4]) and true or false
		local gp = i > 1 and GOOD[keys[i - 1]]
		local via = gp and gp[k]
		if type(via) == "table" then
			for j = 1, #via, 3 do
				n = n + 1
				X[n], Y[n], Z[n], D[n], K[n], M[n], G[n] = via[j], via[j + 1], via[j + 2], 1, false, false, false
				P[n] = pk or prevP
			end
		end
		n = n + 1
		X[n], Y[n], Z[n], D[n], K[n], M[n] = x, y, z, 0, k, false
		P[n] = pk
		G[n] = (q.digUsed and v == false) and true or false
		DE[n] = (q.digUsed and i > 1 and q.digEdge and q.digEdge[k] == keys[i - 1]) and true or false
		prevP = pk
	end
	if q.reached and not q.noGoal then
		n = n + 1
		X[n], Y[n], Z[n], P[n], D[n], K[n], M[n], G[n] = q.tx, q.ty, q.tz, false, 0, false, "g", false
	end
	for i = 1, n do DE[i] = DE[i] or false end
	q.X, q.Y, q.Z, q.P, q.D, q.K, q.M, q.G = X, Y, Z, P, D, K, M, G
	q.DE = DE
	nav_smoothstart(q)
end

local function nav_heur(q, k)
	local ix, iy, iz = nav_decode(k)
	local ex, ey, ez = ix - q.gx, iy - q.gy, iz - q.gz
	return sqrt(ex * ex + ey * ey + ez * ez)
end

local function nav_astarstart(q, dig)
	q.g, q.par, q.cl, q.hB, q.hN, q.hn, q.hm = {}, {}, {}, {}, {}, 0, 0
	q.fr = q.fr or {}
	q.digMode = dig
	q.du = dig and {} or nil
	q.digEdge = dig and {} or nil
	q.meet = nil
	q.nodes = 0
	q.g[q.sk] = 0
	if dig then q.du[q.sk] = 0 end
	local h = nav_heur(q, q.sk)
	nav_hpush(q, q.sk, W * h)
	q.best, q.bestH = q.sk, h
	q.st = "astar"
end

local function nav_togrid(q)
	q.src = "grid"
	q.st = "snap"
	q.X = nil
end

-- the smoothed path is done: deliver
local function nav_smoothdone(q)
	return nav_finish(q)
end

-- a raw leg a -> j stays blocked after midpoint pushes
local function nav_legfail(q, a, j)
	if q.src == "engine" then nav_togrid(q); return true end
	local K, M = q.K, q.M
	local l = a
	while not K[l] and not M[l] do l = l - 1 end
	local r = j
	while not K[r] and not M[r] do r = r + 1 end
	if M[l] == "s" then q.noStart = true; nav_rawgrid(q); return true end
	if M[r] == "g" then q.noGoal = true; nav_rawgrid(q); return true end
	nav_ban(K[l], K[r])
	q.replans = q.replans + 1
	if q.replans > MAXREPLAN then
		q.reached = false
		return nav_finish(q)                -- the verified prefix
	end
	nav_astarstart(q, q.digUsed)
	return true
end

function STEP.smooth(q)
	local X, Y, Z, P, D, G, DE = q.X, q.Y, q.Z, q.P, q.D, q.G, q.DE
	while true do
		local n = #X
		local a, k = q.sa, q.sb
		if k >= n then
			if a < n then nav_emit(q, n, q.tA, false) end
			return nav_smoothdone(q)
		end
		local j = k + 1
		if G[a] or G[j] or DE[j] then
			-- a dig leg: never shortcut over it, never cast it (the brain bites through)
			if k > a then
				nav_emit(q, k, q.tA, false)
				q.sa, q.tA = k, P[k]
			else
				nav_emit(q, j, false, true)
				q.sa, q.sb, q.tA = j, j, P[j]
			end
		else
			local clear = false
			local tt = q.tA or P[j]
			local stop = k > a and (P[j] ~= P[k]
				or nav_dist(X[a], Y[a], Z[a], X[j], Y[j], Z[j]) > MAXLEG)
			if not stop then
				if qLeft < 1 or nLeft <= 0 then return false end
				clear = nav_cast(X[a], Y[a], Z[a], X[j], Y[j], Z[j], tt and SQZ or RAD)
			end
			if clear then
				q.sb, q.tA = j, tt
			elseif k > a then
				nav_emit(q, k, q.tA, false)
				q.sa, q.tA = k, P[k]
			else
				-- the raw leg a -> j itself is blocked: insert a midpoint pushed off the surface
				if max(D[a], D[j]) < MAXDEPTH then
					if qLeft < TESTCOST then return false end
					local mx, my, mz = (X[a] + X[j]) * 0.5, (Y[a] + Y[j]) * 0.5, (Z[a] + Z[j]) * 0.5
					local tight = P[a] or P[j]
					local rt = tight and (SQZ + 0.02) or RT
					local hit, d, hx, hy, hz = nav_cp(mx, my, mz, rt)
					local ok, px, py, pz = true, mx, my, mz
					if hit then ok, px, py, pz = nav_push(mx, my, mz, d, hx, hy, hz, rt, CELL * 0.5, mx, my, mz) end
					if ok then
						table.insert(X, j, px); table.insert(Y, j, py); table.insert(Z, j, pz)
						table.insert(P, j, tight); table.insert(D, j, max(D[a], D[j]) + 1)
						table.insert(q.K, j, false); table.insert(q.M, j, false); table.insert(G, j, false)
						table.insert(DE, j, false)
					else
						return nav_legfail(q, a, j)
					end
				else
					return nav_legfail(q, a, j)
				end
			end
		end
	end
end

-- path keys from the start to e (A* parents), then on along the goal flood's tree when e is in it
local function nav_chain(q, e)
	local rev = {}
	local c = e
	while c ~= nil do
		rev[#rev + 1] = c
		c = q.par[c]
	end
	local keys = {}
	for i = #rev, 1, -1 do keys[#keys + 1] = rev[i] end
	local pv = q.pv
	if pv and pv[e] ~= nil then
		c = pv[e]
		while c ~= -1 do
			keys[#keys + 1] = c
			c = pv[c]
		end
	end
	return keys
end

local function nav_save(q)
	q.saved = {q.g, q.par, q.cl, q.hB, q.hN, q.hn, q.nodes, q.best, q.bestH, q.maxN, q.hm}
end

local function nav_restore(q)
	local t = q.saved
	q.g, q.par, q.cl, q.hB, q.hN, q.hn, q.nodes, q.best, q.bestH, q.maxN, q.hm =
		t[1], t[2], t[3], t[4], t[5], t[6], t[7], t[8], t[9], t[10], t[11]
	q.saved = nil
	q.digMode, q.du, q.digEdge = false, nil, nil
	q.cutoff = nil
	q.st = "astar"
end

-- the cost (cells) of the path to k: A* g plus the flood's steps on to the goal
local function nav_cost(q, k)
	return q.g[k] + (q.pd and q.pd[k] or 0)
end

-- an A* run ended: reached the goal (cell k, or k joins the goal flood), or not (cut = stopped early because
-- every remaining path is a long detour). Maybe try digging, then smooth.
local function nav_astarend(q, reached, k, cut)
	if q.digMode then
		local useDig = reached and (not q.normReached or nav_cost(q, k) < q.normG)
		if useDig then
			q.digUsed = true
			q.keys, q.reached = nav_chain(q, k), true
		else
			q.digUsed = false
			if q.saved then nav_restore(q); return true end      -- digging failed: finish the detour search
			q.keys, q.reached = q.normKeys, q.normReached
		end
		nav_rawgrid(q)
		return true
	end
	local keys = nav_chain(q, reached and k or q.best)
	if q.dig ~= false and q.gk and not q.far and not q.digTried then
		local long = cut
		if reached then
			local len = nav_cost(q, k) * CELL
			local straight = nav_dist(q.fx, q.fy, q.fz, q.tx, q.ty, q.tz)
			long = len > DETOUR * straight and len > DETOUR_MIN
		end
		if not reached or long then
			q.digTried = true
			q.normKeys, q.normReached = keys, reached
			q.normG = reached and nav_cost(q, k) or math.huge
			if cut then nav_save(q) end
			q.maxN = q.maxN0
			nav_astarstart(q, true)
			return true
		end
	end
	q.keys, q.reached = keys, reached
	nav_rawgrid(q)
	return true
end

-- is the edge p -> k usable? Centre-to-centre edges are trusted (the smoothing still casts every leg); an edge
-- with a pushed or proven end is connected by nav_connect (cast, else pushed midpoints) once and cached.
-- Returns 1 = yes, 0 = out of budget, -1 = no (banned).
local function nav_edge(p, vp, k, vk)
	if type(vk) ~= "table" and type(vp) ~= "table" then return 1 end
	local gp = GOOD[p]
	if gp and gp[k] then return 1 end
	local bp = BAD[p]
	if bp and bp[k] then return -1 end
	if qLeft < EDGECOST then return 0 end
	local ax, ay, az = nav_rep(p, vp)
	local bx, by, bz = nav_rep(k, vk)
	local tight = (type(vk) == "table" and vk[4]) or (type(vp) == "table" and vp[4])
	local via = {}
	if nav_connect(ax, ay, az, bx, by, bz, tight and SQZ or RAD, tight and (SQZ + 0.02) or RT, 0, via) then
		nav_good(p, k, via)
		return 1
	end
	nav_ban(p, k)
	return -1
end

-- the edge from k's parent, checked when k is popped. A bad edge gets k the best other closed neighbour as
-- parent (or drops it). Returns 1 = fine, 0 = out of budget, -1 = k was popped (reparented, dropped, stale).
local function nav_parentok(q, k)
	local par = q.par
	local p = par[k]
	if p == nil then
		if k == q.sk then return 1 end
		nav_hpop(q)
		return -1
	end
	local vk, vp = nav_get(k), nav_get(p)
	if not vk or not vp then return 1 end           -- dig moves: bites, not casts
	local de = q.digEdge
	if de and de[k] == p then return 1 end
	local r = nav_edge(p, vp, k, vk)
	if r >= 0 then return r end
	nav_hpop(q)
	if de then
		-- digging: a blocked face edge between two free cells (a thin wall) is one bite
		local dk = abs(k - p)
		local d = (q.du[p] or 0) + 1
		if (dk == 1 or dk == S or dk == S2) and d <= MAX_DIG and not HARD[k] then
			de[k] = p
			local g = q.g[p] + 1 + DIG_COST
			q.g[k], q.du[k] = g, d
			nav_hpush(q, k, g + W * nav_heur(q, k))
			return -1
		end
	end
	local g, cl, du = q.g, q.cl, q.du
	local bk = BAD[k]
	local best, bg = nil, math.huge
	for i = 1, 26 do
		local n = k + DK[i]
		local gn = g[n]
		if cl[n] and gn and gn + DC[i] < bg and not (bk and bk[n]) and nav_get(n) then
			local okc = true
			local dep = DEP[i]
			for j = 1, #dep do
				if not nav_get(k + DK[dep[j]]) then okc = false; break end
			end
			if okc then best, bg = n, gn + DC[i] end
		end
	end
	if best then
		g[k], par[k] = bg, best
		if du then du[k] = du[best] or 0 end
		nav_hpush(q, k, bg + W * nav_heur(q, k))
	else
		g[k], par[k] = nil, nil
	end
	return -1
end

-- flood from the goal cell over face neighbours (edges checked like A*'s): a goal region smaller than PROBE_N
-- cells that does not reach the start is sealed. The flood's tree (pv: parent toward the goal, pd: steps) stays
-- and keeps growing during A* (a cell per expansion, up to PROBE_MAX): A* finishes as soon as it reaches a
-- flooded cell, or the flood reaches a cell A* has closed (a cheap bidirectional search).
-- One flood cell: returns 1 = done, 0 = out of budget, 2 = the flood is over (exhausted, full, met the start).
local function nav_probestep(q, cap)
	local pq, pv, pd = q.pq, q.pv, q.pd
	if q.ph > #pq then q.sealed = true; return 2 end
	if #pq >= cap then return 2 end
	if nLeft <= 0 then return 0 end
	local k = pq[q.ph]
	local ix, iy, iz = nav_decode(k)
	for f = 1, 6 do
		local i = F6[f]
		local nk = k + DK[i]
		if nav_get(nk) == nil then
			if qLeft < TESTCOST or nLeft <= 0 then return 0 end
			nav_test(nk, ix + DX[i], iy + DY[i], iz + DZ[i])
		end
	end
	local vk = nav_get(k)
	local cl = q.cl
	for f = q.pf or 1, 6 do
		local nk = k + DK[F6[f]]
		if pv[nk] == nil then
			local vn = nav_get(nk)
			if vn then
				local r = nav_edge(k, vk, nk, vn)
				if r == 0 then q.pf = f; return 0 end
				if r == 1 then
					pv[nk], pd[nk] = k, pd[k] + 1
					if nk == q.sk then q.pf = nil; q.ph = q.ph + 1; return 2 end
					if cl and cl[nk] and not q.meet then q.meet = nk end
					pq[#pq + 1] = nk
				end
			end
		end
	end
	q.pf = nil
	q.ph = q.ph + 1
	nLeft = nLeft - WORK_PROBE
	q.nodesAll = q.nodesAll + 1
	return 1
end

function STEP.astar(q)
	local g, par, cl, fr = q.g, q.par, q.cl, q.fr
	local gx, gy, gz = q.gx, q.gy, q.gz
	local gk = q.gk
	local dig, du = q.digMode, q.du
	local far = q.far
	local hx, hy, hz, hr2 = q.hcx, q.hcy, q.hcz, q.hr2
	local pv = q.pv
	local cutoff = (not dig and not q.digTried) and q.cutoff or nil
	while true do
		if q.floodDue then
			-- the goal flood grows a cell per expansion, strictly interleaved (the same search at any budget)
			local r = nav_probestep(q, PROBE_MAX)
			if r == 0 then return false end
			q.floodDue = false
			if r == 2 then q.pq = nil end
		end
		if q.meet then return nav_astarend(q, true, q.meet) end
		if q.hn == 0 or q.nodes >= q.maxN then return nav_astarend(q, false) end
		if nLeft <= 0 then return false end
		local k = nav_hpeek(q)
		local pr = -1
		if cl[k] then
			nav_hpop(q)
		else
			pr = nav_parentok(q, k)
			if pr == 0 then return false end
		end
		if pr == 1 and (k == gk or (pv and pv[k] ~= nil)) then
			nav_hpop(q)
			cl[k] = true
			return nav_astarend(q, true, k)
		elseif pr == 1 and cutoff and g[k] + nav_heur(q, k) > cutoff then
			return nav_astarend(q, false, nil, true)
		elseif pr == 1 then
			local ix, iy, iz = nav_decode(k)
			if far then
				-- the first cell popped at the horizon is the intermediate goal
				local cx, cy, cz = ix - hx, iy - hy, iz - hz
				if cx * cx + cy * cy + cz * cz >= q.hb2 then
					q.best = k
					return nav_astarend(q, false)
				end
			end
			for i = 1, 26 do
				local nk = k + DK[i]
				local sh = nk % NSH + 1
				local v = C1[sh][nk]
				if v == nil then
					v = C0[sh][nk]
					if v ~= nil then
						C1[sh][nk] = v
						n1 = n1 + 1
						if n1 >= GEN then nav_swap() end
					else
						if qLeft < TESTCOST or nLeft <= 0 then return false end
						v = nav_test(nk, ix + DX[i], iy + DY[i], iz + DZ[i])
					end
				end
				fr[i] = v
			end
			nav_hpop(q)
			cl[k] = true
			q.nodes = q.nodes + 1
			q.nodesAll = q.nodesAll + 1
			ST.nodes = ST.nodes + 1
			local pushes = 0
			local g0 = g[k]
			local bk = BAD[k]
			local selfBlocked, d0 = false, 0
			if dig then
				selfBlocked = (nav_get(k) == false)
				d0 = du[k] or 0
			end
			if not selfBlocked then
				local ex, ey, ez = ix - gx, iy - gy, iz - gz
				local h = sqrt(ex * ex + ey * ey + ez * ez)
				if h < q.bestH then q.best, q.bestH = k, h end
			end
			for i = 1, 26 do
				local v = fr[i]
				local nk = k + DK[i]
				if not cl[nk] and not (bk and bk[nk] and not (dig and DC[i] == 1)) then
					local cost = nil
					if v and not selfBlocked then
						local okc = true
						local dep = DEP[i]
						for j = 1, #dep do
							if not fr[dep[j]] then okc = false; break end
						end
						if okc then cost = DC[i] end
					elseif dig and DC[i] == 1 and not HARD[nk] then
						-- digging: face moves into / out of blocked cells, at most MAX_DIG cells of them
						if v then cost = 1
						elseif d0 + 1 <= MAX_DIG then cost = 1 + DIG_COST end
					end
					if cost then
						local ex, ey, ez = ix + DX[i], iy + DY[i], iz + DZ[i]
						local inside = true
						if far then
							local cx, cy, cz = ex - hx, ey - hy, ez - hz
							inside = cx * cx + cy * cy + cz * cz <= hr2
						end
						if inside then
							local ng = g0 + cost
							local og = g[nk]
							if og == nil or ng < og then
								g[nk] = ng
								par[nk] = k
								if dig then
									du[nk] = v and d0 or d0 + 1
									q.digEdge[nk] = nil
								end
								ex, ey, ez = ex - gx, ey - gy, ez - gz
								nav_hpush(q, nk, ng + W * sqrt(ex * ex + ey * ey + ez * ez))
								pushes = pushes + 1
							end
						end
					end
				end
			end
			nLeft = nLeft - WORK_NODE - WORK_PUSH * pushes
			if q.pq then q.floodDue = true end
		end
	end
end

local function pvStart(q) return q.pv[q.sk] ~= nil end

function STEP.probe(q)
	while true do
		local r = nav_probestep(q, PROBE_N)
		if r == 0 then return false end
		if r == 2 then break end
	end
	if q.sealed then
		q.maxN = min(q.maxN, SEALED_NODES)
		q.pq = nil
	elseif q.ph > #q.pq or pvStart(q) then
		q.pq = nil
	end
	nav_astarstart(q, false)
	return true
end

-- snap a point to the nearest free cell within SNAP m (ring by ring); pauses on budget.
-- Returns "wait", or the key (false when none)
local function nav_snapstep(q, x, y, z, slot)
	local k0, ix, iy, iz = nav_cellof(x, y, z)
	local R = ceil(SNAP / CELL)
	local r = q[slot .. "r"] or 0
	while r <= R do
		-- make sure ring r is cached
		for a = -r, r do
			for b = -r, r do
				for c = -r, r do
					if max(abs(a), abs(b), abs(c)) == r then
						local k = k0 + a * S2 + b * S + c
						if nav_get(k) == nil then
							if qLeft < TESTCOST or nLeft <= 0 then q[slot .. "r"] = r; return "wait" end
							nav_test(k, ix + a, iy + b, iz + c)
						end
					end
				end
			end
		end
		-- the nearest free representative point within rings 0..r
		local best, bd = false, math.huge
		for a = -r, r do
			for b = -r, r do
				for c = -r, r do
					local k = k0 + a * S2 + b * S + c
					local v = nav_get(k)
					if v then
						local px, py, pz = nav_rep(k, v)
						local d = nav_dist(x, y, z, px, py, pz)
						if d < bd then best, bd = k, d end
					end
				end
			end
		end
		if best and bd <= SNAP + CELL then return best end
		r = r + 1
	end
	return false
end

function STEP.snap(q)
	if q.sk == nil then
		local s = nav_snapstep(q, q.fx, q.fy, q.fz, "s")
		if s == "wait" then return false end
		q.sk = s
		if not s then
			q.reached = false
			q.out, q.tight, q.digs = {Vec(q.fx, q.fy, q.fz)}, {}, {}
			return nav_finish(q)
		end
	end
	if q.gk == nil then
		if q.far then
			q.gk = false
		else
			local s = nav_snapstep(q, q.tx, q.ty, q.tz, "g")
			if s == "wait" then return false end
			q.gk = s
		end
	end
	if q.far then
		local _, ix, iy, iz = nav_cellof(q.fx, q.fy, q.fz)
		q.hcx, q.hcy, q.hcz = ix, iy, iz
		q.hr2 = (HORIZON / CELL) * (HORIZON / CELL)
		q.hb2 = (HORIZON / CELL - 2) * (HORIZON / CELL - 2)
	end
	if not q.gk then
		-- the goal is buried (no free cell near it) or beyond the horizon
		if not q.far then q.maxN = min(q.maxN, SEALED_NODES) end
		nav_astarstart(q, false)
		return true
	end
	if q.dig ~= false then
		local straight = nav_dist(q.fx, q.fy, q.fz, q.tx, q.ty, q.tz)
		q.cutoff = max(DETOUR * straight, DETOUR_MIN) / CELL
	end
	if q.gk ~= q.sk then
		q.pq, q.pv, q.pd, q.ph = {q.gk}, {[q.gk] = -1}, {[q.gk] = 0}, 1
		q.st = "probe"
		return true
	end
	nav_astarstart(q, false)
	return true
end

function STEP.line(q)
	local L = nav_dist(q.fx, q.fy, q.fz, q.tx, q.ty, q.tz)
	if L < 1e-6 then
		q.reached, q.src = true, "line"
		q.out, q.tight, q.digs = {Vec(q.fx, q.fy, q.fz)}, {}, {}
		return nav_finish(q)
	end
	if qLeft < 1 then return false end
	if nav_cast(q.fx, q.fy, q.fz, q.tx, q.ty, q.tz, RAD) then
		q.reached, q.src = true, "line"
		q.out, q.tight, q.digs = {Vec(q.fx, q.fy, q.fz), Vec(q.tx, q.ty, q.tz)}, {}, {}
		return nav_finish(q)
	end
	q.src = "grid"
	if not ENGINE_ON or q.engine == false then
		q.st = "snap"
	elseif q.engine == "force" then
		q.st = "engine"
	else
		q.st = "open"
	end
	return true
end

function STEP.open(q)
	while q.oi <= 28 do
		local i = q.oi
		if i == 15 and q.oh > OPEN_HITS then break end
		if qLeft < 1 then return false end
		local d = OPEN_DIRS[(i - 1) % 14 + 1]
		local hit
		if i <= 14 then
			hit = nav_ray(q.tx, q.ty, q.tz, d, OPEN_LEN)
			if hit then q.oh = q.oh + 1 end
		else
			hit = nav_ray(q.fx, q.fy, q.fz, d, OPEN_LEN)
			if hit then q.ofh = q.ofh + 1 end
		end
		q.oi = i + 1
	end
	if q.oi > 28 and q.oh <= OPEN_HITS and q.ofh <= OPEN_HITS then
		q.st = "engine"
	else
		q.st = "snap"
	end
	return true
end

function STEP.engine(q)
	local pl = PLANNER[q.id]
	if not q.eStarted then
		if not pl then
			pl = CreatePathPlanner()
			PLANNER[q.id] = pl
		end
		local L = nav_dist(q.fx, q.fy, q.fz, q.tx, q.ty, q.tz)
		local kind = "flying"
		-- ("water" only when both ends are in water: from the sea to a goal on land it found nothing in-game, Isla
		-- Estocastica 2026-11-03; in open water the two plan alike, Dive's probe)
		if IsPointInWater and IsPointInWater(Vec(q.fx, q.fy, q.fz)) and IsPointInWater(Vec(q.tx, q.ty, q.tz)) then kind = "water" end
		PathPlannerQuery(pl, Vec(q.fx, q.fy, q.fz), Vec(q.tx, q.ty, q.tz), max(60, 2.5 * L), ENGINE_TR, kind)
		q.eStarted, q.eBusy, q.eTicks, q.eTick = true, true, 0, ST.ticks
		q.eKind = kind
		return false
	end
	if q.eTick == ST.ticks then return false end
	q.eTick = ST.ticks
	q.eTicks = q.eTicks + 1
	local s = GetPathState(pl)
	if s == "done" then
		q.eBusy = false
		local len = GetPathLength(pl)
		local X, Y, Z = {q.fx}, {q.fy}, {q.fz}
		local d = ENGINE_STEP
		while d < len do
			local p = GetPathPoint(d, pl)
			X[#X + 1], Y[#Y + 1], Z[#Z + 1] = p[1], p[2], p[3]
			d = d + ENGINE_STEP
		end
		local p = GetPathPoint(len, pl)
		X[#X + 1], Y[#Y + 1], Z[#Z + 1] = p[1], p[2], p[3]
		X[#X + 1], Y[#Y + 1], Z[#Z + 1] = q.tx, q.ty, q.tz
		local n = #X
		local P, D, K, M, G = {}, {}, {}, {}, {}
		for i = 1, n do P[i], D[i], K[i], M[i], G[i] = false, 0, false, false, false end
		M[1], M[n] = "s", "g"
		q.X, q.Y, q.Z, q.P, q.D, q.K, q.M, q.G = X, Y, Z, P, D, K, M, G
		q.DE = {}
		for i = 1, n do q.DE[i] = false end
		q.ei = 2
		q.src = "engine"
		q.st = "enudge"
		return true
	end
	if s == "fail" or s == "idle" or q.eTicks >= ENGINE_TICKS then
		if q.eBusy then AbortPath(pl) end
		q.eBusy = false
		nav_togrid(q)
		return true
	end
	return false
end

-- push the engine's samples off surfaces (it keeps 0.05-0.13 m off them)
function STEP.enudge(q)
	local X, Y, Z = q.X, q.Y, q.Z
	local n = #X
	while q.ei < n do
		if qLeft < TESTCOST then return false end
		local i = q.ei
		local x, y, z = X[i], Y[i], Z[i]
		local hit, d, hx, hy, hz = nav_cp(x, y, z, RT + ENGINE_SLACK)
		if hit then
			local ok, px, py, pz = nav_push(x, y, z, d, hx, hy, hz, RT + ENGINE_SLACK, 1.0, x, y, z)
			if not ok then nav_togrid(q); return true end
			X[i], Y[i], Z[i] = px, py, pz
		end
		q.ei = i + 1
	end
	q.reached = true
	nav_smoothstart(q)
	return true
end

local function nav_run(q)
	for _ = 1, 1000000 do
		if q.result then return end
		local f = STEP[q.st]
		if not f(q) then return end
	end
end

---------------------------------------------------------------------------------------------------------------
-- API

-- opts: cell 0.5, radius 0.3, margin 0.03, budget 300 (queries / frame, at least 19), work 600 (Lua work / frame,
-- ~us of LuaJIT -joff), maxNodes 6000, mask 63, weight 2, squeeze 0.15 (clearance of legs through cells marked
-- free by players), probe 1.5, probeCells 1500, floodCells 6000, sealedNodes 600, engine (false = never use the
-- engine planner), engineTicks 60, engineRadius 1, snap 1.5, horizon 40, digCost 8, maxDig 3 (m), detour 3,
-- detourMin 20, maxCells 200000.
function Nav.init(opts)
	opts = opts or {}
	CELL = opts.cell or 0.5
	RAD = opts.radius or 0.3
	MARGIN = opts.margin or 0.03
	RT = RAD + MARGIN
	PROBE = max(opts.probe or 1.5, RT)
	SQZ = opts.squeeze or 0.15
	MASK = opts.mask or 63
	BUDGET = max(opts.budget or 300, EDGECOST)  -- one edge connection must fit in a frame
	NODES_TICK = opts.work or (opts.nodesPerTick and opts.nodesPerTick * 8) or 600
	MAXNODES = opts.maxNodes or 6000
	W = opts.weight or 2
	PROBE_N = opts.probeCells or 1500
	PROBE_MAX = max(opts.floodCells or 6000, PROBE_N)
	SEALED_NODES = opts.sealedNodes or 600
	ENGINE_TICKS = opts.engineTicks or 60
	ENGINE_TR = opts.engineRadius or 1.0
	ENGINE_ON = (opts.engine ~= false) and (CreatePathPlanner ~= nil)
	SNAP = opts.snap or 1.5
	HORIZON = opts.horizon or 40
	DIG_COST = opts.digCost or 8
	MAX_DIG = floor((opts.maxDig or 3) / CELL + 0.5)
	DETOUR = opts.detour or 3
	DETOUR_MIN = opts.detourMin or 20
	GEN = floor((opts.maxCells or 200000) / 2)
	for id, q in pairs(REQ) do
		if q.eBusy and PLANNER[id] then AbortPath(PLANNER[id]) end
	end
	C1, C0, n1, n0 = nav_shards(), nav_shards(), 0, 0
	BAD, nBad = {}, 0
	GOOD, nGood = {}, 0
	REQ, ORDER = {}, {}
	ST = {queries = 0, nodes = 0, ticks = 0, lastQueries = 0, lastNodes = 0, direct = 0, swaps = 0}
	-- the cells a free probe fills: offsets within PROBE - RT, nearest first
	FK, FD = {}, {}
	local reach = PROBE - RT - FILL_MARGIN
	local R = floor(reach / CELL)
	local list = {}
	for a = -R, R do
		for b = -R, R do
			for c = -R, R do
				local d = sqrt(a * a + b * b + c * c) * CELL
				if d > 0 and d <= reach then list[#list + 1] = {d, a * S2 + b * S + c} end
			end
		end
	end
	table.sort(list, function(u, v) return u[1] < v[1] end)
	for i = 1, #list do FD[i], FK[i] = list[i][1], list[i][2] end
end

-- once per server frame
function Nav.tick()
	ST.ticks = ST.ticks + 1
	local n = #ORDER
	ST.lastQueries, ST.lastNodes = 0, 0
	if n == 0 then return end
	local ids = {}
	local s = ST.ticks % n
	for i = 1, n do
		ids[i] = ORDER[(s + i - 1) % n + 1]
		local q = REQ[ids[i]]
		if q then q.ticks = q.ticks + 1 end
	end
	local qTot, nTot = BUDGET, NODES_TICK
	for pass = 1, 2 do
		local m = 0
		for i = 1, n do
			local q = REQ[ids[i]]
			if q and not q.result then m = m + 1 end
		end
		if m == 0 or qTot < 1 or nTot <= 0 then break end
		for i = 1, n do
			local q = REQ[ids[i]]
			if q and not q.result and qTot >= 1 and nTot > 0 then
				local qs, ns = qTot, nTot
				if pass == 1 then
					qs = floor(qTot / m)
					ns = nTot / m
				end
				qLeft, nLeft = qs, ns
				CUR = q
				nav_run(q)
				CUR = nil
				qTot = qTot - (qs - qLeft)
				nTot = nTot - (ns - nLeft)
				m = m - 1
			end
		end
	end
	local keep = {}
	for i = 1, #ORDER do
		local q = REQ[ORDER[i]]
		if q and not q.result then keep[#keep + 1] = ORDER[i] end
	end
	ORDER = keep
	ST.lastQueries, ST.lastNodes = BUDGET - qTot, NODES_TICK - nTot
	qLeft, nLeft = 0, 0
end

-- start (or replace) a plan for agent id. o (optional): dig = false (no digging), engine = false | "force",
-- maxNodes = n
function Nav.request(id, from, to, o)
	Nav.cancel(id)
	o = o or {}
	local q = {
		id = id, fx = from[1], fy = from[2], fz = from[3], tx = to[1], ty = to[2], tz = to[3],
		st = "line", src = "line", queries = 0, nodesAll = 0, nodes = 0, ticks = 0, replans = 0,
		engine = o.engine, dig = o.dig, maxN = o.maxNodes or MAXNODES, maxN0 = o.maxNodes or MAXNODES, oi = 1, oh = 0, ofh = 0,
	}
	q.gx, q.gy, q.gz = q.tx / CELL - 0.5, q.ty / CELL - 0.5, q.tz / CELL - 0.5
	q.far = nav_dist(q.fx, q.fy, q.fz, q.tx, q.ty, q.tz) > HORIZON
	REQ[id] = q
	ORDER[#ORDER + 1] = id
end

-- nil while working, else {ok, partial, points, tight, digs, dig, source, far, sealed, gap, queries, nodes, ticks}:
--   points  points[1] = the request's start (unless the head was jammed into geometry: then the start cell's
--           point), the last = the goal when ok (or the free point next to it when the goal itself is too close
--           to a surface: gap > 0), else the reached cell closest to the goal
--   tight   tight[i] = true: leg i (points[i] -> points[i + 1]) is only clear by opts.squeeze (cells players
--           proved passable with markFree), every other leg by radius
--   digs    leg indices that pass through geometry (bite there first); dig = #digs > 0
--   source  "line" | "engine" | "grid";  far = a local plan toward a goal beyond the horizon (replan near its end)
--   sealed  the goal flood found the goal's region closed;  gap = distance from the last point to the goal
function Nav.result(id)
	local q = REQ[id]
	return q and q.result
end

function Nav.cancel(id)
	local q = REQ[id]
	if not q then return end
	if q.eBusy and PLANNER[id] then AbortPath(PLANNER[id]) end
	REQ[id] = nil
	for i = #ORDER, 1, -1 do
		if ORDER[i] == id then table.remove(ORDER, i) end
	end
end

-- the cached cell test for the cell holding p (tests it now when unknown): free, representative point
function Nav.free(p)
	local k, ix, iy, iz = nav_cellof(p[1], p[2], p[3])
	local v = nav_get(k)
	if v == nil then
		local save = qLeft
		v = nav_test(k, ix, iy, iz)
		qLeft = save
		ST.direct = ST.direct + 1
	end
	if not v then return false end
	return true, Vec(nav_rep(k, v))
end

-- a sphere cast (radius r, default the worm's radius) now: true when clear
function Nav.lineFree(a, b, r)
	local save = qLeft
	local c = nav_cast(a[1], a[2], a[3], b[1], b[2], b[3], r or RAD)
	qLeft = save
	return c
end

-- a player was at p: the cell holding p (and neighbours within radius of p) are passable
function Nav.markFree(p)
	local x, y, z = p[1], p[2], p[3]
	local k, ix, iy, iz = nav_cellof(x, y, z)
	if not nav_get(k) then nav_set(k, {x, y, z, true}) end
	for i = 1, 26 do
		local x0, y0, z0 = (ix + DX[i]) * CELL, (iy + DY[i]) * CELL, (iz + DZ[i]) * CELL
		local dx = max(x0 - x, 0, x - x0 - CELL)
		local dy = max(y0 - y, 0, y - y0 - CELL)
		local dz = max(z0 - z, 0, z - z0 - CELL)
		if dx * dx + dy * dy + dz * dz < RAD * RAD then
			local nk = k + DK[i]
			if not nav_get(nk) then nav_set(nk, {x, y, z, true}) end
		end
	end
end

-- geometry changed near p (a hole, an explosion): drop cached cells within r (+ the test radius)
-- a bite at p cut (next to) nothing: the cells within r are never dug into again (they stay as tested otherwise)
function Nav.markHard(p, r)
	r = r or 1
	local x, y, z = p[1], p[2], p[3]
	local _, ix, iy, iz = nav_cellof(x, y, z)
	local cr = ceil(r / CELL)
	for a = -cr, cr do
		for b = -cr, cr do
			for c = -cr, cr do
				local cx, cy, cz = (ix + a + 0.5) * CELL - x, (iy + b + 0.5) * CELL - y, (iz + c + 0.5) * CELL - z
				if cx * cx + cy * cy + cz * cz <= r * r then HARD[nav_key(ix + a, iy + b, iz + c)] = true end
			end
		end
	end
end

function Nav.forget(p, r)
	r = (r or 2) + RT + CELL
	local x, y, z = p[1], p[2], p[3]
	local _, ix, iy, iz = nav_cellof(x, y, z)
	local cr = ceil(r / CELL)
	local r2 = r * r
	if (2 * cr + 1) ^ 3 <= n1 + n0 then
		for a = -cr, cr do
			for b = -cr, cr do
				for c = -cr, cr do
					local cx, cy, cz = (ix + a + 0.5) * CELL - x, (iy + b + 0.5) * CELL - y, (iz + c + 0.5) * CELL - z
					if cx * cx + cy * cy + cz * cz <= r2 then nav_del(nav_key(ix + a, iy + b, iz + c)) end
				end
			end
		end
	else
		local all = {}
		for i = 1, NSH do all[#all + 1] = C1[i]; all[#all + 1] = C0[i] end
		for _, t in ipairs(all) do
			local drop = {}
			for k in pairs(t) do
				local a, b, c = nav_decode(k)
				local cx, cy, cz = (a + 0.5) * CELL - x, (b + 0.5) * CELL - y, (c + 0.5) * CELL - z
				if cx * cx + cy * cy + cz * cz <= r2 then drop[#drop + 1] = k end
			end
			for i = 1, #drop do nav_del(drop[i]) end
		end
	end
	BAD, nBad = {}, 0
	GOOD, nGood = {}, 0
end

function Nav.stats()
	local bad = nBad
	return {queries = ST.queries, cells = n1 + n0, nodes = ST.nodes, ticks = ST.ticks,
		lastQueries = ST.lastQueries, lastNodes = ST.lastNodes, pending = #ORDER, direct = ST.direct,
		swaps = ST.swaps, banned = bad}
end

Nav.init()
