-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local refNodeId = nil
local anchorPos = nil
local anchorRot = nil
local wasParked = false

local function onReset()
	electrics.values['ramp_lift'] = 0
	electrics.values['ramp_lift_input'] = 0
	anchorPos = nil
	anchorRot = nil
	wasParked = false
	refNodeId = nil
end

local function ferryRefNode()
	if refNodeId ~= nil then return refNodeId end
	if beamstate and beamstate.nodeNameMap then
		refNodeId = beamstate.nodeNameMap['ref']
	end
	return refNodeId
end

-- World-space rotation that takes `current` onto `target`, as axis * angle.
local function rotationError(target, current)
	local inv = quat(-current.x, -current.y, -current.z, current.w)
	local d = quat(
		target.w * inv.x + target.x * inv.w + target.y * inv.z - target.z * inv.y,
		target.w * inv.y - target.x * inv.z + target.y * inv.w + target.z * inv.x,
		target.w * inv.z + target.x * inv.y - target.y * inv.x + target.z * inv.w,
		target.w * inv.w - target.x * inv.x - target.y * inv.y - target.z * inv.z
	)
	if d.w < 0 then
		d = quat(-d.x, -d.y, -d.z, -d.w)
	end
	local w = d.w
	if w > 1 then w = 1 elseif w < -1 then w = -1 end
	local angle = 2 * math.acos(w)
	local s = math.sqrt(math.max(0, 1 - w * w))
	if s < 1e-5 then
		return vec3(0, 0, 0)
	end
	return vec3(d.x * angle / s, d.y * angle / s, d.z * angle / s)
end

local function capVec(v, maxLen)
	local len = v:length()
	if len > maxLen and len > 0 then
		return v * (maxLen / len)
	end
	return v
end

-- Parking brake on this ferry holds the hull at the pose where it was pressed.
-- Other vehicles never load this controller.
local function update(dt)
	if not dt or dt <= 0 then return end
	local parking = (electrics.values.parkingbrake or 0) > 0
	local nodeId = ferryRefNode()

	if not parking then
		if wasParked and nodeId and thrusters and thrusters.applyAccel then
			thrusters.applyAccel(vec3(0, 0, 0), 0, nodeId, vec3(0, 0, 0))
		end
		wasParked = false
		anchorPos = nil
		anchorRot = nil
		return
	end

	local pos = obj:getPosition()
	local rot = obj:getRotation()
	if not pos or not rot then return end

	if not wasParked or not anchorPos or not anchorRot then
		anchorPos = vec3(pos.x, pos.y, pos.z)
		anchorRot = quat(rot.x, rot.y, rot.z, rot.w)
		wasParked = true
	end

	if not thrusters or not thrusters.applyAccel then return end

	local vel = obj:getVelocity() or vec3(0, 0, 0)
	local angVel = obj:getAngularVelocity() or vec3(0, 0, 0)
	-- Pull back to the parked pose, and bleed off speed. Overdamped so it does not bounce.
	local linAccel = capVec((anchorPos - pos) * 150 - vel * 30, 40)
	local angAccel = capVec(rotationError(anchorRot, rot) * 80 - angVel * 20, 8)
	pcall(thrusters.applyAccel, linAccel, dt, nodeId, angAccel)
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
M.update    = update
M.updateGFX = updateGFX

return M
