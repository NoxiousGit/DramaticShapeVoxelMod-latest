-- Dramatic Shape 1.8.2 Android optimization shim.
--
-- Keep upstream main.lua byte-for-byte intact.  This entry loads it and
-- injects one module install immediately after ChunkMesher is created, so the
-- Android patch rides the official 1.8.2 module graph instead of replacing it.

local mod = ...
local source = mod:read("main.lua")
if not source then
  error("DRAMATIC_SHAPE Android patch: main.lua is missing", 0)
end

-- Refuse an obviously wrong/old base instead of silently grafting the patch
-- onto the 1.7.x tree it was originally developed against.
local expected = {
  'local ViewBox = V.require("ViewBox")',
  'local SettingsMenu = V.require("SettingsMenu")',
  'local LetsGo = V.require("LetsGo")',
  'local Shiny = V.require("Shiny")',
}
for _, needle in ipairs(expected) do
  if not source:find(needle, 1, true) then
    error("DRAMATIC_SHAPE Android patch: this overlay requires official 1.8.2", 0)
  end
end

local anchor = 'local ChunkMesher = V.require("ChunkMesher")'
local a, b = source:find(anchor, 1, true)
if not a then
  error("DRAMATIC_SHAPE Android patch: ChunkMesher anchor not found", 0)
end

local injection = '\nV.require("AndroidOptimize").install(ChunkMesher, VoxelScene, Voxel)'
source = source:sub(1, b) .. injection .. source:sub(b + 1)

local chunk, err = load(source, "@" .. mod.path .. "/main.lua")
if not chunk then
  error("DRAMATIC_SHAPE Android patch: patched main.lua did not compile: " .. tostring(err), 0)
end
return chunk(mod)
