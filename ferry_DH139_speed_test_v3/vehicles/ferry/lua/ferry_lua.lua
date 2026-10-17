-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local function onReset()
    
	
	electrics.values['ramp_lift'] = 0
    electrics.values['ramp_lift_input'] = 0
	
	
	
	
	
	
end

local function updateGFX(dt)
   
	electrics.values['ramp_lift'] = math.min(2, math.max(-2, (electrics.values['ramp_lift'] + electrics.values['ramp_lift_input'] * dt * 0.065)))
	
	
end

-- public interface
M.onInit    = onReset
M.onReset   = onReset
M.updateGFX = updateGFX

return M
