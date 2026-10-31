-- Reads binary frames from the XIAO ("GB" | type | len u32 LE | payload) and passes
-- {type, payload} to the game. Tells the game when the link opens or closes, and
-- retries every second, so the XIAO can be plugged in or reset at any time.
local path = ...
local out = love.thread.getChannel("serial")
local timer = require("love.timer")
local MAX_FRAME = 2 * 1024 * 1024  -- A larger length means a corrupted header.

local function readFrames(f)
  local previous
  while true do
    local c = f:read(1)
    if not c then return end
    if previous == "G" and c == "B" then
      previous = nil
      local hdr = f:read(5)
      if not hdr or #hdr < 5 then return end
      local len = hdr:byte(2) + hdr:byte(3) * 256 + hdr:byte(4) * 65536 + hdr:byte(5) * 16777216
      if len <= MAX_FRAME then
        local payload = len > 0 and f:read(len) or ""
        if not payload or #payload < len then return end
        out:push({hdr:byte(1), payload})
      end
    else
      previous = c
    end
  end
end

while true do
  local f = io.open(path, "rb")
  if f then
    f:setvbuf("no")
    out:push({0, "opened"})
    readFrames(f)
    f:close()
    out:push({0, "closed"})
  end
  timer.sleep(1)
end
