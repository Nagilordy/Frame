-- Frame's player controls, drawn inside mpv.
--
-- mpv plays the video in its own full-screen window (the fastest way, and the only way to get
-- real HDR and native Dolby Vision). This script draws Frame's controls on top of it, in the
-- same design: title, progress bar, round buttons, and floating glass panels for Playback,
-- Audio and Subtitles. Frame (the app) talks to it:
--   Frame -> script:  script-message-to frame_ui key <up|down|left|right|select|back|playpause|rew|ff|info>
--                     script-message-to frame_ui pad <ps|xbox|none>     (controller legend)
--                     user-data/frame/info      (title, quality, Jellyfin's track names, ...)
--   script -> Frame:  user-data/frame/request   ({action=..., value=..., n=counter})
-- The keyboard and mouse work directly in this window.

local mp = require 'mp'
local assdraw = require 'mp.assdraw'

local W, H = 1920, 1080
local overlay = mp.create_osd_overlay('ass-events')
overlay.res_x, overlay.res_y = W, H

-- Colours (ASS order is BGR) and see-through amounts (00 = solid, FF = invisible)
local FG = 'F7F5F4'      -- #F4F5F7
local BG = '0B0806'      -- #06080B
local MUTED = 'CBC0B9'   -- #B9C0CB
local SOFT = 'E0D8D3'    -- #D3D8E0
local BODY = 'Hanken Grotesk'
local DISPLAY = 'Sora'

local state = {
  visible = true,
  zone = 'buttons',      -- back | bar | buttons | panel
  button = 2,            -- which bottom button has focus
  panel = nil,           -- nil | 'playback' | 'audio' | 'subtitles'
  panel_focus = 1,
  info_box = false,
  pad = 'none',          -- controller legend: ps | xbox | none
  info = {},             -- from Frame
  hits = {},             -- clickable areas from the last drawing
  hover = nil,           -- id of the area under the mouse
  hover_x = nil,         -- mouse x over the progress bar (for the time preview)
  panel_rect = nil,
  requests = 0,
}
local hide_timer = nil

-- ---------- Talking to Frame ----------

local function request(action, value)
  state.requests = state.requests + 1
  mp.set_property_native('user-data/frame/request', { action = action, value = value, n = state.requests })
end

-- In a Watch together room, play, pause and seek go to Frame, which asks the room; the room
-- then tells everyone (this window too) what to do. Alone, they act straight away.
local function in_room() return state.info.group ~= nil end

local function toggle_pause()
  if in_room() then request('sync', { op = 'toggle' }) else mp.command('cycle pause') end
end

local function seek_by(sec)
  if in_room() then
    local p = (mp.get_property_number('time-pos', 0) or 0) + sec
    request('sync', { op = 'seek', pos = math.max(0, p) })
  else
    mp.commandv('seek', tostring(sec), 'relative')
  end
end

local function seek_to(fraction)
  local dur = mp.get_property_number('duration', 0) or 0
  if dur <= 0 then return end
  fraction = math.max(0, math.min(1, fraction))
  if in_room() then
    request('sync', { op = 'seek', pos = dur * fraction })
  else
    mp.commandv('seek', tostring(fraction * 100), 'absolute-percent')
  end
end

mp.observe_property('user-data/frame/info', 'native', function(_, v)
  if type(v) == 'table' then state.info = v end
end)

-- ---------- Drawing helpers ----------

local function esc(s)
  s = tostring(s or '')
  return (s:gsub('\\', '\\\\'):gsub('{', '\\{'):gsub('}', '\\}'):gsub('\n', '\\N'))
end

local function rect(ass, x0, y0, x1, y1, r, colour, alpha)
  ass:new_event()
  ass:append(string.format('{\\an7\\pos(0,0)\\bord0\\shad0\\1c&H%s&\\1a&H%s&}', colour, alpha or '00'))
  ass:draw_start()
  if r and r > 0 then ass:round_rect_cw(x0, y0, x1, y1, r) else ass:rect_cw(x0, y0, x1, y1) end
  ass:draw_stop()
end

-- Frame's pop-up surface: solid dark (#1A1E25), soft corners, no blur, the same as menus and
-- panels in the app. With accent = true, a thin line in your profile's colour along the top.
local SURFACE = '251E1A'
local function accent_colour() return state.info.accent or 'FF8C6F' end

local function glass(ass, x0, y0, x1, y1, r, alpha, accent)
  if accent then
    rect(ass, x0, y0, x1, y1, r, accent_colour(), '00')
    rect(ass, x0, y0 + 4, x1, y1, r, SURFACE, '00')
  else
    rect(ass, x0, y0, x1, y1, r, SURFACE, alpha or '00')
  end
end

local function text(ass, x, y, align, font, size, weight, colour, s, alpha)
  ass:new_event()
  ass:append(string.format('{\\an%d\\pos(%d,%d)\\fn%s\\fs%d\\b%d\\1c&H%s&\\1a&H%s&\\bord0\\shad0\\q2}%s',
    align, x, y, font, size, weight, colour, alpha or '00', esc(s)))
end

local function path(ass, colour, points)
  ass:new_event()
  ass:append(string.format('{\\an7\\pos(0,0)\\bord0\\shad0\\1c&H%s&}', colour))
  ass:draw_start()
  ass:move_to(points[1][1], points[1][2])
  for i = 2, #points do ass:line_to(points[i][1], points[i][2]) end
  ass:draw_stop()
end

-- A soft dark shade along the top or bottom. mpv's overlay has no gradients, so it is
-- built from many thin bands that touch exactly (no overlap, so no darker seams), each a
-- little lighter, easing out smoothly so no step is visible.
local function shade(ass, y0, y1, from_bottom)
  local steps = 48
  local height = y1 - y0
  for i = 0, steps - 1 do
    local a0 = math.floor(height * i / steps + 0.5)
    local a1 = math.floor(height * (i + 1) / steps + 0.5)
    if a1 > a0 then
      local t = (i + 0.5) / steps               -- 0 at the edge, 1 at the far end
      local fade = 1 - t
      local opacity = 0.72 * fade * fade * (3 - 2 * fade)   -- smooth ease
      local alpha = string.format('%02X', math.floor(255 * (1 - opacity) + 0.5))
      if from_bottom then
        rect(ass, 0, y1 - a1, W, y1 - a0, 0, '000000', alpha)
      else
        rect(ass, 0, y0 + a0, W, y0 + a1, 0, '000000', alpha)
      end
    end
  end
end

local function clock(sec)
  sec = math.max(0, math.floor(sec or 0))
  local h, m, s = math.floor(sec / 3600), math.floor(sec % 3600 / 60), sec % 60
  if h > 0 then return string.format('%d:%02d:%02d', h, m, s) end
  return string.format('%d:%02d', m, s)
end

-- A clickable area: fn runs on click, focus moves the highlight there on hover.
local function hit(id, x0, y0, x1, y1, fn, focus)
  table.insert(state.hits, { x0, y0, x1, y1, fn, focus, id = id })
end

-- ---------- Panels ----------

local function track_list(kind)
  local out = {}
  for _, t in ipairs(mp.get_property_native('track-list') or {}) do
    if t.type == kind then table.insert(out, t) end
  end
  return out
end

-- Readable names: Jellyfin's description of the same track when Frame sent it.
local function track_label(t, kind, n)
  local names = (kind == 'audio') and state.info.audio_names or state.info.sub_names
  if names and not t.external and names[n] and names[n] ~= '' then return names[n] end
  local parts = {}
  if t.lang then table.insert(parts, t.lang) end
  if t.title then table.insert(parts, t.title) end
  if t.codec then table.insert(parts, string.upper(t.codec)) end
  if #parts == 0 then return 'Track ' .. tostring(t.id) end
  return table.concat(parts, ' · ')
end

local function sub_style()
  return state.info.sub_scale or 1.0, state.info.sub_pos or 100, state.info.sub_box or false
end

-- Each row: { label, selected, action, adjust = function(dir) } (adjust: left/right steppers)
local function panel_rows()
  local rows = {}
  if state.panel == 'playback' then
    local mode = state.info.mode or 'auto'
    table.insert(rows, { 'Automatic', mode == 'auto', function() request('mode', 'auto') end })
    table.insert(rows, { 'Original file · best quality', mode == 'original', function() request('mode', 'original') end })
    table.insert(rows, { 'Converted by the server · smoothest', mode == 'server', function() request('mode', 'server') end })
  elseif state.panel == 'audio' then
    if state.info.server and state.info.server_audio then
      for _, a in ipairs(state.info.server_audio) do
        table.insert(rows, { a.label, a.selected, function() request('audio', a.index) end })
      end
    else
      local n = 0
      for _, t in ipairs(track_list('audio')) do
        n = n + 1
        local id = t.id
        table.insert(rows, { track_label(t, 'audio', n), t.selected, function()
          mp.set_property_native('aid', id)
          request('picked', 'audio')   -- Frame remembers it for the show
        end })
      end
    end
  elseif state.panel == 'subtitles' then
    if state.info.server and state.info.server_subs then
      local any = false
      for _, s in ipairs(state.info.server_subs) do if s.selected then any = true end end
      table.insert(rows, { 'Off', not any, function() request('sub', -1) end })
      for _, s in ipairs(state.info.server_subs) do
        table.insert(rows, { s.label, s.selected, function() request('sub', s.index) end })
      end
    else
      local sid = mp.get_property('sid')
      table.insert(rows, { 'Off', sid == 'no' or sid == nil, function()
        mp.set_property('sid', 'no')
        request('picked', 'sub')
      end })
      local n = 0
      for _, t in ipairs(track_list('sub')) do
        n = n + 1
        local id = t.id
        table.insert(rows, { track_label(t, 'sub', n), t.selected, function()
          mp.set_property_native('sid', id)
          mp.set_property('sub-visibility', 'yes')
          request('picked', 'sub')
        end })
      end
    end
    -- Style, remembered by Frame for every video.
    local scale, pos, box = sub_style()
    table.insert(rows, { 'Size  ' .. math.floor(scale * 100 + 0.5) .. '%', false, nil, function(dir)
      request('style', { scale = math.max(0.5, math.min(2.0, scale + dir * 0.1)), pos = pos, box = box })
    end, header = 'Style' })
    local above = math.floor((100 - pos) / 5 + 0.5)
    table.insert(rows, { 'Position  ' .. (above == 0 and 'Bottom' or ('+' .. above)), false, nil, function(dir)
      request('style', { scale = scale, pos = math.max(40, math.min(100, pos - dir * 5)), box = box })
    end })
    table.insert(rows, { 'Background box  ' .. (box and 'On' or 'Off'), box, function()
      request('style', { scale = scale, pos = pos, box = not box })
    end, stay = true })
  end
  return rows
end

local function draw_check(ass, x, y, colour)
  -- a small tick mark, drawn as a shape so it never depends on a font
  path(ass, colour, { { x, y + 2 }, { x + 4, y - 2 }, { x + 10, y + 4 }, { x + 22, y - 10 },
    { x + 26, y - 6 }, { x + 10, y + 12 } })
end

-- Picking a row (same for keyboard, controller and mouse): tracks and modes close the
-- panel, style rows stay open so you can see the change.
local function choose(rows, idx)
  local row = rows[idx]
  if not row then return end
  if row[3] then
    row[3]()
    if not row.stay then state.panel, state.zone = nil, 'buttons' end
  elseif row[4] then row[4](1) end
end

local function draw_panel(ass)
  local x0, y0, x1, y1 = W - 32 - 460, 32, W - 32, H - 32
  state.panel_rect = { x0, y0, x1, y1 }
  rect(ass, 0, 0, W, H, 0, '000000', '8C')                    -- dim the video behind the panel
  glass(ass, x0, y0, x1, y1, 18, nil, true)        -- the solid surface, profile colour on top
  local titles = { playback = 'Playback', audio = 'Audio', subtitles = 'Subtitles' }
  text(ass, x0 + 44, y0 + 40, 7, DISPLAY, 34, 700, FG, titles[state.panel])
  local rows = panel_rows()
  if state.panel_focus > #rows then state.panel_focus = #rows end
  if state.panel_focus < 1 then state.panel_focus = 1 end
  local y = y0 + 110
  local row_h = 62
  -- keep the focused row in view
  -- Scroll only as far as needed to keep the highlighted row in view, so hovering
  -- with the mouse never makes the list jump.
  local max_rows = math.floor((y1 - y - 30) / row_h) - ((state.panel == 'subtitles') and 1 or 0)
  local first = state.panel_first or 1
  if state.panel_focus < first then first = state.panel_focus end
  if state.panel_focus > first + max_rows - 1 then first = state.panel_focus - max_rows + 1 end
  first = math.max(1, first)
  state.panel_first = first
  for i = first, #rows do
    local row = rows[i]
    if row.header then
      text(ass, x0 + 44, y + 14, 7, BODY, 19, 700, MUTED, row.header)
      y = y + 46
    end
    if y + row_h > y1 - 16 then break end
    local focused = (state.zone == 'panel' and state.panel_focus == i)
    -- rows are pills like the buttons in Frame: faint when idle, solid white when selected
    rect(ass, x0 + 24, y, x1 - 24, y + row_h - 6, (row_h - 6) / 2, FG, focused and '00' or 'EB')
    local colour = focused and BG or FG
    text(ass, x0 + 44, y + (row_h - 6) / 2, 4, BODY, 24, row[2] and 700 or 500, colour, row[1])
    if row[2] then draw_check(ass, x1 - 70, y + (row_h - 6) / 2, colour) end
    local idx = i
    local cy = y + (row_h - 6) / 2
    local function focus() state.zone, state.panel_focus = 'panel', idx end
    hit('row' .. i, x0 + 24, y, x1 - 24, y + row_h - 6, function() focus(); choose(rows, idx) end, focus)
    if row[4] then
      -- two round arrow buttons: smaller / bigger (or lower / higher)
      for side, dir in pairs({ l = -1, r = 1 }) do
        local cx = (dir < 0) and (x1 - 108) or (x1 - 60)
        local hov = state.hover == ('row' .. i .. side)
        rect(ass, cx - 20, cy - 20, cx + 20, cy + 20, 20, focused and BG or FG, hov and (focused and '40' or 'B0') or (focused and 'C0' or 'E0'))
        local ax = dir < 0 and -1 or 1
        path(ass, colour, { { cx - 4 * ax, cy - 8 }, { cx + 6 * ax, cy }, { cx - 4 * ax, cy + 8 }, { cx - 6 * ax, cy + 6 }, { cx + 1 * ax, cy }, { cx - 6 * ax, cy - 6 } })
        hit('row' .. i .. side, cx - 22, cy - 22, cx + 22, cy + 22, function() focus(); rows[idx][4](dir) end, focus)
      end
    end
    y = y + row_h
  end
  if state.panel == 'playback' then
    text(ass, x0 + 44, y + 20, 7, BODY, 19, 500, MUTED,
      state.info.server and 'Now playing the version your server converts on the NAS.'
        or 'Now playing the original file, straight from the NAS.')
  end
end

-- ---------- The controls ----------

local buttons = { 'rew', 'play', 'ff', 'playback', 'audio', 'subtitles', 'info' }

local function draw_button(ass, name, cx, cy, size, focused)
  local r = size / 2
  rect(ass, cx - r, cy - r, cx + r, cy + r, r, FG, focused and '00' or 'E0')
  local c = focused and BG or FG
  if name == 'play' then
    if mp.get_property_native('pause') then
      path(ass, c, { { cx - 9, cy - 15 }, { cx + 15, cy }, { cx - 9, cy + 15 } })
    else
      rect(ass, cx - 12, cy - 14, cx - 4, cy + 14, 2, c)
      rect(ass, cx + 4, cy - 14, cx + 12, cy + 14, 2, c)
    end
  elseif name == 'rew' or name == 'ff' then
    text(ass, cx, cy, 5, BODY, 18, 800, c, name == 'rew' and '−10' or '+30')
  elseif name == 'audio' then
    local hs = { 8, 16, 24, 16, 8 }
    for i = 1, 5 do
      local x = cx - 14 + (i - 1) * 7
      rect(ass, x - 1.5, cy - hs[i] / 2, x + 1.5, cy + hs[i] / 2, 1.5, c)
    end
  elseif name == 'subtitles' then
    rect(ass, cx - 15, cy - 11, cx + 15, cy + 11, 4, c)
    rect(ass, cx - 12.5, cy - 8.5, cx + 12.5, cy + 8.5, 3, focused and FG or '3A3430')
    text(ass, cx, cy + 1, 5, BODY, 13, 800, c, 'CC')
  elseif name == 'playback' then
    for i, yy in ipairs({ -8, 0, 8 }) do
      rect(ass, cx - 14, cy + yy - 1.5, cx + 14, cy + yy + 1.5, 1.5, c)
      local kx = ({ cx + 6, cx - 6, cx + 2 })[i]
      rect(ass, kx - 4, cy + yy - 4, kx + 4, cy + yy + 4, 4, c)
    end
  elseif name == 'info' then
    text(ass, cx, cy + 1, 5, DISPLAY, 24, 700, c, 'i')
  end
end

local function pad_legend(ass)
  if state.pad == 'none' then return end
  local ps = state.pad == 'ps'
  local items
  if state.panel then
    items = { { 'select', 'Select' }, { 'back', 'Close' } }
  else
    items = { { 'select', 'Select' }, { 'menu', 'Play/Pause' }, { 'skip', 'Skip' }, { 'back', 'Hide' } }
  end
  -- measure roughly: glyph 30 + gap 10 + label ~11 px per character + 26 between items
  local width = 36
  for _, it in ipairs(items) do width = width + 30 + 10 + #it[2] * 11 + 26 + (it[1] == 'skip' and 40 or 0) end
  -- Bottom left, on the same line as the buttons: the right side holds Playback, Audio,
  -- Subtitles and Info, and the middle holds play and the skips.
  local x0, y0 = 48, H - 84 - 25
  local x1, y1 = x0 + width, y0 + 50
  rect(ass, x0, y0, x1, y1, 25, BG, '48')
  local x, cy = x0 + 18, (y0 + y1) / 2
  for _, it in ipairs(items) do
    local g = it[1]
    if g == 'select' or g == 'back' then
      rect(ass, x, cy - 15, x + 30, cy + 15, 15, FG, 'D0')
      if ps then
        if g == 'select' then text(ass, x + 15, cy, 5, BODY, 20, 800, FG, '✕')
        else rect(ass, x + 7, cy - 8, x + 23, cy + 8, 8, FG); rect(ass, x + 10, cy - 5, x + 20, cy + 5, 5, '2A2626') end
      else
        text(ass, x + 15, cy, 5, BODY, 16, 800, FG, g == 'select' and 'A' or 'B')
      end
      x = x + 40
    elseif g == 'menu' then
      rect(ass, x, cy - 15, x + 30, cy + 15, 9, FG, 'D0')
      for _, yy in ipairs({ -6, 0, 6 }) do rect(ass, x + 8, cy + yy - 1.5, x + 22, cy + yy + 1.5, 1.5, FG) end
      x = x + 40
    elseif g == 'skip' then
      rect(ass, x, cy - 15, x + 32, cy + 15, 9, FG, 'D0')
      text(ass, x + 16, cy, 5, BODY, 13, 800, FG, ps and 'L1' or 'LB')
      rect(ass, x + 36, cy - 15, x + 68, cy + 15, 9, FG, 'D0')
      text(ass, x + 52, cy, 5, BODY, 13, 800, FG, ps and 'R1' or 'RB')
      x = x + 78
    end
    text(ass, x, cy, 4, BODY, 19, 600, FG, it[2])
    x = x + #it[2] * 11 + 26
  end
end

local function info_box(ass)
  local hw = mp.get_property('hwdec-current') or 'no'
  local drops = mp.get_property('frame-drop-count') or '0'
  local dec = mp.get_property('decoder-frame-drop-count') or '0'
  local cache = tonumber(mp.get_property('demuxer-cache-duration') or '0') or 0
  local tp = mp.get_property_native('video-target-params') or {}
  local out = (tp.gamma == 'pq' or tp.gamma == 'hlg') and 'HDR to the screen'
    or ((((mp.get_property_native('video-params') or {}).gamma == 'pq')
      or tostring(state.info.quality or ''):find('Dolby') or tostring(state.info.quality or ''):find('HDR'))
      and 'HDR converted to SDR' or 'SDR')
  local lines = {
    'Output  ' .. out .. '  ·  mpv ' .. (mp.get_property('mpv-version') or ''):gsub('^mpv ', ''),
    'Decoder  ' .. ((hw == '' or hw == 'no') and 'CPU' or ('GPU (' .. hw .. ')')),
    'Dropped frames  ' .. drops .. ' / ' .. dec,
    'Buffered  ' .. math.floor(cache) .. 's',
    'Source  ' .. (state.info.server and 'converted by your server (NAS)' or 'original file, direct play'),
    'Picture  mpv, full screen' .. ((state.info.step or 0) > 0 and (', eased (step ' .. state.info.step .. ')') or ''),
  }
  local x1, y0 = W - 56, state.info.group and 168 or 150
  local x0, y1 = x1 - 560, y0 + 40 + #lines * 32
  glass(ass, x0, y0, x1, y1, 14)
  for i, l in ipairs(lines) do text(ass, x0 + 22, y0 + 20 + (i - 1) * 32, 7, BODY, 19, 500, SOFT, l) end
end

-- Who's in the room: small initials, top right, under the quality line.
local function room_people(ass)
  local g = state.info.group
  if not g then return end
  local people = g.people or {}
  local cy, r = 122, 18
  local x = W - 56
  for i = #people, 1, -1 do
    local name = tostring(people[i])
    local cx = x - r
    rect(ass, cx - r - 3, cy - r - 3, cx + r + 3, cy + r + 3, r + 3, BG, '30')
    rect(ass, cx - r, cy - r, cx + r, cy + r, r, ({ 'FA8C6F', '906EEE', 'AED14F', '5AB0F2', 'F584A8', 'EEC25F' })[(#name % 6) + 1])
    text(ass, cx, cy + 1, 5, DISPLAY, 17, 700, FG, name:sub(1, 1):upper())
    x = x - 2 * r - 8
  end
  text(ass, x - 6, cy, 6, BODY, 19, 600, SOFT, 'Watching together')
end

-- Short notes ("Bob paused", "Alex joined"), shown even when the controls are hidden.
local function notice_and_waiting(ass)
  local now = mp.get_time()
  local g = state.info.group
  local msg, left = nil, 1
  if state.notice and now < (state.notice_until or 0) then
    msg = state.notice
    left = (state.notice_until - now) / 3.5
  elseif g and g.state == 'Waiting' then
    msg, left = 'Waiting for everyone…', nil
  end
  if not msg then return end
  -- A banner like the rest of Frame: solid bar, small caps line, bold text, and a line
  -- along the bottom that runs down until it leaves (amber and full while waiting).
  local half = math.max(240, 60 + #msg * 7)
  local y = state.visible and 150 or 40
  local x0, x1 = W / 2 - half, W / 2 + half
  glass(ass, x0, y, x1, y + 84, 14)
  text(ass, x0 + 26, y + 26, 4, BODY, 15, 700, MUTED, 'WATCH TOGETHER')
  text(ass, x0 + 26, y + 54, 4, BODY, 23, 700, FG, msg)
  rect(ass, x0 + 6, y + 80, x1 - 6, y + 84, 0, FG, 'EB')
  local w = (x1 - x0 - 12) * (left or 1)
  if w > 1 then rect(ass, x0 + 6, y + 80, x0 + 6 + w, y + 84, 0, left and accent_colour() or '3BA2F0', '00') end
end

local function render()
  state.hits = {}
  state.panel_rect = nil
  local ass = assdraw.ass_new()
  if state.visible then
    local pos = mp.get_property_number('time-pos', 0) or 0
    local dur = mp.get_property_number('duration', 0) or 0
    local cached = mp.get_property_number('demuxer-cache-time', 0) or 0

    shade(ass, 0, 230, false)
    shade(ass, H - 330, H, true)

    -- Top: Back, title, quality
    local back_focus = state.zone == 'back'
    rect(ass, 48, 40, 100, 92, 26, FG, back_focus and '00' or 'E0')
    path(ass, back_focus and BG or FG, { { 64, 66 }, { 78, 52 }, { 82, 56 }, { 72, 64 }, { 88, 64 }, { 88, 68 }, { 72, 68 }, { 82, 76 }, { 78, 80 } })
    hit('back', 48, 40, 100, 92, function() mp.command('quit') end, function() state.zone = 'back' end)
    text(ass, 124, 46, 7, DISPLAY, 34, 700, FG, state.info.title or mp.get_property('media-title') or '')
    if state.info.subtitle and state.info.subtitle ~= '' then
      text(ass, 124, 92, 7, BODY, 22, 500, SOFT, state.info.subtitle)
    end
    if state.info.quality then text(ass, W - 56, 66, 6, BODY, 20, 600, SOFT, state.info.quality) end

    -- Progress bar
    local bx0, bx1, by = 56, W - 56, H - 190
    local bar_focus = state.zone == 'bar'
    local th = bar_focus and 8 or 5
    rect(ass, bx0, by - th / 2, bx1, by + th / 2, th / 2, FG, 'CC')
    if dur > 0 then
      local played = math.min(1, pos / dur)
      local buffered = math.min(1, cached / dur)
      if buffered > played then rect(ass, bx0, by - th / 2, bx0 + (bx1 - bx0) * buffered, by + th / 2, th / 2, FG, 'A6') end
      local px = bx0 + (bx1 - bx0) * played
      rect(ass, bx0, by - th / 2, px, by + th / 2, th / 2, FG, '00')
      if bar_focus then rect(ass, px - 11, by - 11, px + 11, by + 11, 11, FG, '00') end
    end
    hit('bar', bx0, by - 22, bx1, by + 22, function()
      local x = state.hover_x
      if x and dur > 0 then seek_to((x - bx0) / (bx1 - bx0)) end
    end, function() state.zone = 'bar' end)
    -- Hovering the bar: a little pill with the time under the pointer.
    if state.hover == 'bar' and state.hover_x and dur > 0 then
      local f = math.max(0, math.min(1, (state.hover_x - bx0) / (bx1 - bx0)))
      local hx = bx0 + (bx1 - bx0) * f
      local label = clock(dur * f)
      local half = 14 + #label * 6
      local px = math.max(bx0 + half, math.min(bx1 - half, hx))
      glass(ass, px - half, by - 62, px + half, by - 24, 19, '20')
      text(ass, px, by - 43, 5, BODY, 20, 700, FG, label)
      rect(ass, hx - 1.5, by - 10, hx + 1.5, by + 10, 1.5, FG, '00')
    end

    -- Times
    local left = math.max(0, dur - pos)
    text(ass, bx0, by + 36, 4, BODY, 21, 500, SOFT, clock(pos))
    if dur > 0 then
      local speed = mp.get_property_number('speed', 1) or 1
      text(ass, W / 2, by + 36, 5, BODY, 21, 500, MUTED, 'Ends at ' .. os.date('%H:%M', os.time() + math.floor(left / speed)))
    end
    text(ass, bx1, by + 36, 6, BODY, 21, 500, SOFT, '-' .. clock(left))

    -- Buttons: -10, play, +30 in the middle; Playback, Audio, Subtitles, Info on the right
    local cy = H - 84
    local centre = { { 'rew', W / 2 - 98, 52 }, { 'play', W / 2, 72 }, { 'ff', W / 2 + 98, 52 } }
    local right = {}
    local rx = W - 56 - 26
    for i = 7, 4, -1 do right[i] = { buttons[i], rx, 52 }; rx = rx - 64 end
    for i, b in ipairs(centre) do
      draw_button(ass, b[1], b[2], cy, b[3], state.zone == 'buttons' and state.button == i)
      local idx = i
      hit('btn' .. i, b[2] - b[3] / 2, cy - b[3] / 2, b[2] + b[3] / 2, cy + b[3] / 2, function() state.zone, state.button = 'buttons', idx; activate() end,
        function() state.zone, state.button = 'buttons', idx end)
    end
    for i = 4, 7 do
      local b = right[i]
      draw_button(ass, b[1], b[2], cy, b[3], state.zone == 'buttons' and state.button == i)
      local idx = i
      hit('btn' .. i, b[2] - 28, cy - 28, b[2] + 28, cy + 28, function() state.zone, state.button = 'buttons', idx; activate() end,
        function() state.zone, state.button = 'buttons', idx end)
    end

    room_people(ass)
    if state.info_box then info_box(ass) end
    if state.panel then draw_panel(ass) end
    pad_legend(ass)
  end
  notice_and_waiting(ass)
  overlay.data = ass.text
  overlay:update()
end

-- ---------- Showing, hiding ----------

local function schedule_hide()
  if hide_timer then hide_timer:kill() end
  hide_timer = mp.add_timeout(4, function()
    if not mp.get_property_native('pause') and not state.panel and not state.hover then
      state.visible = false
      render()
    end
  end)
end

local function show(focus_play)
  if not state.visible then
    state.visible = true
    if focus_play then state.zone, state.button = 'buttons', 2 end
  end
  render()
  schedule_hide()
end

local function hide()
  state.visible, state.panel = false, nil
  render()
end

-- ---------- Actions ----------

function activate()
  local b = buttons[state.button]
  if b == 'play' then toggle_pause()
  elseif b == 'rew' then seek_by(-10)
  elseif b == 'ff' then seek_by(30)
  elseif b == 'info' then state.info_box = not state.info_box
  else state.panel, state.zone, state.panel_focus, state.panel_first = b, 'panel', 1, 1 end
  show()
end

local function key(k)
  -- Keyboard or controller in use: the mouse no longer holds the controls open.
  state.hover, state.hover_x = nil, nil
  if not state.visible then
    if k == 'left' or k == 'rew' then seek_by(-10)
    elseif k == 'right' or k == 'ff' then seek_by(30)
    elseif k == 'back' then mp.command('quit') return
    elseif k == 'playpause' then toggle_pause()
    elseif k == 'info' then state.info_box = not state.info_box end
    show(true)
    return
  end
  if k == 'playpause' then toggle_pause() show() return end
  if k == 'rew' then seek_by(-10) show() return end
  if k == 'ff' then seek_by(30) show() return end
  if k == 'info' then state.info_box = not state.info_box show() return end

  if state.zone == 'panel' then
    local rows = panel_rows()
    if k == 'up' then state.panel_focus = math.max(1, state.panel_focus - 1)
    elseif k == 'down' then state.panel_focus = math.min(#rows, state.panel_focus + 1)
    elseif k == 'back' then state.panel = nil; state.zone = 'buttons'
    elseif (k == 'left' or k == 'right') and rows[state.panel_focus] and rows[state.panel_focus][4] then
      rows[state.panel_focus][4](k == 'right' and 1 or -1)
    elseif k == 'select' then choose(rows, state.panel_focus)
    end
    show()
    return
  end

  if k == 'back' then hide() return end
  if state.zone == 'buttons' then
    if k == 'left' then state.button = math.max(1, state.button - 1)
    elseif k == 'right' then state.button = math.min(#buttons, state.button + 1)
    elseif k == 'up' then state.zone = 'bar'
    elseif k == 'select' then activate() return end
  elseif state.zone == 'bar' then
    if k == 'left' then seek_by(-10)
    elseif k == 'right' then seek_by(30)
    elseif k == 'up' then state.zone = 'back'
    elseif k == 'down' then state.zone = 'buttons'
    elseif k == 'select' then toggle_pause() end
  elseif state.zone == 'back' then
    if k == 'down' then state.zone = 'bar'
    elseif k == 'select' then mp.command('quit') return end
  end
  show()
end

mp.register_script_message('key', key)
mp.register_script_message('pad', function(style) state.pad = style or 'none'; render() end)
local notice_timer = nil
mp.register_script_message('notice', function(text)
  state.notice, state.notice_until = text, mp.get_time() + 3.5
  render()
  -- redraw often while it shows, so its line runs down smoothly
  if notice_timer then notice_timer:kill() end
  notice_timer = mp.add_periodic_timer(0.1, function()
    render()
    if mp.get_time() > state.notice_until then notice_timer:kill(); notice_timer = nil; render() end
  end)
end)

-- Keyboard in this window: the same keys as in Frame.
local keymap = {
  UP = 'up', DOWN = 'down', LEFT = 'left', RIGHT = 'right', ENTER = 'select', KP_ENTER = 'select',
  ESC = 'back', BS = 'back', SPACE = 'playpause', i = 'info', I = 'info',
}
for name, k in pairs(keymap) do
  mp.add_forced_key_binding(name, 'frame_' .. name, function()
    if state.pad ~= 'none' then state.pad = 'none' end
    key(k)
  end, { repeatable = true })
end

-- Mouse: moving shows the controls and highlights what's under the pointer, like hovering
-- in Frame; clicking presses it; the wheel scrolls panels (or skips, outside a panel).
local function mouse_xy()
  local mx, my = mp.get_mouse_pos()
  local ow, oh = mp.get_property_number('osd-width', 0), mp.get_property_number('osd-height', 0)
  if not mx or ow <= 0 or oh <= 0 then return -1, -1 end
  return mx * W / ow, my * H / oh
end

local function hit_at(x, y)
  for i = #state.hits, 1, -1 do
    local h = state.hits[i]
    if x >= h[1] and x <= h[3] and y >= h[2] and y <= h[4] then return h end
  end
  return nil
end

local function in_panel(x, y)
  local r = state.panel_rect
  return r and x >= r[1] and x <= r[3] and y >= r[2] and y <= r[4]
end

local function on_mouse_move()
  if state.pad ~= 'none' then state.pad = 'none' end
  local was_visible = state.visible
  if not was_visible then state.visible = true; render() end
  local x, y = mouse_xy()
  local h = hit_at(x, y)
  -- With a panel open, only the panel reacts.
  if h and state.panel and not in_panel(x, y) then h = nil end
  local id = h and h.id or nil
  local changed = id ~= state.hover or not was_visible
  state.hover = id
  if id == 'bar' then state.hover_x = x; changed = true else state.hover_x = nil end
  if h and h[6] then h[6]() end
  if changed then render() end
  schedule_hide()
end

mp.add_forced_key_binding('MOUSE_MOVE', 'frame_mouse_move', on_mouse_move)
mp.add_forced_key_binding('MOUSE_LEAVE', 'frame_mouse_leave', function()
  state.hover, state.hover_x = nil, nil
  if state.visible then render() end
  schedule_hide()
end)

mp.add_forced_key_binding('MBTN_LEFT', 'frame_click', function()
  if not state.visible then show(true) return end
  local x, y = mouse_xy()
  if state.panel then
    if in_panel(x, y) then
      local h = hit_at(x, y)
      if h then h[5]() end
    else
      state.panel, state.zone = nil, 'buttons'   -- click outside closes the panel
    end
    show()
    return
  end
  local h = hit_at(x, y)
  if h then h[5]() show() return end
  toggle_pause()
  show()
end)
-- Double-click on the picture (not on a control) switches full screen.
mp.add_forced_key_binding('MBTN_LEFT_DBL', 'frame_dblclick', function()
  local x, y = mouse_xy()
  if state.panel or (state.visible and hit_at(x, y)) then return end
  mp.command('cycle fullscreen')
end)

local function wheel(dir)
  local x, y = mouse_xy()
  if state.panel and in_panel(x, y) then
    local rows = panel_rows()
    state.zone = 'panel'
    state.panel_focus = math.max(1, math.min(#rows, state.panel_focus + dir))
  elseif not state.panel then
    seek_by(dir > 0 and -10 or 10)
  end
  show()
end
mp.add_forced_key_binding('WHEEL_UP', 'frame_wheel_up', function() wheel(-1) end, { repeatable = true })
mp.add_forced_key_binding('WHEEL_DOWN', 'frame_wheel_down', function() wheel(1) end, { repeatable = true })

-- Keep the clock and progress bar current while the controls are up.
mp.add_periodic_timer(0.25, function() if state.visible then render() end end)
mp.observe_property('pause', 'bool', function(_, paused)
  if paused then show() else schedule_hide() end
end)
mp.register_event('file-loaded', function() show(true) end)
-- Frame's news (who's in the room, waiting for everyone): redraw so it shows at once.
mp.observe_property('user-data/frame/info', 'native', function() render() end)
-- Keep 1080 units of height and widen or narrow the canvas to the window's shape, so the
-- controls never stretch and the mouse lines up exactly with what's drawn.
mp.observe_property('osd-dimensions', 'native', function(_, d)
  if d and d.w and d.h and d.w > 0 and d.h > 0 then
    W = math.floor(H * d.w / d.h + 0.5)
    overlay.res_x = W
  end
  render()
end)
