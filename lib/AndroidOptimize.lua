-- Android performance layer for Dramatic Shape 1.8.2.
--
-- Deliberately implemented as wrappers around the official public ChunkMesher
-- API.  The 1.8.2 geometry builders therefore remain authoritative: new door,
-- wall, prop, Stadium, Let's Go, ViewBox, and other upstream geometry changes
-- are never replaced by the older 1.7.x Android fork.
--
-- What this adds on Android:
--   * resumable persistent BODY cache in LOVE's save directory;
--   * LZ4-compressed independent vertex chunks, streamed incrementally;
--   * current/facing/nearest cached-neighbour upload priority;
--   * no heavy live meshing while normal walking is already fully 3D;
--   * transition frames count as covered work time;

local V = ...

local M = {}
local installed = false

local function isAndroid()
  return love and love.system and love.system.getOS
         and love.system.getOS() == "Android"
end

local ffi = nil
do
  local ok, f = pcall(require, "ffi")
  if ok then ffi = f end
end

local clock = (love and love.timer and love.timer.getTime) or os.clock
local Budget = V.require("BuildBudget")
local Voxel3D = V.require("Voxel3D")
local Structures = V.require("Structures")

local CACHE_VERSION = "182a1"
local CACHE_DIR = "dramatic_shape/voxel_cache_" .. CACHE_VERSION
local HEADER_BYTES = 64
local CACHE_CHUNK_VERTS = 8192
local VERTEX_FLOATS = 6
local VERTEX_BYTES = VERTEX_FLOATS * 4

local originals = {}
local ext = {}          -- map id -> { fp, mapRef, body, water }

local statusMemo = {}   -- map id -> { mapRef, fp, hit }
local jobs = {}         -- disk BODY pair loads only
local jobsById = {}
local prevLive = {}

local function safeId(id)
  return tostring(id):gsub("[^%w_%-]", "_")
end

local function bodyPath(map, water)
  return CACHE_DIR .. "/" .. safeId(map.id)
         .. (water and "_body_water.dsvc" or "_body.dsvc")
end

local function okPath(map)
  return CACHE_DIR .. "/" .. safeId(map.id) .. "_body.ok"
end

local function capable()
  return isAndroid() and ffi and love and love.filesystem
         and love.filesystem.write and love.filesystem.read
         and love.filesystem.newFile and love.graphics and love.graphics.newMesh
         and love.data and love.data.newByteData
end

local function ensureDir()
  if not capable() then return false end
  local ok = pcall(love.filesystem.createDirectory, CACHE_DIR)
  return ok
end

-- Deterministic hash of the live map data the BODY build consumes.  Runtime
-- block edits therefore invalidate a pristine disk entry without deleting it.
local function mapFingerprint(map)
  if not (map and map.def and map.tileAt) then return "0" end
  local h = 5381
  local function add(v)
    h = (h * 65599 + (tonumber(v) or 0) + 257) % 4294967296
  end
  add(map.def.width); add(map.def.height)
  local ts = tostring((map.tileset and map.tileset.id) or map.def.tileset or "?")
  for i = 1, #ts do add(ts:byte(i)) end
  local okTR, TileRenderer = pcall(require, "src.render.TileRenderer")
  local vf = okTR and TileRenderer and tostring(TileRenderer.voidFill or "trees") or "trees"
  for i = 1, #vf do add(vf:byte(i)) end
  local tw = (map.def.width or 0) * 4
  local th = (map.def.height or 0) * 4
  for y = 0, th - 1 do
    for x = 0, tw - 1 do
      local ok, tile = pcall(map.tileAt, map, x, y)
      add(ok and tile or 0)
    end
  end
  return string.format("%08x", h)
end

local function fixedHeader(n, fp, chunks)
  local core = ("DSVC|%s|%010d|%s|%06d\n"):format(
      CACHE_VERSION, n, fp, chunks)
  if #core > HEADER_BYTES then return nil end
  return core .. string.rep(" ", HEADER_BYTES - #core)
end

local function parseHeader(head)
  if type(head) ~= "string" or #head < HEADER_BYTES then return nil end
  local ver, count, fp, chunks = head:match(
      "^DSVC|([^|]+)|(%d+)|([0-9a-fA-F]+)|(%d+)\n")
  if ver ~= CACHE_VERSION then return nil end
  return tonumber(count), fp and fp:lower() or nil, tonumber(chunks)
end

local function openFile(path, mode)
  local ok, f = pcall(love.filesystem.newFile, path)
  if not ok or not f then return nil end
  local okOpen, opened = pcall(f.open, f, mode)
  if not okOpen or opened == false then return nil end
  return f
end

local function readHeader(path)
  if not capable() then return nil end
  local f = openFile(path, "r")
  if not f then return nil end
  local ok, head = pcall(f.read, f, HEADER_BYTES)
  pcall(f.close, f)
  return ok and type(head) == "string" and head or nil
end

local function fileMatches(path, fp)
  local n, got, chunks = parseHeader(readHeader(path))
  return n ~= nil and chunks ~= nil and got == tostring(fp):lower()
end

local function releaseMesh(mesh)
  if mesh and mesh.release then pcall(mesh.release, mesh) end
end

local function releaseExt(id)
  local e = ext[id]
  if not e then return end
  releaseMesh(e.body)
  releaseMesh(e.water)
  ext[id] = nil
end

local function diskStatus(map)
  if not (capable() and map and map.id) then return false, nil end
  local memo = statusMemo[map.id]
  if memo and memo.mapRef == map then return memo.hit, memo.fp end

  local fp = mapFingerprint(map)
  local markerOk = false
  local okM, marker = pcall(love.filesystem.read, okPath(map))
  if okM and type(marker) == "string" and marker == fp then markerOk = true end
  local hit = markerOk
              and fileMatches(bodyPath(map, false), fp)
              and fileMatches(bodyPath(map, true), fp)
  statusMemo[map.id] = { mapRef = map, fp = fp, hit = hit and true or false }
  return hit, fp
end

local function writeMesh(path, mesh, fp)
  if not ensureDir() then return false end
  local n = mesh and mesh:getVertexCount() or 0
  local chunks = (n == 0) and 0 or math.ceil(n / CACHE_CHUNK_VERTS)
  local head = fixedHeader(n, fp, chunks)
  if not head then return false end
  local f = openFile(path, "w")
  if not f then return false end

  local ok, err = pcall(function()
    assert(f:write(head) ~= false)
    local at = 1
    while at <= n do
      local count = math.min(CACHE_CHUNK_VERTS, n - at + 1)
      local buf = ffi.new("float[?]", count * VERTEX_FLOATS)
      local p = 0
      for i = 0, count - 1 do
        local x, y, z, u, v, shade = mesh:getVertex(at + i)
        buf[p] = x or 0;         buf[p + 1] = y or 0
        buf[p + 2] = z or 0;     buf[p + 3] = u or 0
        buf[p + 4] = v or 0;     buf[p + 5] = shade or 1
        p = p + VERTEX_FLOATS
        if i % 256 == 255 then Budget.check() end
      end
      local raw = ffi.string(buf, count * VERTEX_BYTES)
      local mode, payload = "R", raw
      if love.data and love.data.compress then
        local okC, packed = pcall(love.data.compress, "string", "lz4", raw)
        if okC and type(packed) == "string" and #packed < #raw then
          mode, payload = "L", packed
        end
      end
      assert(f:write(mode .. string.format("%08x", #payload)) ~= false)
      assert(f:write(payload) ~= false)
      at = at + count
      Budget.check()
    end
  end)
  pcall(f.close, f)
  if not ok then
    pcall(love.filesystem.remove, path)
    return false, err
  end
  return true
end

local function loadMesh(path, expectedFp)
  local f = openFile(path, "r")
  if not f then return false, nil end
  local okH, head = pcall(f.read, f, HEADER_BYTES)
  if not okH then pcall(f.close, f); return false, nil end
  local n, fp, chunks = parseHeader(head)
  if n == nil or fp ~= tostring(expectedFp):lower() then
    pcall(f.close, f)
    return false, nil
  end
  if n == 0 then pcall(f.close, f); return true, nil end

  local mesh = nil
  local ok, err = pcall(function()
    mesh = love.graphics.newMesh(Voxel3D.FORMAT, n, "triangles", "static")
    local at = 0
    for _ = 1, chunks do
      local rec = f:read(9)
      assert(type(rec) == "string" and #rec == 9)
      local mode = rec:sub(1, 1)
      local packedBytes = tonumber(rec:sub(2, 9), 16)
      assert((mode == "R" or mode == "L") and packedBytes)
      local payload = f:read(packedBytes)
      assert(type(payload) == "string" and #payload == packedBytes)
      local raw = payload
      if mode == "L" then
        raw = love.data.decompress("string", "lz4", payload)
      end
      local count = math.min(CACHE_CHUNK_VERTS, n - at)
      local bytes = count * VERTEX_BYTES
      assert(type(raw) == "string" and #raw == bytes)
      local data = love.data.newByteData(bytes)
      ffi.copy(data:getFFIPointer(), raw, bytes)
      mesh:setVertices(data, at + 1)
      data:release()
      at = at + count
      Budget.check()
    end
    assert(at == n)
  end)
  pcall(f.close, f)
  if not ok then
    releaseMesh(mesh)
    return false, nil, err
  end
  return true, mesh
end

local function precompileBody(ChunkMesher, map)
  if not (capable() and map and map.id) then return false, "unsupported" end
  local hit, fp = diskStatus(map)
  if hit then return true, "cached" end
  ensureDir()

  -- Official 1.8.2's build() remains the source of truth.  It uses the current
  -- FFI geometry sink and therefore includes every upstream geometry fix.
  local terrain, water = ChunkMesher.build(map, true, nil, true)
  local okT, errT = writeMesh(bodyPath(map, false), terrain, fp)
  local okW, errW = writeMesh(bodyPath(map, true), water, fp)
  releaseMesh(terrain)
  releaseMesh(water)
  if not (okT and okW) then
    pcall(love.filesystem.remove, bodyPath(map, false))
    pcall(love.filesystem.remove, bodyPath(map, true))
    pcall(love.filesystem.remove, okPath(map))
    return false, errT or errW or "write failed"
  end
  local okMarker, wrote = pcall(love.filesystem.write, okPath(map), fp)
  if not okMarker or wrote == false then return false, "marker write failed" end
  statusMemo[map.id] = { mapRef = map, fp = fp, hit = true }
  return true
end

local function queueDisk(map)
  local hit, fp = diskStatus(map)
  if not hit then return false end
  local e = ext[map.id]
  if e and e.fp == fp and e.mapRef == map and e.body ~= nil then return true end
  local j = jobsById[map.id]
  if j then
    j.map = map
    j.fp = fp
    return true
  end
  j = { id = map.id, map = map, fp = fp }
  jobsById[map.id] = j
  jobs[#jobs + 1] = j
  return true
end

local function finishDiskJob(job)
  if jobsById[job.id] == job then jobsById[job.id] = nil end
  for i = #jobs, 1, -1 do
    if jobs[i] == job then table.remove(jobs, i); break end
  end
end

local function runDiskJob(job)
  local okT, terrain = loadMesh(bodyPath(job.map, false), job.fp)
  if not okT then return false, "terrain cache read failed" end
  local okW, water = loadMesh(bodyPath(job.map, true), job.fp)
  if not okW then
    releaseMesh(terrain)
    return false, "water cache read failed"
  end
  if job.cancelled then
    releaseMesh(terrain)
    releaseMesh(water)
    return false, "cancelled"
  end
  releaseExt(job.id)
  ext[job.id] = { fp = job.fp, mapRef = job.map, body = terrain, water = water }
  return true
end

local moveProbe = { map = nil, x = nil, y = nil, last = -math.huge }
local MOVE_GRACE = 0.18
local function moving(ow)
  local p = ow and ow.player
  if not (p and ow.map) then
    moveProbe.map, moveProbe.x, moveProbe.y = nil, nil, nil
    moveProbe.last = -math.huge
    return false
  end
  local same = moveProbe.map == ow.map.id
  local moved = same and moveProbe.x ~= nil
                and (p.px ~= moveProbe.x or p.py ~= moveProbe.y)
  local nowMoving = p.moving == true or moved
  if nowMoving then moveProbe.last = clock() end
  moveProbe.map, moveProbe.x, moveProbe.y = ow.map.id, p.px, p.py
  return nowMoving or (same and (clock() - moveProbe.last) < MOVE_GRACE)
end

local function priorities(ow)
  local pmap = {}
  if not (ow and ow.map) then return pmap end
  pmap[ow.map.id] = 100
  local list = ow.neighbors or {}
  if #list == 0 then return pmap end

  local player = ow.player
  local nearest, nearestD2 = nil, math.huge
  local front, frontScore = nil, -math.huge
  local fx, fy = 0, 0
  local facing = player and player.facing
  if facing == "up" then fy = -1
  elseif facing == "down" then fy = 1
  elseif facing == "left" then fx = -1
  elseif facing == "right" then fx = 1 end

  local cw = (ow.map.def.width or 0) * 32
  local ch = (ow.map.def.height or 0) * 32
  local ccx, ccy = cw * 0.5, ch * 0.5
  for i, nb in ipairs(list) do
    pmap[nb.map.id] = math.max(pmap[nb.map.id] or 0, 2)
    if player then
      local x1, y1 = nb.ox, nb.oy
      local x2 = x1 + (nb.map.def.width or 0) * 32
      local y2 = y1 + (nb.map.def.height or 0) * 32
      local dx = (player.px < x1 and x1 - player.px)
                 or (player.px > x2 and player.px - x2) or 0
      local dy = (player.py < y1 and y1 - player.py)
                 or (player.py > y2 and player.py - y2) or 0
      local d2 = dx * dx + dy * dy
      if d2 < nearestD2 then nearest, nearestD2 = i, d2 end
      if fx ~= 0 or fy ~= 0 then
        local ncx = nb.ox + (nb.map.def.width or 0) * 16
        local ncy = nb.oy + (nb.map.def.height or 0) * 16
        local vx, vy = ncx - ccx, ncy - ccy
        local len = math.sqrt(vx * vx + vy * vy)
        if len > 0 then
          local score = (vx * fx + vy * fy) / len
          if score > frontScore then front, frontScore = i, score end
        end
      end
    end
  end
  if nearest and list[nearest] then pmap[list[nearest].map.id] = 4 end
  if front and frontScore > 0.20 and list[front] then pmap[list[front].map.id] = 6 end
  return pmap
end

local function pickDiskJob(ow)
  if #jobs == 0 then return nil end
  local prio = priorities(ow)
  local pick, best = jobs[1], -math.huge
  for _, j in ipairs(jobs) do
    local v = prio[j.id] or 1
    if v > best then pick, best = j, v end
  end
  return pick
end

local function pumpDisk(ow, covered, isMoving)
  local job = pickDiskJob(ow)
  if not job then return false end
  if not job.co then
    job.co = coroutine.create(function()
      local ok, err = runDiskJob(job)
      return ok, err
    end)
  end
  local slice = covered and 0.030 or (isMoving and 0.00060 or 0.003)
  Budget.begin(job.co, slice)
  local ok, a, b = coroutine.resume(job.co)
  Budget.finish()
  if not ok then
    statusMemo[job.id] = { mapRef = job.map, fp = job.fp, hit = false }
    pcall(love.filesystem.remove, okPath(job.map))
    finishDiskJob(job)
    return true
  end
  if coroutine.status(job.co) == "dead" then
    if not a and not job.cancelled then
      statusMemo[job.id] = { mapRef = job.map, fp = job.fp, hit = false }
      pcall(love.filesystem.remove, okPath(job.map))
    end
    finishDiskJob(job)
  end
  return true
end

function M.install(ChunkMesher, VoxelScene, Voxel)
  if installed then return end
  installed = true
  if not isAndroid() then return end

  originals.request = ChunkMesher.request
  originals.pair = ChunkMesher.pair
  originals.peek = ChunkMesher.peek
  originals.pump = ChunkMesher.pump
  originals.setLive = ChunkMesher.setLive
  originals.invalidate = ChunkMesher.invalidate
  originals.refresh = ChunkMesher.refresh

  ChunkMesher.diskCacheCapable = capable
  ChunkMesher.diskCacheDir = function() return CACHE_DIR end
  ChunkMesher.diskCacheVersion = function() return CACHE_VERSION end
  ChunkMesher.bodyCachedOnDisk = function(map)
    local hit = diskStatus(map)
    return hit and true or false
  end
  ChunkMesher.precompileBody = function(map)
    return precompileBody(ChunkMesher, map)
  end

  -- A FULL request still goes to upstream, but also starts the cheaper cached
  -- BODY immediately when available.  This is enough to make official
  -- VoxelScene.prefetch() fall through from pair(full) to our pair(body)
  -- without replacing any 1.8.2 scene code.
  ChunkMesher.request = function(map, bodyOnly, masks, urgent, ...)
    local onDisk = queueDisk(map)
    if bodyOnly and onDisk then
      local e = ext[map.id]
      return e and e.body or nil
    end
    return originals.request(map, bodyOnly, masks, urgent, ...)
  end

  ChunkMesher.pair = function(map, bodyOnly)
    local a, b = originals.pair(map, bodyOnly)
    if a or not bodyOnly then return a, b end
    local memo = statusMemo[map.id]
    local e = ext[map.id]
    if memo and memo.mapRef == map and e and e.fp == memo.fp and e.mapRef == map then
      return e.body, e.water
    end
    return nil, nil
  end

  ChunkMesher.peek = function(map, bodyOnly)
    local m = originals.peek(map, bodyOnly)
    if m or not bodyOnly then return m end
    local memo = statusMemo[map.id]
    local e = ext[map.id]
    if memo and memo.mapRef == map and e and e.fp == memo.fp and e.mapRef == map then
      return e.body
    end
    return nil
  end

  ChunkMesher.setLive = function(live)
    originals.setLive(live)
    for id in pairs(ext) do
      if not live[id] and not prevLive[id] then releaseExt(id) end
    end
    for i = #jobs, 1, -1 do
      local j = jobs[i]
      if not live[j.id] and not prevLive[j.id] then
        if j.co then
          j.cancelled = true
          if jobsById[j.id] == j then jobsById[j.id] = nil end
        else
          if jobsById[j.id] == j then jobsById[j.id] = nil end
          table.remove(jobs, i)
        end
      end
    end
    prevLive = live
  end

  ChunkMesher.invalidate = function(mapId)
    if mapId then
      releaseExt(mapId)
      statusMemo[mapId] = nil
      local j = jobsById[mapId]
      if j then
        if j.co then
          j.cancelled = true
          jobsById[mapId] = nil
        else
          finishDiskJob(j)
        end
      end
    else
      for id in pairs(ext) do releaseExt(id) end
      ext, statusMemo = {}, {}
      jobs, jobsById = {}, {}
      prevLive = {}
    end
    return originals.invalidate(mapId)
  end

  ChunkMesher.refresh = function(mapId)
    if mapId then
      releaseExt(mapId)
      statusMemo[mapId] = nil
      local j = jobsById[mapId]
      if j then
        if j.co then
          j.cancelled = true
          jobsById[mapId] = nil
        else
          finishDiskJob(j)
        end
      end
    end
    return originals.refresh(mapId)
  end

  local CacheScreen = V.require("VoxelCacheScreen")
  ChunkMesher.pump = function(covered, ...)
    local okG, Game = pcall(require, "src.core.Game")
    local ow = okG and Game and Game.overworld or nil
    covered = (covered or (ow and ow.transitioning)) and true or false

    -- First activation: move expensive map compilation to its own opaque,
    -- resumable screen.  Do not let the ordinary runtime queue compete with it.
    if CacheScreen.maybePush() or CacheScreen.active() then return end

    local isMoving = not covered and moving(ow)
    pumpDisk(ow, covered, isMoving)

    -- If the CURRENT map is coming from disk, never race that cheap upload
    -- against an upstream live FULL build.  The next prefetch sees the loaded
    -- BODY and flips Voxel.ready; only then may hidden/idle refinement resume.
    if ow and ow.map and not (Voxel and Voxel.ready) then
      local j = jobsById[ow.map.id]
      local e = ext[ow.map.id]
      if j or (e and e.body) then return end
    end

    -- Once terrain is visible, live geometry generation is background work on
    -- Android and waits for idle/covered time. Cached BODY uploads remain safe
    -- during walking because they are chunked and tightly budgeted above.
    if isMoving and Voxel and Voxel.ready then return end

    return originals.pump(covered, ...)
  end

  pcall(function()
    if V.mod and V.mod.log and V.mod.log.info then
      V.mod.log:info("Android optimizer active: persistent BODY cache %s", CACHE_VERSION)
    end
  end)
end

return M
