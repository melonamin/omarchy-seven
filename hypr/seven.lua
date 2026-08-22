-- Runtime shortcut registration for melonamin.seven. Loaded with
-- `hyprctl eval`; it never edits a Hyprland configuration file.
--
-- The binding carries a description so it shows up in Omarchy's keybindings
-- menu (SUPER + K), which reads `hyprctl binds` and keeps any Lua bind that
-- has one.

_G.omarchy_seven = _G.omarchy_seven or {}
local S = _G.omarchy_seven
S.handles = S.handles or {}
S.installed = S.installed or false
S.shortcut = S.shortcut or nil

local DESCRIPTION = "Seven notes"

local function release_handles()
  for _, handle in ipairs(S.handles) do
    pcall(function() handle:unbind() end)
  end
  S.handles = {}
  S.installed = false
  S.shortcut = nil
end

function S.uninstall()
  release_handles()
  return "uninstalled"
end

function S.install(shortcut, force)
  shortcut = tostring(shortcut or "")

  -- A config reload has already discarded the compositor-side handles. Forget
  -- the stale references without calling unbind on them, then bind again.
  if force then
    S.handles = {}
    S.installed = false
    S.shortcut = nil
  elseif S.installed and S.shortcut == shortcut then
    return "already"
  else
    release_handles()
  end

  S.installed = true
  S.shortcut = shortcut
  if shortcut == "" then return "disabled" end

  local handle = hl.bind(shortcut, function()
    hl.exec_cmd("omarchy-shell -q seven toggle")
  end, { description = DESCRIPTION })
  table.insert(S.handles, handle)
  return "installed"
end
