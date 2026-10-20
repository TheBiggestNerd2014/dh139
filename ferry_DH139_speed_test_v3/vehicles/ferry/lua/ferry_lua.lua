-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local anchorPos = nil
local wasParked = false
local overrideActive = false
local physicsSteps = 0
local holdWait = 0
local wakeNodes = nil
local wakeHooked = false
local wakeWait = 0
local lastWake = nil

-- About 0.4 m/s². From 10 mph that is roughly ten seconds to stop,
-- light enough that cars on the deck stay put.
local BRAKE_ACCEL = 0.4
local HOLD_ACCEL = 0.1
local COMMAND_DT = 0.1

-- Full throttle sits near REST_RPM while the hull is stopped, then climbs to
-- TOP_RPM once the boat is moving at SPEED_REF. This sample is a low-rpm
-- diesel, so the ceiling stays well under the limiter instead of screaming.
local REST_RPM = 3000
local TOP_RPM = 4200
local SPEED_REF = 3

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
	wakeNodes = nil
	wakeWait = 0
	lastWake = nil
	if obj and obj.queueGameEngineLua then
		pcall(obj.queueGameEngineLua, obj, "local w = extensions.dh142_wake or dh142_wake; if w and w.clear then w.clear() end")
	end
end

local function parkedFlag(value)
	if value == true then return true end
	if type(value) == 'number' and value > 0.5 then return true end
	return false
end

-- The parking-brake key sets parkingbrake. ferry_park is the same latch
-- when this vehicle's binding handles the key. Gearbox Park is ignored.
local function parkingOn()
	if parkedFlag(electrics.values.ferry_park) then return true end
	if parkedFlag(electrics.values.parkingbrake) then return true end
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

-- Ease the hull to a stop, then keep it there. The acceleration is horizontal
-- only, and it fades as the boat gets slow so the deck does not throw cars
-- into the ramp. The anchor is taken where the boat actually stops, not where
-- the button was pressed.
local function holdHull(dt)
	local pos = obj:getPosition()
	local vel = obj:getVelocity()
	if not pos or not vel then return end

	holdWait = holdWait + (dt or 0)
	if holdWait < COMMAND_DT then return end
	holdWait = 0

	local hspeed = math.sqrt(vel.x * vel.x + vel.y * vel.y)
	if hspeed > 0.25 then
		anchorPos = nil
	elseif not anchorPos then
		anchorPos = vec3(pos.x, pos.y, pos.z)
	end

	local ax, ay = 0, 0
	if hspeed > 0.12 then
		local strength = BRAKE_ACCEL * math.min(1, hspeed / 0.8)
		ax = -vel.x / hspeed * strength
		ay = -vel.y / hspeed * strength
	end

	if anchorPos then
		local dx = anchorPos.x - pos.x
		local dy = anchorPos.y - pos.y
		local dist = math.sqrt(dx * dx + dy * dy)
		if hspeed < 0.08 and dist < 0.35 then
			return
		end
		if dist > 0.35 then
			local pull = math.min(HOLD_ACCEL, (dist - 0.35) * 0.08)
			ax = ax + dx / dist * pull
			ay = ay + dy / dist * pull
		end
	elseif hspeed <= 0.12 then
		return
	end

	local amag = math.sqrt(ax * ax + ay * ay)
	if amag > BRAKE_ACCEL then
		ax = ax / amag * BRAKE_ACCEL
		ay = ay / amag * BRAKE_ACCEL
	end
	if amag < 0.02 then return end

	if thrusters.getAccelDt then
		local ok, pending = pcall(thrusters.getAccelDt)
		if ok and type(pending) == "number" and pending > 0.03 then
			return
		end
	end
	-- Zero on Z. Matching the boat's vertical speed is what threw it into the air.
	if thrusters and thrusters.applyAccel and pcall(thrusters.applyAccel, vec3(ax, ay, 0), COMMAND_DT) then
		return
	end
	if not v or not v.data or not v.data.nodes then return end
	local want = {ref = true, refb = true, refl = true, refr = true}
	local cids = {}
	for cid, n in pairs(v.data.nodes) do
		if type(n) == "table" and n.name and want[n.name] then
			cids[#cids + 1] = n.cid or cid
		end
	end
	if #cids == 0 then return end
	local share = 330000 / #cids
	for _, cid in ipairs(cids) do
		pcall(obj.applyForce, obj, cid, ax * share, ay * share, 0)
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

local WAKE_NODES = {
	{name = "fh115", scale = 1.6},
	{name = "fhl114", scale = 1.05},
	{name = "fhr114", scale = 1.05},
	{name = "fh6", scale = 0.7},
}

local function cacheWakeNodes()
	wakeNodes = {}
	if not v or not v.data or not v.data.nodes then return end
	local want = {}
	for _, entry in ipairs(WAKE_NODES) do
		want[entry.name] = true
	end
	for cid, n in pairs(v.data.nodes) do
		if type(n) == "table" and n.name and want[n.name] then
			wakeNodes[n.name] = n.cid or cid
		end
	end
end

local function nodeWorld(cid)
	local pos = obj:getPosition()
	local rel = obj:getNodePosition(cid)
	if not pos or not rel then return nil end
	return pos.x + rel.x, pos.y + rel.y, pos.z + rel.z
end

-- Drop foam at the bow and across the stern once the hull has moved a few
-- metres. The patches stay in the world after the boat has gone by.
local function updateWake(dt)
	wakeWait = wakeWait + (dt or 0)
	if wakeWait < 0.25 then return end
	wakeWait = 0
	if not obj or not obj.queueGameEngineLua then return end

	local vel = obj:getVelocity()
	local fwd = obj.getDirectionVector and obj:getDirectionVector()
	if not vel or not fwd then return end
	local along = fwd.x * vel.x + fwd.y * vel.y + fwd.z * vel.z
	if along < 1 then return end

	if not wakeNodes then cacheWakeNodes() end
	local cid = wakeNodes and wakeNodes.fh115
	if not cid then
		wakeNodes = nil
		return
	end
	local sx, sy, sz = nodeWorld(cid)
	if not sx then return end
	if lastWake then
		local dx = sx - lastWake.x
		local dy = sy - lastWake.y
		if dx * dx + dy * dy < 4.5 * 4.5 then return end
	end

	if not wakeHooked then
		local ok = pcall(obj.queueGameEngineLua, obj, "extensions.load('dh142_wake')")
		if not ok then return end
		wakeHooked = true
		return
	end

	local speedScale = math.min(1, (along - 1) / 3)
	local pieces = {}
	for _, entry in ipairs(WAKE_NODES) do
		local nodeId = wakeNodes[entry.name]
		if nodeId then
			local x, y, z = nodeWorld(nodeId)
			if x then
				local scale = entry.scale * (0.55 + 0.45 * speedScale)
				pieces[#pieces + 1] = string.format("w.drop(%f,%f,%f,%f)", x, y, z, scale)
			end
		end
	end
	if #pieces == 0 then return end
	local command = "local w = extensions.dh142_wake or dh142_wake; if w and w.drop then " .. table.concat(pieces, ";") .. " end"
	if pcall(obj.queueGameEngineLua, obj, command) then
		lastWake = {x = sx, y = sy}
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

	-- Physics update owns the hold. If this BeamNG build does not call it,
	-- the graphics step still has to, or the brake does nothing.
	if physicsSteps == 0 then
		updateParkAndEngine(dt)
	end

	updateWake(dt)

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
