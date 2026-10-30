-- Frame <-> mpv on Windows, without a socket.
--
-- On Linux Frame talks to mpv through its control socket. On Windows that socket is a named
-- pipe, which Frame can't read and write reliably at the same time. So this script carries the
-- same messages a simpler way:
--   Frame -> mpv:  Frame appends one JSON command per line to a file; this script reads new
--                  lines 50 times a second and runs them.
--   mpv -> Frame:  this script prints one JSON message per line to mpv's output, which Frame
--                  already reads ("[frame_bridge] {...}").
-- The messages are mpv's own JSON IPC format, so the rest of Frame doesn't know the difference.

local mp = require 'mp'
local utils = require 'mp.utils'

local path = mp.get_opt('frame_bridge-commands')
if not path or path == '' then return end

local function send(t)
  local json = utils.format_json(t) -- (it also returns an error value; only the text is sent)
  if json then mp.msg.info(json) end
end

local function reply(id, ok, data, err)
  if id == nil then return end
  send({ request_id = id, error = ok and 'success' or (err or 'error'), data = data })
end

local function run(msg)
  local cmd, id = msg.command, msg.request_id
  if type(cmd) ~= 'table' or #cmd == 0 then return reply(id, false, nil, 'invalid parameter') end
  local name = cmd[1]
  if name == 'set_property' then
    local ok, err = mp.set_property_native(cmd[2], cmd[3])
    return reply(id, ok, nil, err)
  elseif name == 'get_property' then
    local v, err = mp.get_property_native(cmd[2])
    return reply(id, err == nil, v, err)
  elseif name == 'observe_property' then
    local obs, prop = cmd[2], cmd[3]
    mp.observe_property(prop, 'native', function(_, v)
      send({ event = 'property-change', id = obs, name = prop, data = v })
    end)
    return reply(id, true)
  else
    local res, err = mp.command_native(cmd)
    return reply(id, err == nil, res, err)
  end
end

-- New lines in the command file since the last look.
local offset, pending = 0, ''
mp.add_periodic_timer(0.02, function()
  local f = io.open(path, 'rb')
  if not f then return end
  local size = f:seek('end')
  if size and size > offset then
    f:seek('set', offset)
    local chunk = f:read(size - offset) or ''
    offset = size
    pending = pending .. chunk
    while true do
      local nl = pending:find('\n', 1, true)
      if not nl then break end
      local line = pending:sub(1, nl - 1)
      pending = pending:sub(nl + 1)
      if line ~= '' then
        local msg = utils.parse_json(line)
        if type(msg) == 'table' then
          local ok, e = pcall(run, msg)
          if not ok then reply(msg.request_id, false, nil, tostring(e)) end
        end
      end
    end
  end
  f:close()
end)

for _, ev in ipairs({ 'file-loaded', 'seek', 'playback-restart' }) do
  mp.register_event(ev, function() send({ event = ev }) end)
end
mp.register_event('end-file', function(e) send({ event = 'end-file', reason = e.reason, file_error = e.file_error }) end)

send({ event = 'bridge-ready' })
