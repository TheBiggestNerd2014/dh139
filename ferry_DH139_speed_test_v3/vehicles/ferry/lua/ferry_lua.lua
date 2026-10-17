-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local anchorPos = nil
local wasParked = false

local function onReset()
	electrics.values['ramp_lift'] = 0
	electrics.values['ramp_lift_input'] = 0
	electrics.values.ferry_park = 0
	anchorPos = nil
	wasParked = false
end

local function parkingOn()
	local value = electrics.values.ferry_park
	if value == true then return true end
	if type(value) == 'number' and value > 0.5 then return true end
	value = electrics.values.parkingbrake
	if value == true then return true end
	if type(value) == 'number' and value > 0.5 then return true end
	value = electrics.values.parking
	if value == true then return true end
	if type(value) == 'number' and value > 0.5 then return true end
	return false
end

-- Bleed horizontal drift only. Freezing vertical speed and pitch while the
-- ramp is down turns a bow that is trying to settle into a deck-wide hop.
-- A velocity command through thrusters stacks every frame, so it is not used.
local function holdFerry()
	local pos = obj:getPosition()
	local vel = obj:getVelocity()
	if not pos or not vel then return end
	if not anchorPos then
		anchorPos = vec3(pos.x, pos.y, pos.z)
	end
	local id = obj:getID()
	if not id then return end

	local dx = anchorPos.x - pos.x
	local dy = anchorPos.y - pos.y
	local dist = math.sqrt(dx * dx + dy * dy)
	local hspeed = math.sqrt(vel.x * vel.x + vel.y * vel.y)

	-- Sitting still. Leave the hull alone so cars on deck are not kicked.
	if dist < 0.4 and hspeed < 0.15 then
		return
	end

	local tx = vel.x
	local ty = vel.y
	if hspeed > 0.15 then
		local keep = math.max(0, hspeed - 0.35)
		local scale = keep / hspeed
		tx = vel.x * scale
		ty = vel.y * scale
	end
	if dist > 0.4 then
		local speed = math.min(0.25, (dist - 0.4) * 0.4)
		tx = tx + dx / dist * speed
		ty = ty + dy / dist * speed
	end

	obj:queueGameEngineLua(string.format(
		'local v=be:getObjectByID(%d); if v then v:setVelocity(vec3(%.4f,%.4f,%.4f)) end',
		id, tx, ty, vel.z))
end

local function updateGFX(dt)
	-- 0 is stowed on the bow, 1 is fully lowered. Releasing the key holds position.
	-- Full travel takes about 8 seconds.
	local rampLift = electrics.values.ramp_lift or 0
	local rampInput = electrics.values.ramp_lift_input or 0
	if rampLift < 0 then rampLift = 0 elseif rampLift > 1 then rampLift = 1 end
	if rampInput ~= 0 then
		rampLift = math.min(1, math.max(0, rampLift + rampInput * dt * 0.125))
	end
	electrics.values.ramp_lift = rampLift

	if parkingOn() then
		wasParked = true
		holdFerry()
	elseif wasParked then
		wasParked = false
		anchorPos = nil
	end

	-- 0.39 reads the speedometer only from wheels with speedo enabled.
	-- The propellers are not speedo wheels, so that value stays at 0.
	-- Use the hull velocity instead. wheelspeed is in m/s.
	local velocity = obj:getVelocity()
	if velocity then
		electrics.values.wheelspeed = velocity:length()
	end
end

-- public interface
M.onInit    = onReset
M.onReset   = onReset
M.updateGFX = updateGFX

return M
