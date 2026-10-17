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

-- Once per frame. The physics step is the wrong place for this: a per-step
-- acceleration command stacks and the hull never actually gets zeroed.
local function holdFerry()
	local pos = obj:getPosition()
	if not pos then return end
	if not anchorPos then
		anchorPos = vec3(pos.x, pos.y, pos.z)
	end

	local id = obj:getID()
	if id then
		obj:queueGameEngineLua(string.format(
			'local v=be:getObjectByID(%d); if v then v:setVelocity(vec3(0,0,0)); if v.setAngVelocity then v:setAngVelocity(vec3(0,0,0)) end end',
			id))
	end

	if thrusters and thrusters.applyVelocity then
		local err = anchorPos - pos
		local pull = err * 2
		local len = pull:length()
		if len > 1 then
			pull = pull * (1 / len)
		end
		thrusters.applyVelocity(pull, 0.05)
	end
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
		if thrusters and thrusters.applyVelocity then
			thrusters.applyVelocity(vec3(0, 0, 0), 0)
		end
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
