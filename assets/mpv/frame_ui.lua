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
  visible = false,
  loading = true,        -- the loading screen, until the video starts (see below)
  loading_fade = nil,    -- when the fade into the video began
  zone = 'buttons',      -- back | bar | buttons | panel
  button = 6,            -- which bottom button has focus (6 = play)
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
local frame_pad = 'none' -- the controller style Frame last told us (state.pad may be hidden since)

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

-- Where the last jump went, so presses in quick succession (holding skip) add up even while
-- mpv is still getting there.
local pending_pos, pending_at = nil, 0

local function seek_by(sec)
  if in_room() then
    local base = mp.get_property_number('time-pos', 0) or 0
    if pending_pos and mp.get_time() - pending_at < 1.5 then base = pending_pos end
    local dur = mp.get_property_number('duration', 0) or 0
    local p = math.max(0, base + sec)
    if dur > 0 then p = math.min(p, dur - 1) end
    pending_pos, pending_at = p, mp.get_time()
    request('sync', { op = 'seek', pos = p })
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
    table.insert(rows, { 'Server version · converted, smoothest', mode == 'server', function() request('mode', 'server') end })
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
    -- Style, remembered by Frame for every video: small choices in a row under the tracks.
    local scale, pos, box = sub_style()
    local function style(label, group, on, scale2, pos2, box2)
      table.insert(rows, { label, on, function()
        request('style', { scale = scale2, pos = pos2, box = box2 })
      end, style = true, group = group, stay = true })
    end
    for _, sz in ipairs({ { 'Small', 0.8 }, { 'Medium', 1.0 }, { 'Large', 1.3 } }) do
      style(sz[1], 'Size', math.abs(scale - sz[2]) < 0.05, sz[2], pos, box)
    end
    style('Bottom', 'Position', pos >= 99, scale, 100, box)
    style('Higher', 'Position', pos < 99, scale, 88, box)
    style('Off', 'Background', not box, scale, pos, false)
    style('Box', 'Background', box, scale, pos, true)
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

-- The player's sheet (Audio, Subtitles, Playback): slides up from the bottom like Frame's
-- menus. The progress bar stays on top of it, tabs switch with L1 / R1, tracks are big cards
-- in a row (left / right), and the subtitle style is a row of small choices under them.
local SHEET = '1B1512' -- #12151B
local tabs = { { 'audio', 'Audio' }, { 'subtitles', 'Subtitles' }, { 'playback', 'Playback' } }

local function is_card(row) return row and not row.style end

-- Shortens text to n characters (counting accented letters as one) with an ellipsis.
local function shorten(s, n)
  local out, count = {}, 0
  for ch in (s or ''):gmatch('[%z\1-\127\194-\244][\128-\191]*') do
    count = count + 1
    if count > n then return table.concat(out) .. '…' end
    out[#out + 1] = ch
  end
  return table.concat(out)
end

-- A selected item's ring: a dark gap, then white, like everything selected in Frame.
local function ring(ass, x0, y0, x1, y1, r)
  rect(ass, x0 - 9, y0 - 9, x1 + 9, y1 + 9, r + 9, FG, '00')
  rect(ass, x0 - 4, y0 - 4, x1 + 4, y1 + 4, r + 4, SHEET, '00')
end

-- What's in use, for the line under each tab on the bar.
function utf8_len(str)
  local n = 0
  for _ in (str or ''):gmatch('[%z\1-\127\194-\244][\128-\191]*') do n = n + 1 end
  return n
end

function current_value(name)
  if name == 'info' then return state.info.quality or '' end
  if name == 'playback' then
    local mode = state.info.mode or 'auto'
    return ({ auto = 'Automatic', original = 'Original', server = 'Server version' })[mode] or ''
  end
  local saved = state.panel
  state.panel = name
  local rows = panel_rows()
  state.panel = saved
  for _, r in ipairs(rows) do
    if not r.style and r[2] then
      local main = r[1] or ''
      local cut = main:find(' · ', 1, true)
      if cut then
        local rest = main:sub(cut + 4)
        local second = rest:find(' · ', 1, true)
        main = main:sub(1, cut - 1) .. ' · ' .. (second and rest:sub(1, second - 1) or rest)
      end
      return shorten(main, 20)
    end
  end
  return name == 'subtitles' and 'Off' or ''
end

-- Opens a sheet tab with the focus on what's in use (the current track or mode).
function open_panel(name)
  state.panel, state.zone, state.panel_focus, state.panel_first = name, 'panel', 1, 1
  for i, r in ipairs(panel_rows()) do
    if not r.style and r[2] then state.panel_focus = i break end
  end
end

local function draw_panel(ass)
  local rows = panel_rows()
  local has_style = false
  for _, r in ipairs(rows) do if r.style then has_style = true end end
  if state.panel_focus > #rows then state.panel_focus = #rows end
  if state.panel_focus < 1 then state.panel_focus = 1 end

  local top = H - (has_style and 600 or 500)
  state.panel_rect = { 0, top, W, H }
  hit('sheet', 0, top, W, H, function() end)   -- empty parts of the sheet do nothing
  rect(ass, 0, 0, W, H, 0, '000000', 'C0')                         -- dim the video
  rect(ass, 0, top, W, H + 60, 36, SHEET, '50')                     -- the sheet
  rect(ass, 0, top, W, top + 1, 0, FG, 'EB')

  -- Progress, so you never lose your place
  local pos = mp.get_property_number('time-pos', 0) or 0
  local dur = mp.get_property_number('duration', 0) or 0
  local py = top + 54
  text(ass, 56, py, 4, BODY, 22, 600, SOFT, clock(pos))
  text(ass, W - 56, py, 6, BODY, 22, 600, SOFT, '-' .. clock(math.max(0, dur - pos)))
  local bx0, bx1 = 150, W - 150
  rect(ass, bx0, py - 3, bx1, py + 3, 3, FG, 'D1')
  if dur > 0 then rect(ass, bx0, py - 3, bx0 + (bx1 - bx0) * math.min(1, pos / dur), py + 3, 3, FG, '00') end

  -- Tabs
  local tx, ty = 56, top + 110
  for _, t in ipairs(tabs) do
    local w = 48 + #t[2] * 13
    local on = state.panel == t[1]
    if on then rect(ass, tx, ty, tx + w, ty + 56, 28, FG, 'D6') end
    text(ass, tx + w / 2, ty + 28, 5, BODY, 24, on and 700 or 600, on and FG or SOFT, t[2])
    local name = t[1]
    hit('tab' .. name, tx, ty, tx + w, ty + 56, function()
      open_panel(name)
    end)
    tx = tx + w + 10
  end

  -- Cards
  local cards = {}
  for i, r in ipairs(rows) do if is_card(r) then cards[#cards + 1] = i end end
  local cw, ch, gap = 300, 150, 24
  local fit = math.floor((W - 112 + gap) / (cw + gap))
  local focus_card = 1
  for n, i in ipairs(cards) do if i == state.panel_focus then focus_card = n end end
  local first = state.panel_first or 1
  if is_card(rows[state.panel_focus]) then
    if focus_card < first then first = focus_card end
    if focus_card > first + fit - 1 then first = focus_card - fit + 1 end
  end
  first = math.max(1, math.min(first, math.max(1, #cards - fit + 1)))
  state.panel_first = first
  local cy0 = top + 200
  local x = 56
  for n = first, math.min(#cards, first + fit - 1) do
    local i = cards[n]
    local row = rows[i]
    local focused = state.zone == 'panel' and state.panel_focus == i
    if focused then ring(ass, x, cy0, x + cw, cy0 + ch, 26) end
    rect(ass, x, cy0, x + cw, cy0 + ch, 26, FG, focused and '00' or (row[2] and 'D1' or 'EB'))
    local main, rest = row[1], ''
    local cut = (row[1] or ''):find(' · ', 1, true)
    if cut then main, rest = row[1]:sub(1, cut - 1), row[1]:sub(cut + 4) end
    local colour = focused and BG or FG
    text(ass, x + 24, cy0 + 28, 7, BODY, 26, (focused or row[2]) and 700 or 600, colour, shorten(main, 18))
    if rest ~= '' then
      text(ass, x + 24, cy0 + ch - 26, 1, BODY, 20, 500, focused and '50423B' or MUTED, shorten(rest, 26))
    end
    if row[2] then draw_check(ass, x + cw - 50, cy0 + 44, colour) end
    local idx = i
    local function focus() state.zone, state.panel_focus = 'panel', idx end
    hit('row' .. i, x, cy0, x + cw, cy0 + ch, function() focus(); choose(rows, idx) end, focus)
    x = x + cw + gap
  end
  if #cards == 0 then
    text(ass, 56, cy0 + 40, 4, BODY, 24, 500, MUTED,
      state.panel == 'audio' and 'This video has no sound tracks.' or 'Nothing to choose here.')
  end
  if #cards > first + fit - 1 then text(ass, W - 40, cy0 + ch / 2, 6, BODY, 40, 600, MUTED, '›') end
  if first > 1 then text(ass, 30, cy0 + ch / 2, 4, BODY, 40, 600, MUTED, '‹') end

  if state.panel == 'playback' then
    text(ass, 56, cy0 + ch + 44, 4, BODY, 20, 500, MUTED,
      state.info.server and 'Now playing the version your server converts on the NAS.'
        or 'Now playing the original file, straight from the NAS.')
  end

  -- Subtitle style: small pills in groups (Size, Position, Background)
  if has_style then
    local sy = cy0 + ch + 56
    local sx = 56
    local last_group = nil
    for i, r in ipairs(rows) do
      if r.style then
        if r.group ~= last_group then
          if last_group then sx = sx + 30 end
          text(ass, sx, sy + 24, 4, BODY, 21, 500, MUTED, r.group)
          sx = sx + 20 + #r.group * 11
          last_group = r.group
        end
        local w = 44 + #r[1] * 12
        local focused = state.zone == 'panel' and state.panel_focus == i
        if focused then ring(ass, sx, sy, sx + w, sy + 48, 24) end
        rect(ass, sx, sy, sx + w, sy + 48, 24, FG, focused and '00' or (r[2] and 'C4' or 'EB'))
        text(ass, sx + w / 2, sy + 24, 5, BODY, 21, (focused or r[2]) and 700 or 600, focused and BG or FG, r[1])
        local idx = i
        local function focus() state.zone, state.panel_focus = 'panel', idx end
        hit('row' .. i, sx, sy, sx + w, sy + 48, function() focus(); choose(rows, idx) end, focus)
        sx = sx + w + 10
      end
    end
  end
end

-- ---------- The controls ----------

-- Left to right as they sit on the bar: the tabs, then -10, play, +30.
local buttons = { 'audio', 'subtitles', 'playback', 'info', 'rew', 'play', 'ff' }
local PLAY = 6

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
    items = { { 'select', 'Select' }, { 'skip', 'Switch' }, { 'back', 'Close' } }
  else
    items = { { 'select', 'Select' }, { 'menu', 'Play/Pause' }, { 'skip', 'Skip' }, { 'back', 'Exit' } }
  end
  -- measure roughly: glyph 30 + gap 10 + label ~11 px per character + 26 between items
  local width = 36
  for _, it in ipairs(items) do width = width + 30 + 10 + #it[2] * 11 + 26 + (it[1] == 'skip' and 40 or 0) end
  -- Bottom left, on the same line as the buttons: the right side holds Playback, Audio,
  -- Subtitles and Info, and the middle holds play and the skips.
  -- On the right of the bar (or of the open sheet), level with the buttons
  local x0, y0 = W - 48 - width, H - 90 - 25
  if state.panel then y0 = H - 36 - 50 end
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

-- ---------- Up next ----------
-- Near the end of an episode: a card with the next one. Cross plays it now, Circle hides it.
-- Frame sends the title and, when the server knows where the credits start, from when.

local function up_next()
  local n = state.info.next
  if type(n) ~= 'table' or state.next_hidden then return nil end
  local dur = mp.get_property_number('duration', 0) or 0
  if dur < 60 then return nil end
  local pos = mp.get_property_number('time-pos', 0) or 0
  local at = tonumber(n.at) or (dur - 30)
  if pos < at then return nil end
  return n, math.max(0, dur - pos), math.max(1, dur - at)
end

local function draw_up_next(ass)
  local n, left, span = up_next()
  if not n or state.panel then return end
  local w, h = 600, 160
  local x1 = W - 56
  local y1 = state.visible and (H - 250) or (H - 56)
  local x0, y0 = x1 - w, y1 - h
  glass(ass, x0, y0, x1, y1, 14, nil, true)
  text(ass, x0 + 28, y0 + 34, 4, BODY, 15, 700, MUTED, 'UP NEXT')
  text(ass, x0 + 28, y0 + 66, 4, BODY, 24, 700, FG, n.title or 'Next episode')
  -- Play now: a white pill with a play shape
  local px0, py0, px1, py1 = x0 + 24, y0 + 96, x0 + 210, y0 + 140
  rect(ass, px0, py0, px1, py1, 22, FG, '00')
  path(ass, BG, { { px0 + 26, py0 + 12 }, { px0 + 44, py0 + 22 }, { px0 + 26, py0 + 32 } })
  text(ass, px0 + 56, (py0 + py1) / 2, 4, BODY, 20, 700, BG, 'Play now')
  hit('next', px0, py0, px1, py1, function() request('next') end)
  -- what the controller buttons do here (only while the controls are hidden)
  if not state.visible and state.pad ~= 'none' then
    local ps = state.pad == 'ps'
    text(ass, px1 + 24, (py0 + py1) / 2, 4, BODY, 18, 600, SOFT,
      (ps and '✕' or 'A') .. ' Play now     ' .. (ps and '○' or 'B') .. ' Hide')
  end
  -- the line runs down to the end of the episode, when the next one starts by itself
  rect(ass, x0 + 6, y1 - 4, x1 - 6, y1, 0, FG, 'EB')
  local lw = (x1 - x0 - 12) * math.max(0, math.min(1, left / span))
  if lw > 1 then rect(ass, x0 + 6, y1 - 4, x0 + 6 + lw, y1, 0, accent_colour(), '00') end
end

-- The loading screen. Frame shows the same one before the player opens (the title logo
-- centred in a 900 x 160 box at y = 500, the line under it at y = 620, a thin running line at
-- y = 680), so going from Frame to the player can't be seen. Frame places the logo itself (a
-- picture, which these controls can't draw) and says so with info.logo; without one, the
-- title is written in its place. When the video starts, the screen fades into it.
local started = mp.get_time()
local function draw_loading(ass)
  local a = 0
  if state.loading_fade then a = math.min(1, (mp.get_time() - state.loading_fade) / 0.5) end
  local function alpha(base) -- base see-through (0-255), faded further as the screen goes
    return string.format('%02X', math.floor(base + (255 - base) * a))
  end
  rect(ass, 0, 0, W, H, 0, BG, alpha(0))
  -- (while Frame is still preparing the logo, briefly nothing, rather than the title flashing)
  local waiting_logo = state.info.logo_coming and mp.get_time() - started < 2
  if not state.info.logo and not waiting_logo then
    text(ass, W / 2, 500, 5, DISPLAY, 64, 700, FG, state.info.title or mp.get_property('media-title') or '', alpha(0))
  end
  local line = state.info.loading_line
  if line and line ~= '' then text(ass, W / 2, 621, 5, BODY, 26, 500, SOFT, line, alpha(0)) end
  -- a short accent segment running along a faint track, like Frame's
  local x0, x1, y = W / 2 - 120, W / 2 + 120, 680
  rect(ass, x0, y - 2, x1, y + 2, 2, FG, alpha(225))
  local t = (mp.get_time() % 1.6) / 1.6
  local s0 = x0 + (x1 - x0) * math.max(0, t * 1.4 - 0.4)
  local s1 = x0 + (x1 - x0) * math.min(1, t * 1.4)
  if s1 - s0 > 2 then rect(ass, s0, y - 2, s1, y + 2, 2, accent_colour(), alpha(0)) end
end

local function render()
  state.hits = {}
  state.panel_rect = nil
  local ass = assdraw.ass_new()
  if state.loading or state.loading_fade then
    draw_loading(ass)
    overlay.data = ass.text
    overlay:update()
    return
  end
  if state.visible then
    local pos = mp.get_property_number('time-pos', 0) or 0
    local dur = mp.get_property_number('duration', 0) or 0
    local cached = mp.get_property_number('demuxer-cache-time', 0) or 0

    shade(ass, 0, 230, false)
    shade(ass, H - 330, H, true)   -- keeps the see-through sheet readable over bright scenes

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

    if not state.panel then   -- with a sheet open, the sheet has its own progress bar
    -- The bar: the same sheet as Audio / Subtitles, folded down. Choosing a tab grows it.
    local top = H - 250
    rect(ass, 0, top, W, H + 60, 36, SHEET, '6A')
    rect(ass, W / 2 - 32, top + 10, W / 2 + 32, top + 15, 2.5, FG, 'BF')   -- handle: it opens further
    hit('sheet_bar', 0, top, W, H, function() end)

    -- Progress bar, in the same place as on the open sheet
    local bx0, bx1, by = 150, W - 150, top + 54
    local bar_focus = state.zone == 'bar'
    local th = bar_focus and 10 or 6
    rect(ass, bx0, by - th / 2, bx1, by + th / 2, th / 2, FG, 'D1')
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

    -- Times either side of the bar; when it ends, top right under the quality
    local left = math.max(0, dur - pos)
    text(ass, 56, by, 4, BODY, 22, 600, SOFT, clock(pos))
    text(ass, W - 56, by, 6, BODY, 22, 600, SOFT, '-' .. clock(left))
    if dur > 0 then
      local speed = mp.get_property_number('speed', 1) or 1
      text(ass, W - 56, state.info.quality and 96 or 66, 6, BODY, 20, 500, MUTED,
        'Ends at ' .. os.date('%H:%M', os.time() + math.floor(left / speed)))
    end

    -- Tabs on the left, each with what's in use underneath
    local cy = top + 160
    local tx = 56
    for i = 1, 4 do
      local name = buttons[i]
      local label = ({ audio = 'Audio', subtitles = 'Subtitles', playback = 'Playback', info = 'Info' })[name]
      local value = current_value(name)
      local w = 44 + math.max(#label * 12, utf8_len(value) * 8.5)
      local focused = state.zone == 'buttons' and state.button == i
      if focused then ring(ass, tx, cy - 38, tx + w, cy + 38, 24) end
      if focused then rect(ass, tx, cy - 38, tx + w, cy + 38, 24, FG, '00')
      elseif name == 'info' and state.info_box then rect(ass, tx, cy - 38, tx + w, cy + 38, 24, FG, 'E6') end
      text(ass, tx + 22, cy - 2, 1, BODY, 23, 700, focused and BG or FG, label)
      if value ~= '' then text(ass, tx + 22, cy + 2, 7, BODY, 18, 500, focused and '50423B' or MUTED, value) end
      local idx = i
      hit('btn' .. i, tx, cy - 38, tx + w, cy + 38, function() state.zone, state.button = 'buttons', idx; activate() end,
        function() state.zone, state.button = 'buttons', idx end)
      tx = tx + w + 6
    end

    -- -10, play, +30 in the middle
    local centre = { { 5, W / 2 - 100, 64 }, { 6, W / 2, 84 }, { 7, W / 2 + 100, 64 } }
    for _, b in ipairs(centre) do
      local i = b[1]
      local focused = state.zone == 'buttons' and state.button == i
      if focused then
        local r = b[3] / 2
        rect(ass, b[2] - r - 9, cy - r - 9, b[2] + r + 9, cy + r + 9, r + 9, FG, '00')
        rect(ass, b[2] - r - 4, cy - r - 4, b[2] + r + 4, cy + r + 4, r + 4, SHEET, '00')
      end
      draw_button(ass, buttons[i], b[2], cy, b[3], focused)
      local idx = i
      hit('btn' .. i, b[2] - b[3] / 2, cy - b[3] / 2, b[2] + b[3] / 2, cy + b[3] / 2, function() state.zone, state.button = 'buttons', idx; activate() end,
        function() state.zone, state.button = 'buttons', idx end)
    end

    end

    room_people(ass)
    if state.info_box then info_box(ass) end
    if state.panel then draw_panel(ass) end
    pad_legend(ass)
  end
  draw_up_next(ass)
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
    if focus_play then state.zone, state.button = 'buttons', PLAY end
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
  else open_panel(b) end
  show()
end

local function key(k)
  -- Still loading: only Back works (it leaves, like backing out of Frame's loading screen).
  if state.loading then
    if k == 'back' then mp.command('quit') end
    return
  end
  -- Keyboard or controller in use: the mouse no longer holds the controls open.
  state.hover, state.hover_x = nil, nil
  -- Up next showing over the picture: Cross plays it, Circle hides the card.
  if not state.visible and up_next() then
    if k == 'select' then request('next') return end
    if k == 'back' then
      state.next_hidden = true
      request('next_dismiss')
      render()
      return
    end
  end
  if not state.visible then
    if k == 'left' or k == 'rew' then seek_by(-10)
    elseif k == 'right' or k == 'ff' then seek_by(30)
    elseif k == 'back' then show(true) return   -- one Back shows the controls; a second one leaves
    elseif k == 'playpause' then toggle_pause()
    elseif k == 'info' then state.info_box = not state.info_box end
    show(true)
    return
  end
  if k == 'playpause' then toggle_pause() show() return end
  if state.panel and (k == 'rew' or k == 'ff') then
    local at = 1
    for i, t in ipairs(tabs) do if t[1] == state.panel then at = i end end
    at = at + (k == 'ff' and 1 or -1)
    if at < 1 then at = #tabs elseif at > #tabs then at = 1 end
    open_panel(tabs[at][1])
    show()
    return
  end
  if k == 'rew' then seek_by(-10) show() return end
  if k == 'ff' then seek_by(30) show() return end
  if k == 'info' then state.info_box = not state.info_box show() return end

  if state.zone == 'panel' then
    local rows = panel_rows()
    local cur = rows[state.panel_focus]
    local on_style = cur and cur.style
    -- the row the focus is on: the track cards, or the style choices under them
    local same = {}
    for i, r in ipairs(rows) do if (r.style and true or false) == (on_style and true or false) then same[#same + 1] = i end end
    local at = 1
    for n, i in ipairs(same) do if i == state.panel_focus then at = n end end
    if k == 'left' then state.panel_focus = same[math.max(1, at - 1)] or state.panel_focus
    elseif k == 'right' then state.panel_focus = same[math.min(#same, at + 1)] or state.panel_focus
    elseif k == 'down' and not on_style then
      for i, r in ipairs(rows) do
        if r.style then
          state.last_card = state.panel_focus
          -- land on the choice in use in the first group (the current size)
          state.panel_focus = i
          for j = i, #rows do if rows[j].style and rows[j].group == r.group and rows[j][2] then state.panel_focus = j break end end
          break
        end
      end
    elseif k == 'up' and on_style then
      local back = state.last_card
      if not (rows[back] and not rows[back].style) then
        back = 1
        for i, r in ipairs(rows) do if not r.style and r[2] then back = i break end end
      end
      state.panel_focus = back
    elseif k == 'back' then state.panel = nil; state.zone = 'buttons'
    elseif k == 'select' then choose(rows, state.panel_focus)
    end
    show()
    return
  end

  if k == 'back' then mp.command('quit') return end
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

-- Buttons from Frame come from the controller. If the mouse or keyboard hid the controller
-- legend meanwhile, bring it back: Frame never saw those mouse/keyboard events (they went to
-- this window), so it still thinks the controller is in use and wouldn't tell us again.
mp.register_script_message('key', function(k)
  if state.pad == 'none' and frame_pad ~= 'none' then state.pad = frame_pad end
  key(k)
end)
mp.register_script_message('pad', function(style) state.pad = style or 'none'; frame_pad = state.pad; render() end)
-- Read as 'native': read as a string, mpv hands user-data back as JSON ('"ps"', with quotes),
-- which never matched 'ps', so the PlayStation symbols were never drawn.
mp.observe_property('user-data/frame/pad', 'native', function(_, style)
  if type(style) == 'string' and style ~= '' then state.pad = style; frame_pad = style; render() end
end)
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

-- Real mouse use switches the legend off; a pointer resting over the video or a light touch of
-- a controller's trackpad doesn't (it needs a good 200 px of movement, like in Frame).
local mouse_last, mouse_travel = nil, 0

local function on_mouse_move()
  if state.loading then return end
  if state.pad ~= 'none' then
    local mx, my = mp.get_mouse_pos()
    if mx and mouse_last then
      mouse_travel = mouse_travel + math.abs(mx - mouse_last[1]) + math.abs(my - mouse_last[2])
    end
    mouse_last = mx and { mx, my } or nil
    if mouse_travel < 200 then return end
    state.pad = 'none'
  end
  mouse_travel = 0
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
  if state.loading then return end
  if not state.visible then
    local h = hit_at(mouse_xy())
    if h and h.id == 'next' then h[5]() return end
    show(true)
    return
  end
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
-- (and the Up next card, which also shows while the controls are hidden)
local up_next_shown = false
mp.add_periodic_timer(0.25, function()
  local showing = up_next() ~= nil
  if state.visible or showing or up_next_shown then render() end
  up_next_shown = showing
end)
mp.observe_property('pause', 'bool', function(_, paused)
  if state.loading then return end
  if paused then show() else schedule_hide() end
end)

-- Loading: redraw often so the line runs, until the first picture is on screen; then fade
-- into the video and bring up the controls for a moment, as before.
local loading_timer = mp.add_periodic_timer(0.04, function() render() end)
local function finish_loading()
  if not state.loading then return end
  state.loading, state.loading_fade = false, mp.get_time()
  state.logo_gone = true
  request('loaded', true) -- Frame takes its logo off (a picture can't fade with the rest)
  mp.add_timeout(0.5, function()
    state.loading_fade = nil
    loading_timer:kill()
    state.zone, state.button = 'buttons', PLAY
    show(true)
  end)
end
mp.register_event('playback-restart', finish_loading)
mp.add_timeout(20, finish_loading) -- never stuck behind the loading screen
-- A different video in the same player (a room moving on): back to the loading screen.
mp.register_event('start-file', function()
  if state.loading_fade then return end
  if mp.get_property_native('playlist-pos', 0) > 0 or state.logo_gone then
    state.loading, state.visible, state.panel = true, false, nil
    state.info.logo, state.info.logo_coming = false, false -- the logo was for the first video
    loading_timer:resume()
  end
end)
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
