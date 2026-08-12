-- Headless regression coverage for the validated Android optimization shim.
-- Run from the mod repository root with:
--   luajit tests/android_optimize_test.lua

local ffi = require("ffi")

local passed = 0
local function check(value, message)
  if not value then error(message or "check failed", 2) end
end

local function eq(actual, expected, message)
  if actual ~= expected then
    error((message or "values differ") .. ": expected " .. tostring(expected)
          .. ", got " .. tostring(actual), 2)
  end
end

local function near(actual, expected, epsilon, message)
  if math.abs(actual - expected) > epsilon then
    error((message or "values differ") .. ": expected " .. tostring(expected)
          .. ", got " .. tostring(actual), 2)
  end
end

local function test(name, fn)
  local ok, err = pcall(fn)
  if not ok then
    io.stderr:write("FAIL ", name, ": ", tostring(err), "\n")
    os.exit(1)
  end
  passed = passed + 1
  io.write("ok   ", name, "\n")
end

local function newFilesystem()
  local fs = { files = {}, readOpens = {} }

  function fs.createDirectory() return true end
  function fs.write(path, body)
    fs.files[path] = body
    return true
  end
  function fs.read(path) return fs.files[path] end
  function fs.remove(path)
    fs.files[path] = nil
    return true
  end
  function fs.newFile(path)
    local file = { path = path, pos = 1 }
    function file:open(mode)
      self.pos = 1
      if mode == "w" then
        fs.files[path] = ""
      else
        fs.readOpens[#fs.readOpens + 1] = path
        if fs.files[path] == nil then return false end
      end
      return true
    end
    function file:write(body)
      fs.files[path] = (fs.files[path] or "") .. body
      return true
    end
    function file:read(bytes)
      local body = fs.files[path]
      if body == nil then return nil end
      if bytes == nil then
        local out = body:sub(self.pos)
        self.pos = #body + 1
        return out
      end
      local out = body:sub(self.pos, self.pos + bytes - 1)
      self.pos = self.pos + #out
      return out
    end
    function file:close() return true end
    return file
  end

  return fs
end

local function sourceMesh(seed)
  local mesh = { released = false }
  function mesh:getVertexCount() return 6 end
  function mesh:getVertex(i)
    return seed + i, i * 2, i * 3, i / 10, i / 20, 0.5
  end
  function mesh:release() self.released = true end
  return mesh
end

local function newChunkMesher()
  local cm = {
    requests = {}, pumps = {}, invalidates = {}, refreshes = {},
    live = {},
  }
  function cm.build()
    return sourceMesh(10), sourceMesh(20)
  end
  function cm.request(map, bodyOnly, masks, urgent)
    cm.requests[#cm.requests + 1] = {
      id = map.id, bodyOnly = bodyOnly, masks = masks, urgent = urgent,
    }
  end
  function cm.pair() return nil, nil end
  function cm.peek() return nil end
  function cm.pump(covered)
    cm.pumps[#cm.pumps + 1] = covered and true or false
  end
  function cm.setLive(live) cm.live = live end
  function cm.invalidate(mapId)
    cm.invalidates[#cm.invalidates + 1] = mapId or "*"
  end
  function cm.refresh(mapId)
    cm.refreshes[#cm.refreshes + 1] = mapId
  end
  return cm
end

local function map(id, ox)
  local tiles = {}
  for i = 1, 16 do tiles[i] = i + (ox or 0) end
  local m = {
    id = id,
    def = { width = 1, height = 1, tileset = "OVERWORLD" },
    tileset = { id = "OVERWORLD" },
    tiles = tiles,
  }
  function m:tileAt(x, y) return self.tiles[y * 4 + x + 1] end
  return m
end

local function install(options)
  options = options or {}
  local fs = options.fs or newFilesystem()
  local now = options.now or { value = 0 }
  local slices = {}
  local created = {}
  local tileRenderer = options.tileRenderer or { voidFill = "trees" }
  local structures = { invalidates = {} }
  function structures.invalidate(id)
    structures.invalidates[#structures.invalidates + 1] = id or "*"
  end
  local budget = {}
  function budget.begin(_, slice) slices[#slices + 1] = slice end
  function budget.finish() end
  function budget.check() end

  local graphics = {}
  function graphics.newMesh(_, count)
    local mesh = { count = count, uploads = {}, released = false }
    function mesh:setVertices(data, at)
      self.uploads[#self.uploads + 1] = { bytes = data.bytes, at = at }
    end
    function mesh:release() self.released = true end
    created[#created + 1] = mesh
    return mesh
  end

  local data = {}
  -- Deliberately larger than raw: exercises the validated raw fallback.
  function data.compress(container, codec, raw) return raw .. "x" end
  function data.decompress(container, codec, raw) return raw end
  function data.newByteData(bytes)
    local storage = ffi.new("uint8_t[?]", bytes)
    return {
      bytes = bytes,
      getFFIPointer = function() return storage end,
      release = function() end,
    }
  end

  _G.love = {
    system = { getOS = function() return options.os or "Android" end },
    timer = { getTime = function() return now.value end },
    filesystem = fs,
    graphics = graphics,
    data = data,
  }
  package.loaded["src.render.TileRenderer"] = tileRenderer
  package.loaded["src.core.Game"] = options.game

  local cacheScreen = options.cacheScreen or {
    maybePush = function() return false end,
    active = function() return false end,
  }
  local shadowMap = options.shadowMap or {
    SIZES = { 1024, 1536, 2048 }, TARGET = 0.45, res = 1024,
    stale = function() return false end,
    finish = function() end,
    invalidate = function() end,
  }
  local voxel = options.voxel or { ready = false }
  local modules = {
    BuildBudget = budget,
    Voxel3D = { FORMAT = { { "VertexPosition", "float", 3 } } },
    Structures = structures,
    VoxelCacheScreen = cacheScreen,
    ShadowMap = shadowMap,
  }
  local V = {
    mod = { log = { info = function() end, warn = function() end } },
  }
  function V.require(name)
    local value = modules[name]
    if value == nil then error("unexpected V.require: " .. tostring(name)) end
    return value
  end

  local cm = options.chunkMesher or newChunkMesher()
  local optimizer = assert(loadfile("lib/AndroidOptimize.lua"))(V)
  optimizer.install(cm, {}, voxel)
  return {
    cm = cm, fs = fs, now = now, slices = slices, created = created,
    tileRenderer = tileRenderer, structures = structures, voxel = voxel,
    shadowMap = shadowMap,
  }
end

test("entry shim injects the optimizer without replacing upstream main", function()
  local installs = 0
  local V = {}
  function V.require(name)
    if name == "AndroidOptimize" then
      return { install = function() installs = installs + 1 end }
    end
    return { name = name }
  end
  local source = [[
local mod = ...
local V = mod.V
local VoxelScene = V.require("VoxelScene")
local Voxel = V.require("VoxelState")
local ChunkMesher = V.require("ChunkMesher")
local ViewBox = V.require("ViewBox")
local SettingsMenu = V.require("SettingsMenu")
local LetsGo = V.require("LetsGo")
local Shiny = V.require("Shiny")
return ChunkMesher.name
]]
  local mod = { V = V, path = "test-mod", read = function() return source end }
  local result = assert(loadfile("android_main.lua"))(mod)
  eq(result, "ChunkMesher", "upstream main result")
  eq(installs, 1, "optimizer injection count")
end)

test("desktop path is unchanged", function()
  local cm = newChunkMesher()
  local request, pump = cm.request, cm.pump
  local shadow = { SIZES = { 1024, 1536, 2048 }, TARGET = 0.45, res = 1024 }
  install({ os = "Windows", chunkMesher = cm, shadowMap = shadow })
  eq(cm.request, request, "desktop request")
  eq(cm.pump, pump, "desktop pump")
  eq(cm.diskCacheCapable, nil, "desktop cache API")
  eq(shadow.SIZES[1], 1024, "desktop shadow ladder")
  eq(shadow.TARGET, 0.45, "desktop shadow target")
end)

test("BODY cache fingerprint, header, invalidation, and restart", function()
  local ctx = install()
  local m = map("MAP A")
  local ok, status = ctx.cm.precompileBody(m)
  check(ok and status == nil, "first precompile")

  local dir = "dramatic_shape/voxel_cache_182a1"
  local terrainPath = dir .. "/MAP_A_body.dsvc"
  local waterPath = dir .. "/MAP_A_body_water.dsvc"
  local markerPath = dir .. "/MAP_A_body.ok"
  local marker1 = ctx.fs.files[markerPath]
  check(marker1 and #marker1 == 8, "fingerprint marker")
  check(ctx.cm.bodyCachedOnDisk(m), "fresh cache hit")
  check(ctx.fs.files[waterPath], "water cache exists")

  local head = ctx.fs.files[terrainPath]:sub(1, 64)
  eq(#head, 64, "fixed header size")
  check(head:match("^DSVC|182a1|0000000006|" .. marker1 .. "|000001\n"),
        "versioned cache header")
  eq(ctx.fs.files[terrainPath]:sub(65, 65), "R", "raw fallback record")

  ctx.cm.invalidate(m.id)
  check(ctx.cm.bodyCachedOnDisk(m), "stable fingerprint after invalidation")
  eq(ctx.fs.files[markerPath], marker1, "stable marker")

  m.tiles[1] = m.tiles[1] + 1
  ctx.cm.refresh(m.id)
  check(not ctx.cm.bodyCachedOnDisk(m), "tile edit invalidates disk hit")
  check(ctx.cm.precompileBody(m), "recompile edited map")
  local marker2 = ctx.fs.files[markerPath]
  check(marker2 ~= marker1, "tile edit changes fingerprint")

  local restarted = install({ fs = ctx.fs, tileRenderer = ctx.tileRenderer })
  check(restarted.cm.bodyCachedOnDisk(m), "cache survives module restart")
  restarted.tileRenderer.voidFill = "water"
  restarted.cm.refresh(m.id)
  check(not restarted.cm.bodyCachedOnDisk(m), "void-fill invalidates disk hit")
end)

test("current, facing, nearest, and other disk jobs keep validated budgets", function()
  local current = map("CURRENT", 0)
  local nearest = map("NEAREST", 20)
  local other = map("OTHER", 40)
  local front = map("FRONT", 60)
  local cold = map("COLD", 80)
  local ow = {
    map = current,
    player = { px = 16, py = 16, facing = "right", moving = true },
    neighbors = {
      { map = nearest, ox = 0, oy = -32 },
      { map = other, ox = -32, oy = 0 },
      { map = front, ox = 32, oy = 0 },
    },
    transitioning = false,
  }
  local game = { overworld = ow }
  local ctx = install({ game = game })
  for _, m in ipairs({ current, nearest, other, front }) do
    check(ctx.cm.precompileBody(m), "precompile " .. m.id)
  end

  ctx.cm.request(current, false, nil, true)
  ctx.cm.request(nearest, true)
  ctx.cm.request(other, true)
  ctx.cm.request(front, true)
  ctx.fs.readOpens = {}
  ctx.slices = ctx.slices

  ctx.cm.pump(false)
  check(ctx.fs.readOpens[1]:find("CURRENT_body.dsvc", 1, true),
        "current map loads first")
  near(ctx.slices[#ctx.slices], 0.00060, 1e-9, "walking cached budget")
  eq(#ctx.cm.pumps, 0, "FULL build does not race current disk BODY")
  local currentBody = ctx.cm.pair(current, true)
  check(currentBody ~= nil, "current cached BODY is drawable")

  ctx.voxel.ready = true
  ctx.fs.readOpens = {}
  ctx.cm.pump(false)
  check(ctx.fs.readOpens[1]:find("FRONT_body.dsvc", 1, true),
        "facing neighbour precedes nearer frontier")
  near(ctx.slices[#ctx.slices], 0.00060, 1e-9, "facing walking budget")

  ow.player.moving = false
  ctx.now.value = 0.5
  ctx.fs.readOpens = {}
  ctx.cm.pump(false)
  check(ctx.fs.readOpens[1]:find("NEAREST_body.dsvc", 1, true),
        "nearest frontier follows facing neighbour")
  near(ctx.slices[#ctx.slices], 0.003, 1e-9, "idle cached budget")

  ow.transitioning = true
  ctx.fs.readOpens = {}
  ctx.cm.pump(false)
  check(ctx.fs.readOpens[1]:find("OTHER_body.dsvc", 1, true),
        "remaining cached neighbour follows")
  near(ctx.slices[#ctx.slices], 0.030, 1e-9, "transition cached budget")
  eq(ctx.cm.pumps[#ctx.cm.pumps], true, "overworld.transitioning is covered")

  ow.transitioning = false
  ow.player.moving = true
  ctx.cm.request(cold, true)
  local before = #ctx.cm.pumps
  ctx.cm.pump(false)
  eq(#ctx.cm.pumps, before, "cold heavy work pauses while walking")
  ow.player.moving = false
  ctx.now.value = 1.0
  ctx.cm.pump(false)
  eq(#ctx.cm.pumps, before + 1, "cold heavy work resumes while idle")
end)

test("one-time cache resumes and writes complete only after a clean pass", function()
  local fs = newFilesystem()
  local cached, builds = {}, {}
  local cm = {}
  function cm.diskCacheCapable() return true end
  function cm.diskCacheDir() return "dramatic_shape/voxel_cache_182a1" end
  function cm.diskCacheVersion() return "182a1" end
  function cm.bodyCachedOnDisk(m) return cached[m.id] == true end
  function cm.precompileBody(m)
    builds[m.id] = (builds[m.id] or 0) + 1
    cached[m.id] = true
    return true
  end
  local budget = { begin = function() end, finish = function() end }
  local structures = { invalidate = function() end }
  local voxel = { active = function() return true end }
  local maps = { A = map("A"), B = map("B") }
  maps.A.def.width, maps.A.def.height = 6, 4
  maps.B.def.width, maps.B.def.height = 8, 4
  local overworld = {}
  local stack = { items = { overworld } }
  function stack:top() return self.items[#self.items] end
  function stack:push(value) self.items[#self.items + 1] = value; value:enter() end
  function stack:pop() table.remove(self.items) end
  local skip = false
  local game = {
    data = { maps = { A = maps.A.def, B = maps.B.def } },
    overworld = overworld,
    stack = stack,
    input = { wasPressed = function(_, key) return key == "b" and skip end },
  }

  _G.love = {
    filesystem = fs,
    graphics = { setColor = function() end, rectangle = function() end },
  }
  package.loaded["src.render.TileRenderer"] = { voidFill = "trees" }
  package.loaded["src.core.Game"] = game
  package.loaded["src.world.MapLoader"] = {
    load = function(_, id) return maps[id] end,
  }
  local modules = {
    ChunkMesher = cm, BuildBudget = budget, Structures = structures,
    VoxelState = voxel,
  }
  local V = { mod = { log = { warn = function() end } } }
  function V.require(name) return assert(modules[name], name) end
  local Screen = assert(loadfile("lib/VoxelCacheScreen.lua"))(V)

  check(Screen.maybePush(), "initial prebuild screen")
  local first = stack:top()
  first:update()
  eq(builds.A, 1, "first map built")
  skip = true
  first:update()
  eq(stack:top(), overworld, "B/Back defers setup")
  eq(fs.files[cm.diskCacheDir() .. "/complete"], nil,
     "interrupted pass has no global marker")

  skip = false
  Screen._reset()
  check(Screen.maybePush(), "resumed prebuild screen")
  local resumed = stack:top()
  for _ = 1, 8 do
    resumed:update()
    if resumed.finished then break end
  end
  check(resumed.finished, "resumed pass finishes")
  eq(builds.A, 1, "valid map skipped on resume")
  eq(builds.B, 1, "missing map built on resume")
  eq(fs.files[cm.diskCacheDir() .. "/complete"], "182a1|trees",
     "complete marker written after clean pass")
end)

test("Android shadow ladder and 1/90 second pacing match the validated build", function()
  local now = { value = 1 }
  local game = { overworld = { map = { id = "MAP_A" } } }
  local oldFinish, oldInvalidate = 0, 0
  local shadow = {
    SIZES = { 1024, 1536, 2048 }, TARGET = 0.45, res = 1024,
    stale = function() return true end,
    finish = function() oldFinish = oldFinish + 1; return "finished" end,
    invalidate = function() oldInvalidate = oldInvalidate + 1 end,
  }
  install({ now = now, game = game, shadowMap = shadow })
  eq(shadow.SIZES[1], 768, "Android shadow ladder first rung")
  eq(shadow.SIZES[2], 1024, "Android shadow ladder second rung")
  eq(shadow.SIZES[3], 1536, "Android shadow ladder third rung")
  eq(shadow.TARGET, 0.60, "Android shadow target")
  eq(shadow.res, 768, "Android initial shadow resolution")

  eq(shadow.finish("base"), "finished", "wrapped finish result")
  eq(oldFinish, 1, "original finish called")
  now.value = 1.005
  check(not shadow.stale("motion"), "same-map high-refresh pass throttled")
  now.value = 1.020
  check(shadow.stale("motion"), "same-map pass resumes after 1/90 second")
  now.value = 1.006
  game.overworld.map = { id = "MAP_B" }
  check(shadow.stale("map-change"), "map changes bypass throttle")
  shadow.invalidate()
  eq(oldInvalidate, 1, "original invalidate called")
end)

io.write(("PASS %d Android optimization tests\n"):format(passed))
