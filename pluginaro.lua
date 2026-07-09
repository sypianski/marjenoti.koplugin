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

--- Stub — Task 2 fills in UIManager._window_stack introspection.
-- Until then no key is ever considered blocked by a modal.
function Pluginaro.is_modal_active()
    return false
end

--- Stub — Task 3 fills in the toggle/signpost menu builder.
-- Returns a sub_item_table-shaped array; empty = caller skips the section.
function Pluginaro.build_ext_menu(...)
    return {}
end

return Pluginaro
