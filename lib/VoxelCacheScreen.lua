-- Android V18: one-time persistent voxel BODY precompiler.
--
-- Heavy route/town meshes are the one thing a 120 Hz gameplay frame cannot
-- hide: build them while walking and the player feels stutter; build them at a
-- seam and they see void/2D; build them synchronously behind a door and the
-- transition freezes.  So pay that cost once, on an explicit opaque loading
-- screen, then keep the raw BODY vertex streams in LOVE's save directory.
--
-- The cache is resumable.  Every map is its own fingerprinted file; closing
-- the app halfway through simply means the next run skips what is already
-- valid and continues the missing maps.

local V = ...

local ChunkMesher = V.require("ChunkMesher")
local Budget = V.require("BuildBudget")
local Structures = V.require("Structures")

local Screen = {}
Screen.__index = Screen
Screen.isOpaque = true

local W, H = 160, 144
local MIN_AREA = 24       -- blocks; catches routes/towns/forest, skips tiny rooms
local SLICE = 0.018       -- loading-screen CPU budget per visible frame
local HOLD = 0.65

local asked = false
local active = false

local Font
local function font()
  if Font then return Font end
  local ok, F = pcall(require, "src.render.Font")
  if ok then Font = F end
  return Font
end

local function text(str, x, y)
  local F = font()
  if not F then return end
  love.graphics.setColor(0, 0, 0, 1)
  F.draw(tostring(str), math.floor(x), math.floor(y))
end

local function centred(str, y)
  local F = font()
  if not F then return end
  str = tostring(str)
  text(str, (W - F.width(str)) / 2, y)
end

local function cacheSignature()
  local vf = "trees"
  local ok, TR = pcall(require, "src.render.TileRenderer")
  if ok and TR then vf = tostring(TR.voidFill or vf) end
  return tostring(ChunkMesher.diskCacheVersion()) .. "|" .. vf
end

local function markerPath()
  return ChunkMesher.diskCacheDir() .. "/complete"
end

local function markerMatches()
  if not (love and love.filesystem) then return false end
  local ok, body = pcall(love.filesystem.read, markerPath())
  return ok and type(body) == "string" and body == cacheSignature()
end

local function writeMarker()
  pcall(love.filesystem.createDirectory, ChunkMesher.diskCacheDir())
  pcall(love.filesystem.write, markerPath(), cacheSignature())
end

local function candidateIds(game)
  local out = {}
  local maps = game and game.data and game.data.maps or {}
  for id, def in pairs(maps) do
    local w = type(def) == "table" and tonumber(def.width) or nil
    local h = type(def) == "table" and tonumber(def.height) or nil
    -- Some engine revisions leave dimensions to MapLoader. Keep those ids and
    -- decide after load rather than silently missing an outdoor map.
    if not (w and h) or w * h >= MIN_AREA then out[#out + 1] = id end
  end
  table.sort(out, function(a, b) return tostring(a) < tostring(b) end)
  return out
end

function Screen.new(game)
  return setmetatable({
    game = game,
    ids = candidateIds(game),
    index = 1,
    done = 0,
    built = 0,
    skipped = 0,
    current = nil,
    currentName = "",
    co = nil,
    hold = 0,
    finished = false,
    failed = 0,
  }, Screen)
end

function Screen:enter()
  active = true
end

local function pop(self)
  active = false
  if self.game and self.game.stack and self.game.stack:top() == self then
    self.game.stack:pop()
  end
end

local function nextMap(self)
  local MapLoader = require("src.world.MapLoader")
  while self.index <= #self.ids do
    local id = self.ids[self.index]
    self.index = self.index + 1
    local ok, map = pcall(MapLoader.load, self.game.data, id)
    if ok and map and map.def then
      local area = (tonumber(map.def.width) or 0) * (tonumber(map.def.height) or 0)
      if area >= MIN_AREA then
        self.current = map
        self.currentName = tostring(map.id or id)
        if ChunkMesher.bodyCachedOnDisk(map) then
          self.done = self.done + 1
          self.skipped = self.skipped + 1
          Structures.invalidate(map.id)
          self.current = nil
        else
          self.co = coroutine.create(function()
            return ChunkMesher.precompileBody(map)
          end)
          return true
        end
      else
        self.done = self.done + 1
      end
    else
      self.done = self.done + 1
      self.failed = self.failed + 1
    end
  end
  return false
end

function Screen:update()
  if self.finished then
    self.hold = self.hold + 1 / 60
    if self.hold >= HOLD then pop(self) end
    return
  end

  -- B/Back skips this run.  No completion marker is written, so the next boot
  -- resumes exactly where the per-map cache files left off.
  local input = self.game and self.game.input
  if input and input.wasPressed and input:wasPressed("b") then
    pop(self)
    return
  end

  if not self.co then
    if not nextMap(self) then
      if self.failed == 0 then writeMarker() end
      self.finished = true
      self.hold = 0
      return
    end
    if not self.co then return end
  end

  Budget.begin(self.co, SLICE)
  local ok, a, b = coroutine.resume(self.co)
  Budget.finish()
  if not ok then
    self.failed = self.failed + 1
    V.mod.log:warn("voxel cache: %s failed: %s", tostring(self.currentName), tostring(a))
  end

  if (not ok) or coroutine.status(self.co) == "dead" then
    if ok and a then self.built = self.built + 1 else self.failed = self.failed + (ok and 1 or 0) end
    self.done = self.done + 1
    if self.current and self.current.id then Structures.invalidate(self.current.id) end
    self.current, self.co = nil, nil
    -- Keep the loading screen's memory flat after a route-sized raw buffer was
    -- compressed/written and its Structures analysis was dropped.
    collectgarbage("step", 300)
  end
end

function Screen:onKeyPressed(key)
  if key == "escape" or key == "backspace" or key == "x" then
    pop(self)
    return true
  end
  return false
end

function Screen:draw()
  love.graphics.setColor(0.93, 0.94, 0.90, 1)
  love.graphics.rectangle("fill", 0, 0, W, H)
  centred("VOXEL CACHE", 18)
  centred("ONE-TIME SETUP", 32)

  local total = math.max(1, #self.ids)
  local frac = math.max(0, math.min(1, self.done / total))
  if self.finished then frac = 1 end
  local bx, by, bw, bh = 20, 66, 120, 9
  love.graphics.setColor(0.06, 0.05, 0.09, 1)
  love.graphics.rectangle("fill", bx - 1, by - 1, bw + 2, bh + 2)
  love.graphics.setColor(0.93, 0.94, 0.90, 1)
  love.graphics.rectangle("fill", bx, by, bw, bh)
  love.graphics.setColor(0.06, 0.05, 0.09, 1)
  love.graphics.rectangle("fill", bx, by, math.floor(bw * frac + 0.5), bh)

  if self.finished then
    if self.failed == 0 then
      centred("READY", 86)
      centred("3D MAPS CACHED", 100)
    else
      centred("CACHE PARTIAL", 86)
      centred(("%d FAILED"):format(self.failed), 100)
    end
  else
    centred(("%d/%d"):format(self.done, #self.ids), 84)
    if self.currentName ~= "" then
      local name = self.currentName
      if #name > 18 then name = name:sub(1, 18) end
      centred(name, 98)
    else
      centred("SCANNING MAPS", 98)
    end
    centred("KEEP APP OPEN", 112)
    centred("B: SKIP FOR NOW", 128)
  end
  love.graphics.setColor(1, 1, 1, 1)
end

function Screen.active() return active end

function Screen.maybePush()
  if asked then return false end
  if not ChunkMesher.diskCacheCapable() then asked = true; return false end
  local ok, Game = pcall(require, "src.core.Game")
  if not (ok and Game and Game.stack and Game.overworld) then return false end
  if Game.stack:top() ~= Game.overworld then return false end
  local okV, Voxel = pcall(V.require, "VoxelState")
  if not (okV and Voxel and Voxel.active and Voxel.active()) then return false end
  asked = true
  if markerMatches() then return false end
  Game.stack:push(Screen.new(Game))
  return true
end

function Screen._reset()
  asked, active = false, false
end

return Screen
