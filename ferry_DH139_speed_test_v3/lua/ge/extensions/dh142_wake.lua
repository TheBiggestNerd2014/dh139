-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Foam left behind the DH-142. BeamNG's water surface does not keep a
-- wave, so each patch is its own emitter that sits on the water, spreads,
-- and fades. The datablocks are created here and never replace the game's
-- particle files.

local M = {}

local patches = {}
local ready = false
local nextId = 0
local MAX_PATCHES = 72
local LIFE_MS = 22000

local DATABLOCKS = [[
if (!isObject(dh142_wake_particle)) {
  datablock ParticleData(dh142_wake_particle) {
    textureName = "vehicles/ferry/dh142_foam.png";
    dragCoefficient = 1.2;
    gravityCoefficient = 0;
    inheritedVelFactor = 0;
    constantAcceleration = 0;
    lifetimeMS = 20000;
    lifetimeVarianceMS = 3000;
    spinSpeed = 6;
    spinRandomMin = -15;
    spinRandomMax = 15;
    useInvAlpha = false;
    colors[0] = "0.93 0.97 1.0 0.0";
    colors[1] = "0.96 0.98 1.0 0.42";
    colors[2] = "0.92 0.96 1.0 0.16";
    colors[3] = "0.90 0.94 1.0 0.0";
    sizes[0] = 4.5;
    sizes[1] = 8.5;
    sizes[2] = 13;
    sizes[3] = 16;
    times[0] = 0.0;
    times[1] = 0.1;
    times[2] = 0.5;
    times[3] = 1.0;
  };
}
if (!isObject(dh142_wake_emitter)) {
  datablock ParticleEmitterData(dh142_wake_emitter) {
    ejectionPeriodMS = 35;
    periodVarianceMS = 10;
    ejectionVelocity = 0.85;
    velocityVariance = 0.4;
    ejectionOffset = 0;
    thetaMin = 75;
    thetaMax = 105;
    phiReferenceVel = 0;
    phiVariance = 360;
    overrideAdvance = false;
    orientParticles = true;
    orientOnVelocity = false;
    particles = dh142_wake_particle;
    lifetimeMS = 220;
    lifetimeVarianceMS = 40;
    useEmitterSizes = true;
    useEmitterColors = false;
    softnessDistance = 3;
    blendStyle = "NORMAL";
    softParticles = true;
    ambientFactor = 0.7;
  };
}
if (!isObject(dh142_wake_node)) {
  datablock ParticleEmitterNodeData(dh142_wake_node) {
    timeMultiple = 1;
  };
}
]]

local function nowMs()
	if Engine and Engine.Platform and Engine.Platform.getSystemTimeMS then
		local ok, value = pcall(Engine.Platform.getSystemTimeMS)
		if ok and type(value) == "number" then return value end
	end
	return os.clock() * 1000
end

local function evalTorque(script)
	if TorqueScript and TorqueScript.eval then
		return TorqueScript.eval(script)
	end
	if ts and ts.eval then
		return ts.eval(script)
	end
	if _G["eval"] then
		return _G["eval"](script)
	end
	return nil
end

local function ensureDatablocks()
	if ready then return true end
	if scenetree.findObject("dh142_wake_emitter") and scenetree.findObject("dh142_wake_node") then
		ready = true
		return true
	end
	pcall(evalTorque, DATABLOCKS)
	ready = scenetree.findObject("dh142_wake_emitter") ~= nil and scenetree.findObject("dh142_wake_node") ~= nil
	return ready
end

local function nameList(names)
	if type(names) == "string" then
		local list = {}
		for name in names:gmatch("%S+") do
			list[#list + 1] = name
		end
		return list
	end
	if type(names) == "table" then return names end
	return {}
end

-- WaterPlane covers the whole map, so height is enough. A stern that is
-- several metres off that height is on land or in the air, and should not
-- paint foam.
local function waterHeight(z)
	local found = false
	local classes = {"WaterPlane", "WaterBlock"}
	for _, className in ipairs(classes) do
		local ok, names = pcall(scenetree.findClassObjects, className)
		if ok then
			for _, name in ipairs(nameList(names)) do
				local water = scenetree.findObject(name)
				local pos = water and water.getPosition and water:getPosition()
				if pos and type(pos.z) == "number" then
					found = true
					if math.abs(pos.z - z) < 4 then
						return pos.z
					end
				end
			end
		end
	end
	if found then return nil end
	return z
end

local function patchGroup()
	local group = scenetree.findObject("dh142_wake_patches")
	if group then return group end
	group = createObject("SimGroup")
	if not group then return nil end
	group:registerObject("dh142_wake_patches")
	pcall(function() group:setField("canSave", 0, "0") end)
	local mission = scenetree.MissionGroup
	if mission then
		local added = pcall(function() mission:addObject(group) end)
		if not added then
			pcall(function() mission:add(group) end)
		end
	end
	return group
end

local function destroyNamed(name)
	local obj = scenetree.findObject(name)
	if obj and obj.delete then
		pcall(function() obj:delete() end)
	end
end

local function sweep(force)
	local t = nowMs()
	local kept = {}
	for _, entry in ipairs(patches) do
		if force or (t - entry.born) > LIFE_MS then
			destroyNamed(entry.name)
		else
			kept[#kept + 1] = entry
		end
	end
	patches = kept
	while #patches > MAX_PATCHES do
		destroyNamed(patches[1].name)
		table.remove(patches, 1)
	end
end

local function clear()
	sweep(true)
	local group = scenetree.findObject("dh142_wake_patches")
	if group and group.delete then
		pcall(function() group:delete() end)
	end
	patches = {}
end

-- x, y, z are world metres. scale grows the patch. The emitter itself
-- dies after a short burst; the particles stay until LIFE_MS.
local function drop(x, y, z, scale)
	if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then return end
	if x ~= x or y ~= y or z ~= z then return end
	if not ensureDatablocks() then return end
	local surface = waterHeight(z)
	if not surface then return end
	sweep(false)
	local group = patchGroup()
	if not group then return end

	nextId = nextId + 1
	local name = "dh142wake" .. tostring(nextId)
	local node = createObject("ParticleEmitterNode")
	if not node then return end
	local sized = scale or 1
	if sized < 0.3 then sized = 0.3 elseif sized > 2.2 then sized = 2.2 end
	pcall(function() node:setField("datablock", 0, "dh142_wake_node") end)
	pcall(function() node:setField("emitter", 0, "dh142_wake_emitter") end)
	pcall(function() node:setField("canSave", 0, "0") end)
	local placed = pcall(function() node:setPosition(vec3(x, y, surface + 0.15)) end)
	if not placed then
		pcall(function() node:setField("position", 0, string.format("%f %f %f", x, y, surface + 0.15)) end)
	end
	local scaled = pcall(function() node:setScale(vec3(sized, sized, sized)) end)
	if not scaled then
		pcall(function() node:setField("scale", 0, string.format("%f %f %f", sized, sized, sized)) end)
	end
	node:registerObject(name)
	local added = pcall(function() group:addObject(node) end)
	if not added then
		pcall(function() group:add(node) end)
	end
	pcall(evalTorque, string.format('if (isObject(%s)) %s.schedule(%d, "delete");', name, name, LIFE_MS))
	patches[#patches + 1] = {name = name, born = nowMs()}
	while #patches > MAX_PATCHES do
		destroyNamed(patches[1].name)
		table.remove(patches, 1)
	end
end

local function onExtensionLoaded()
	rawset(_G, "dh142_wake", M)
	pcall(ensureDatablocks)
end

local function onExtensionUnloaded()
	clear()
	if rawget(_G, "dh142_wake") == M then
		rawset(_G, "dh142_wake", nil)
	end
end

M.drop = drop
M.clear = clear
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onClientEndMission = clear

return M
