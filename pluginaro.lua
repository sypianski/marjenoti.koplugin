--[[
Pluginaro: opt-in extension registry + keyboard arbitration for the
KOReader plugin family (keyreader+visel, kopad, marjenoti).

Providers register extensions against a host; hosts read the registry
lazily whenever they build their settings menu (order-independent — no
load-order guarantee needed). Every extension is strictly opt-in:
`default_enabled` MUST be literally false, and the enabled flag lives in
G_reader_settings under the string key `<host>.ext.<provider>.<id>`
(absent key = disabled).

The registry itself lives in `_G._pluginaro_registry` so it survives
multiple plugin loads (each family plugin ships its own verbatim copy of
this file — canonical source: lib/pluginaro.lua, propagated by
bin/sync-pluginaro.fish, drift-guarded by .githooks/pre-commit).

KOReader dependencies (G_reader_settings, UIManager) are resolved lazily
through `Pluginaro._deps` so the core is requirable — and unit-testable —
in plain lua/luajit without KOReader (see lib/pluginaro_test.lua, which
injects mock deps before first use).
]]

-- logger is a KOReader module; fall back to a no-op shim so the core
-- loads in a bare Lua interpreter.
local ok_logger, logger = pcall(require, "logger")
if not ok_logger or type(logger) ~= "table" then
    local noop = function() end
    logger = { dbg = noop, info = noop, warn = noop, err = noop }
end

local Pluginaro = {
    _deps = nil,  -- lazy: { settings = G_reader_settings, uimanager = UIManager }
}

-- Resolve KOReader dependencies on first use. Tests set Pluginaro._deps
-- to a mock table before calling anything, so this never fires there.
local function get_deps()
    if not Pluginaro._deps then
        local uimanager
        local ok, mod = pcall(require, "ui/uimanager")
        if ok then uimanager = mod end
        Pluginaro._deps = {
            settings = rawget(_G, "G_reader_settings"),
            uimanager = uimanager,
        }
    end
    return Pluginaro._deps
end

local function registry()
    _G._pluginaro_registry = _G._pluginaro_registry or {}
    return _G._pluginaro_registry
end

local function reg_key(host, provider, id)
    return host .. "\0" .. provider .. "\0" .. id
end

local function settings_key(host, provider, id)
    return host .. ".ext." .. provider .. "." .. id
end

local function copy_opts(opts)
    local out = {}
    for k, v in pairs(opts) do out[k] = v end
    return out
end

-- Payload equality tolerant of plugin reloads: a Reader→FileManager switch
-- reloads plugins, so callbacks are fresh closures on every registration.
-- Function fields therefore compare by *presence* (both sides have one),
-- everything else by value (tables recursively).
local function values_equal(a, b)
    if type(a) == "function" and type(b) == "function" then return true end
    if type(a) ~= type(b) then return false end
    if type(a) == "table" then
        for k, v in pairs(a) do
            if not values_equal(v, b[k]) then return false end
        end
        for k in pairs(b) do
            if a[k] == nil then return false end
        end
        return true
    end
    return a == b
end

--- Register an extension. Called from the provider plugin.
-- @param host string — name of the host plugin (e.g. "visel")
-- @param opts table — id, provider, section, menu_location, label,
--   default_enabled (MUST be literally false), on_enable, on_disable,
--   plus any type-specific hooks (get_targets, on_gamepad_event, …).
-- @return true on success; nil, err on contract violation.
-- Re-registration with an identical payload is a silent OK (replace);
-- a different payload under the same (host, provider, id) warns and
-- replaces anyway — last writer wins.
function Pluginaro.register(host, opts)
    local function fail(err)
        logger.warn("pluginaro: register rejected: " .. err)
        return nil, err
    end
    if type(host) ~= "string" or host == "" then
        return fail("host must be a non-empty string")
    end
    if type(opts) ~= "table" then
        return fail("opts must be a table")
    end
    if opts.default_enabled ~= false then
        return fail("opt-in contract violation: default_enabled must be false")
    end
    if type(opts.id) ~= "string" or not opts.id:match("^[a-z_]+$") then
        return fail("invalid id: must be a string matching ^[a-z_]+$")
    end
    if type(opts.provider) ~= "string" then
        return fail("provider must be a string")
    end

    local reg = registry()
    local key = reg_key(host, opts.provider, opts.id)
    local entry = copy_opts(opts)
    entry.host = host
    local existing = reg[key]
    if existing and not values_equal(existing, entry) then
        logger.warn("pluginaro: re-registration with different payload for "
            .. settings_key(host, opts.provider, opts.id) .. " — last writer wins")
    end
    reg[key] = entry
    return true
end

--- All registrations for a host, sorted by (section, id). Never nil —
-- an empty array means the host skips its „Rozszerzenia" menu section.
function Pluginaro.list_for(host)
    local out = {}
    for _, entry in pairs(registry()) do
        if entry.host == host then
            out[#out + 1] = entry
        end
    end
    table.sort(out, function(a, b)
        local sa, sb = a.section or "", b.section or ""
        if sa ~= sb then return sa < sb end
        if a.id ~= b.id then return a.id < b.id end
        return a.provider < b.provider
    end)
    return out
end

--- Opt-in state from G_reader_settings. Absent key = false (contract).
function Pluginaro.is_enabled(host, provider, id)
    local deps = get_deps()
    if not deps.settings then return false end
    return deps.settings:readSetting(settings_key(host, provider, id)) == true
end

--- Persist the opt-in flag and fire the matching registration callback
-- (on_enable / on_disable). Callback errors are caught (pcall) so a
-- broken extension can't take the settings menu down with it.
function Pluginaro.set_enabled(host, provider, id, enabled)
    enabled = enabled and true or false
    local deps = get_deps()
    if deps.settings then
        deps.settings:saveSetting(settings_key(host, provider, id), enabled)
    end
    local entry = registry()[reg_key(host, provider, id)]
    if entry then
        local cb
        if enabled then cb = entry.on_enable else cb = entry.on_disable end
        if type(cb) == "function" then
            local ok, err = pcall(cb)
            if not ok then
                logger.warn("pluginaro: " .. (enabled and "on_enable" or "on_disable")
                    .. " callback failed for " .. settings_key(host, provider, id)
                    .. ": " .. tostring(err))
            end
        end
    end
end

----------------------------------------------------------------------
-- Keyboard arbitration (modal-aware key routing)
--
-- Family plugins register global shortcuts on ReaderUI.active_widgets.
-- Those handlers fire even when a Menu/dialog is top-of-stack (the key
-- leaks past the modal because the modal didn't declare it). Wrapping a
-- handler with Pluginaro.guard makes it no-op (return false, event flows
-- on) whenever a modal is up or a text input is focused — the modal keeps
-- exclusive keyboard control until it closes.
----------------------------------------------------------------------

-- Modal widget classes, resolved lazily by require so the core still
-- loads in a bare Lua interpreter (each require pcall'd; a missing module
-- just drops out of the set). Subclasses (FileChooser, ToC's Menu,
-- BookmarkList, History, …) extend one of these and are matched by the
-- metatable walk below, so they don't need explicit entries.
Pluginaro.MODAL_CLASS_MODULES = {
    "ui/widget/menu",
    "ui/widget/touchmenu",
    "ui/widget/inputdialog",
    "ui/widget/buttondialog",
    "ui/widget/confirmbox",
    "ui/widget/multiconfirmbox",
    "ui/widget/infomessage",
}

-- Cache of resolved class tables (built once, keyed by the class table).
local modal_classes

local function get_modal_classes()
    if modal_classes then return modal_classes end
    modal_classes = {}
    for _, mod in ipairs(Pluginaro.MODAL_CLASS_MODULES) do
        local ok, cls = pcall(require, mod)
        if ok and type(cls) == "table" then
            modal_classes[cls] = true
        end
    end
    -- Allow tests / callers to inject extra classes directly.
    if type(Pluginaro.MODAL_CLASSES) == "table" then
        for cls in pairs(Pluginaro.MODAL_CLASSES) do
            modal_classes[cls] = true
        end
    end
    return modal_classes
end

-- Reset the memoized class set — used by tests that swap MODAL_CLASSES.
function Pluginaro._reset_modal_cache()
    modal_classes = nil
end

-- True iff `widget`'s class (walking the __index metatable chain) is one
-- of the modal classes. KOReader widgets use `Class:extend{}` which sets
-- each instance's metatable to `{ __index = Class }`, and each Class's
-- metatable to `{ __index = SuperClass }`, so a chain walk covers every
-- subclass without listing them explicitly.
local function is_modal_widget(widget)
    if type(widget) ~= "table" then return false end
    local classes = get_modal_classes()
    if next(classes) == nil then return false end
    local mt = getmetatable(widget)
    local seen = {}
    while type(mt) == "table" do
        local cls = mt.__index
        if type(cls) ~= "table" then break end
        if classes[cls] then return true end
        if seen[cls] then break end
        seen[cls] = true
        mt = getmetatable(cls)
    end
    return false
end

--- True when the top-of-stack widget is a blocking modal (Menu, dialog,
-- popup, …). Family global shortcuts consult this and stand down while it
-- holds, giving the modal exclusive keyboard control.
function Pluginaro.is_modal_active()
    local deps = get_deps()
    local uimanager = deps and deps.uimanager
    if not uimanager then return false end
    local stack = uimanager._window_stack
    if type(stack) ~= "table" then return false end
    local n = #stack
    if n == 0 then return false end
    return is_modal_widget(stack[n].widget)
end

-- Depth-first scan for a focused text input in a widget tree. InputText
-- sets `focused = true` and carries a `charlist` buffer; that pair is the
-- signature. `seen` guards against cyclic widget graphs.
local function has_focused_input(widget, seen)
    if type(widget) ~= "table" then return false end
    seen = seen or {}
    if seen[widget] then return false end
    seen[widget] = true
    if widget.focused and widget.charlist then return true end
    for _, child in ipairs(widget) do
        if has_focused_input(child, seen) then return true end
    end
    return false
end

--- True when the top-of-stack widget contains a focused text input, so a
-- shortcut should yield the keystroke to the editor/search field instead
-- of firing its action. (Migrated from keyremap/palette/wordsearch copies.)
function Pluginaro.input_is_active()
    local deps = get_deps()
    local uimanager = deps and deps.uimanager
    if not uimanager then return false end
    local stack = uimanager._window_stack
    if type(stack) ~= "table" or #stack == 0 then return false end
    return has_focused_input(stack[#stack].widget)
end

--- Wrap a key-event handler so it no-ops (returns false, event flows on)
-- whenever a modal is top-of-stack or a text input is focused. The wrapped
-- handler is otherwise called verbatim (same self + args), so its return
-- value is preserved.
function Pluginaro.guard(handler)
    return function(...)
        if Pluginaro.is_modal_active() or Pluginaro.input_is_active() then
            return false
        end
        return handler(...)
    end
end

--- Stub — Task 3 fills in the toggle/signpost menu builder.
-- Returns a sub_item_table-shaped array; empty = caller skips the section.
function Pluginaro.build_ext_menu(...)
    return {}
end

return Pluginaro
