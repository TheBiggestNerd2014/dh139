-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local anchorPos = nil
local wasParked = false
local overrideActive = false
local physicsSteps = 0
local forceOk = true
local nodeMap = nil

local HOLD_NODES = {"ref", "refb", "refl", "refr"}
local HOLD_MASS = 330000
local HOLD_ACCEL = 2.0

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
	forceOk = true
	nodeMap = nil
end

local function parkedFlag(value)
	if value == true then return true end
	if type(value) == 'number' and value > 0.5 then return true end
	return false
end

-- Only the ferry latch. The gearbox "parking" value and the spawn parking
-- brake must not count, or the hold runs the moment the boat is created.
local function parkingOn()
	return parkedFlag(electrics.values.ferry_park)
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

local function ensureNodeMap()
	if nodeMap then return nodeMap end
	nodeMap = {}
	if not v or not v.data or not v.data.nodes then return nodeMap end
	for _, n in pairs(v.data.nodes) do
		if type(n) == "table" and n.name and n.cid then
			nodeMap[n.name] = n.cid
		end
	end
	return nodeMap
end

-- A velocity match feeds the boat's own speed back into the force and throws
-- it out of the water. This is a plain horizontal push, capped, with no
-- vertical component, so heave and pitch stay with the water.
local function holdHull(dt)
	if not forceOk then return end
	local pos = obj:getPosition()
	local vel = obj:getVelocity()
	if not pos or not vel then return end

	local hspeed = math.sqrt(vel.x * vel.x + vel.y * vel.y)
	local tx, ty = 0, 0
	if not anchorPos then
		anchorPos = vec3(pos.x, pos.y, pos.z)
	end
	local dx = anchorPos.x - pos.x
	local dy = anchorPos.y - pos.y
	local dist = math.sqrt(dx * dx + dy * dy)
	if dist < 0.25 and hspeed < 0.08 then
		return
	end
	if dist > 0.25 then
		local pull = math.min(0.6, (dist - 0.25) * 0.4)
		tx = dx / dist * pull
		ty = dy / dist * pull
	end

	local ax = tx - vel.x
	local ay = ty - vel.y
	local amag = math.sqrt(ax * ax + ay * ay)
	if amag > HOLD_ACCEL then
		ax = ax / amag * HOLD_ACCEL
		ay = ay / amag * HOLD_ACCEL
	end

	local share = 1 / #HOLD_NODES
	local fx = HOLD_MASS * ax * share
	local fy = HOLD_MASS * ay * share
	local map = ensureNodeMap()
	for _, name in ipairs(HOLD_NODES) do
		local cid = map[name]
		if cid then
			local ok = pcall(obj.applyForce, obj, cid, fx, fy, 0)
			if not ok then
				forceOk = false
				return
			end
		end
	end
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
