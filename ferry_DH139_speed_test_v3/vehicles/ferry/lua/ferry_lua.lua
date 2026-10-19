-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local anchorPos = nil
local wasParked = false
local overrideActive = false
local physicsSteps = 0
local holdWait = 0
local HOLD_DT = 0.05

-- Full throttle sits near REST_RPM while the hull is stopped, then climbs to
-- TOP_RPM once the boat is moving at SPEED_REF. Past that, it stays under the
-- rev limiter instead of buzzing on it.
local REST_RPM = 2800
local TOP_RPM = 7000
local SPEED_REF = 10

local function onReset()
	electrics.values['ramp_lift'] = 0
	electrics.values['ramp_lift_input'] = 0
	electrics.values.ferry_park = 0
	if overrideActive then
		electrics.values.throttleOverride = nil
		overrideActive = false
	end
	anchorPos = nil
	wasParked = false
	physicsSteps = 0
	holdWait = 0
end

local function parkedFlag(value)
	if value == true then return true end
	if type(value) == 'number' and value > 0.5 then return true end
	return false
end

local function parkingOn()
	if parkedFlag(electrics.values.ferry_park) then return true end
	if parkedFlag(electrics.values.parkingbrake) then return true end
	if parkedFlag(electrics.values.parking) then return true end
	return false
end

local function pedalInput()
	local state = input and input.state
	local throttle = state and state.throttle
	if type(throttle) == 'number' then return throttle end
	if type(throttle) == 'table' and type(throttle.val) == 'number' then return throttle.val end
	local value = electrics.values.throttle_input
	if type(value) == 'number' then return value end
	return 0
end

local function hullSpeed()
	local vel = obj:getVelocity()
	if not vel then return 0 end
	return math.sqrt(vel.x * vel.x + vel.y * vel.y)
end

local function rpmCeiling(speed)
	local t = speed / SPEED_REF
	if t < 0 then t = 0 elseif t > 1 then t = 1 end
	t = t * t * (3 - 2 * t)
	return REST_RPM + (TOP_RPM - REST_RPM) * t
end

local function setThrottle(value)
	electrics.values.throttleOverride = value
	overrideActive = true
end

local function releaseThrottle()
	if not overrideActive then return end
	electrics.values.throttleOverride = nil
	overrideActive = false
end

-- The converter used to let the crank run away to the limiter while the hull
-- was still slow. The pedal is passed through below the speed ceiling and
-- closed as rpm reaches it, so the note climbs with the boat.
local function govern()
	if parkingOn() then
		setThrottle(0)
		return
	end
	local pedal = pedalInput()
	if pedal < 0.02 then
		releaseThrottle()
		return
	end
	local cap = rpmCeiling(hullSpeed())
	local target = 875 + pedal * (cap - 875)
	local rpm = electrics.values.rpm or 0
	if rpm < target - 350 then
		releaseThrottle()
		return
	end
	local excess = (rpm - (target - 350)) / 700
	if excess < 0 then excess = 0 elseif excess > 1 then excess = 1 end
	setThrottle(pedal * (1 - excess))
end

-- Node velocity cannot be assigned. A world-object setVelocity is overwritten
-- by the physics step, which is why the brake did not hold. This asks the
-- thruster system for a horizontal acceleration only, and leaves heave alone
-- so a ramp resting on a dock cannot bounce the deck.
local function holdHull(dt)
	local pos = obj:getPosition()
	local vel = obj:getVelocity()
	if not pos or not vel then return end

	-- One command at a time. Applying every physics step stacks the acceleration
	-- and is what launched the deck when the ramp was down.
	holdWait = holdWait + (dt or 0.016)
	if holdWait < HOLD_DT then return end
	holdWait = 0

	local hspeed = math.sqrt(vel.x * vel.x + vel.y * vel.y)
	local tx, ty = 0, 0
	if hspeed < 0.4 then
		if not anchorPos then
			anchorPos = vec3(pos.x, pos.y, pos.z)
		end
		local dx = anchorPos.x - pos.x
		local dy = anchorPos.y - pos.y
		local dist = math.sqrt(dx * dx + dy * dy)
		if dist < 0.2 and hspeed < 0.05 then
			return
		end
		if dist > 0.2 then
			local pull = math.min(0.7, (dist - 0.2) * 0.5)
			tx = dx / dist * pull
			ty = dy / dist * pull
		end
	end

	local maxDelta = 6 * HOLD_DT
	local function stepToward(current, target)
		local delta = target - current
		if delta > maxDelta then return current + maxDelta end
		if delta < -maxDelta then return current - maxDelta end
		return target
	end

	if thrusters.getAccelDt then
		local ok, pending = pcall(thrusters.getAccelDt)
		if ok and type(pending) == 'number' and pending > 0.01 then
			return
		end
	end
	thrusters.applyVelocity(vec3(stepToward(vel.x, tx), stepToward(vel.y, ty), vel.z), HOLD_DT)
end

local function updateParkAndEngine(dt)
	if parkedFlag(electrics.values.ferry_park) and not parkedFlag(electrics.values.parkingbrake) then
		electrics.values.parkingbrake = 1
	end
	govern()
	if parkingOn() then
		wasParked = true
		holdHull(dt)
	elseif wasParked then
		wasParked = false
		anchorPos = nil
	end
end

local function update(dt)
	physicsSteps = physicsSteps + 1
	updateParkAndEngine(dt)
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

	-- Physics update owns the hold. If this BeamNG build does not call it,
	-- the graphics step still has to, or the brake does nothing.
	if physicsSteps == 0 then
		updateParkAndEngine(dt)
	end

	-- 0.39 reads the speedometer only from wheels with speedo enabled.
	-- The propellers are not speedo wheels, so that value stays at 0.
	-- Use the hull velocity instead. wheelspeed is in m/s.
	local velocity = obj:getVelocity()
	if velocity then
		electrics.values.wheelspeed = velocity:length()
	end
end

-- Run before the vehicle controller so the throttle ceiling is in place
-- when it reads the pedals.
M.defaultOrder = 450

-- public interface
M.onInit    = onReset
M.onReset   = onReset
M.update    = update
M.updateGFX = updateGFX

return M
