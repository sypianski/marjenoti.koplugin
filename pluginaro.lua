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
-- Provided implementations (host → provider call channel)
--
-- Some integrations flow "backwards": the *provider* owns the event
-- source (e.g. kopad receives the gamepad input) while the *host* owns
-- the reaction (visel moves its selection). For those, the host publishes
-- an implementation table with Pluginaro.provide(...) and the provider
-- calls into it with Pluginaro.call_provided(...). call_provided returns
-- nil — without touching the implementation — unless the extension's
-- opt-in toggle is ON, so routing stays disabled-by-default like
-- everything else in the registry.
--
-- Zero hard dependency both ways: provide without a matching register is
-- fine (nobody ever calls), call_provided without a provide returns nil
-- (caller falls back to its own behaviour).
----------------------------------------------------------------------

local function provided_registry()
    _G._pluginaro_provided = _G._pluginaro_provided or {}
    return _G._pluginaro_provided
end

--- Publish an implementation table for one extension. Called from the
-- host plugin (usually at init). Re-providing replaces the previous
-- table — plugin reloads produce fresh closures, that's expected.
-- @return true on success; nil, err on invalid arguments.
function Pluginaro.provide(host, provider, id, impl)
    local function fail(err)
        logger.warn("pluginaro: provide rejected: " .. err)
        return nil, err
    end
    if type(host) ~= "string" or host == "" then
        return fail("host must be a non-empty string")
    end
    if type(provider) ~= "string" or provider == "" then
        return fail("provider must be a non-empty string")
    end
    if type(id) ~= "string" or not id:match("^[a-z_]+$") then
        return fail("invalid id: must be a string matching ^[a-z_]+$")
    end
    if type(impl) ~= "table" then
        return fail("impl must be a table")
    end
    provided_registry()[reg_key(host, provider, id)] = impl
    return true
end

--- Call one method of a provided implementation. Called from the
-- provider plugin, typically per event. Returns nil (without calling
-- anything) when the opt-in toggle is OFF, nothing was provided, the
-- method is missing, or the implementation errors (pcall'd + logged) —
-- in every such case the caller just keeps its own default behaviour.
function Pluginaro.call_provided(host, provider, id, method, ...)
    if not Pluginaro.is_enabled(host, provider, id) then return nil end
    local impl = provided_registry()[reg_key(host, provider, id)]
    if type(impl) ~= "table" then return nil end
    local fn = impl[method]
    if type(fn) ~= "function" then return nil end
    local ok, res = pcall(fn, ...)
    if not ok then
        logger.warn("pluginaro: provided method "
            .. settings_key(host, provider, id) .. "." .. tostring(method)
            .. " failed: " .. tostring(res))
        return nil
    end
    return res
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

----------------------------------------------------------------------
-- Family overlay claim (ui._kokb_overlay)
--
-- Family overlays (visel, hilite, kopad's selector) are plain widgets —
-- not Menu/dialog subclasses — so is_modal_active() cannot see them.
-- They coordinate through a single ownership flag on the ReaderUI
-- instance instead: `ui._kokb_overlay` holds the NAME of the overlay
-- that currently owns the screen (nil = none).
--
-- Contract:
--   • Every family overlay claims the flag when it opens
--     (claim_overlay) and releases it when it closes (release_overlay).
--   • claim succeeds only when the flag is free or already held by the
--     same name (re-claim is idempotent). A refused claim means another
--     family overlay is up — do not open on top of it.
--   • release clears the flag ONLY when `name` is the current owner, so
--     a stale close from overlay A can never drop overlay B's claim.
--   • Global-shortcut guards call overlay_active(ui) alongside
--     is_modal_active(): reader-level shortcuts stand down while any
--     family overlay is up. An overlay's OWN key_events are unaffected —
--     its controller sits in front of the global handlers in
--     active_widgets and consumes its keys first.
--   • The flag lives on the ui instance (not in this module), so every
--     plugin's verbatim pluginaro copy sees the same state.
----------------------------------------------------------------------

--- True while a family overlay holds the claim on this ui.
-- @param ui table — the ReaderUI/FileManager instance the caller runs in.
-- @param except (optional) string — a claim held by `except` itself does
--   NOT count (used by kopad's gamepad handlers, which must keep driving
--   kopad's own overlay while standing down under anyone else's).
function Pluginaro.overlay_active(ui, except)
    if type(ui) ~= "table" then return false end
    local owner = ui._kokb_overlay
    if owner == nil or owner == false or owner == "" then return false end
    if except ~= nil and owner == except then return false end
    return true
end

--- Claim the overlay flag for `name`. Returns true when claimed (or
-- already held by `name`); false when another overlay holds it — the
-- caller must then refrain from opening.
function Pluginaro.claim_overlay(ui, name)
    if type(ui) ~= "table" then return false end
    if type(name) ~= "string" or name == "" then return false end
    local owner = ui._kokb_overlay
    if owner ~= nil and owner ~= false and owner ~= "" and owner ~= name then
        return false
    end
    ui._kokb_overlay = name
    return true
end

--- Release the overlay flag — but only when `name` is the current owner.
-- Returns true when released; false when the flag was free or held by
-- someone else (in which case it is left untouched).
function Pluginaro.release_overlay(ui, name)
    if type(ui) ~= "table" then return false end
    if ui._kokb_overlay ~= name then return false end
    ui._kokb_overlay = nil
    return true
end

--- Build the „Rozszerzenia" sub_item_table for a given plugin.
--
-- Scans every registration where `self_name` appears as host OR provider
-- and emits one menu row per registration:
--
--   Toggle row — when `self_name` is the `menu_location` side:
--     • menu_location = 'host'     → self is the host plugin
--     • menu_location = 'provider' → self is the provider plugin
--     • menu_location = 'both'     → self is either (toggle in both)
--   Rendered as a checkable item; callback flips set_enabled.
--
--   Annotation row — when `self_name` is the OTHER side:
--     • non-clickable (enabled_func → false); carries help_text naming where
--       the toggle actually lives: „Włącz w: Ustawienia <other> → Rozszerzenia"
--
-- @param self_name  string — name of the calling plugin (e.g. "kopad")
-- @param label_prefix  (optional) string prepended to each row label;
--   used by the keyreader host to prefix visel registrations ("visel: ").
-- @return array — empty when nothing is registered involving self_name.
function Pluginaro.build_ext_menu(self_name, label_prefix)
    if type(self_name) ~= "string" or self_name == "" then return {} end
    label_prefix = (type(label_prefix) == "string" and label_prefix) or ""

    local rows = {}
    -- Sort for deterministic menu order: (section, host, id)
    local relevant = {}
    for _, entry in pairs(registry()) do
        if entry.host == self_name or entry.provider == self_name then
            relevant[#relevant + 1] = entry
        end
    end
    table.sort(relevant, function(a, b)
        local sa, sb = a.section or "", b.section or ""
        if sa ~= sb then return sa < sb end
        if a.host ~= b.host then return a.host < b.host end
        return a.id < b.id
    end)

    for _, entry in ipairs(relevant) do
        local host     = entry.host
        local provider = entry.provider
        local id       = entry.id
        local label    = label_prefix .. (entry.label or (provider .. " → " .. id))
        local ml       = entry.menu_location or "host"

        -- Determine whether self is the toggle side.
        local self_is_toggle_side
        if ml == "both" then
            self_is_toggle_side = (self_name == host or self_name == provider)
        elseif ml == "host" then
            self_is_toggle_side = (self_name == host)
        elseif ml == "provider" then
            self_is_toggle_side = (self_name == provider)
        else
            self_is_toggle_side = (self_name == host)
        end

        if self_is_toggle_side then
            -- Toggle row
            local h, p, i = host, provider, id  -- local captures for closures
            rows[#rows + 1] = {
                text_func = function()
                    return label
                end,
                checked_func = function()
                    return Pluginaro.is_enabled(h, p, i)
                end,
                callback = function()
                    local now = Pluginaro.is_enabled(h, p, i)
                    Pluginaro.set_enabled(h, p, i, not now)
                end,
                keep_menu_open = true,
            }
        else
            -- Annotation / signpost row (non-clickable)
            -- The toggle lives on the "other" side: if self is provider,
            -- the toggle is in the host's menu (and vice-versa for
            -- menu_location='provider').
            local other_plugin
            if ml == "host" then
                -- Toggle lives at host; self is provider → point to host
                other_plugin = host
            elseif ml == "provider" then
                -- Toggle lives at provider; self is host → point to provider
                other_plugin = provider
            else
                -- Fallback
                other_plugin = (self_name == host) and provider or host
            end
            rows[#rows + 1] = {
                text = "ℹ " .. label,
                enabled_func = function() return false end,
                help_text = "Włącz w: Ustawienia " .. other_plugin
                            .. " → Rozszerzenia",
            }
        end
    end

    return rows
end

return Pluginaro
