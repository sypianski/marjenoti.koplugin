--[[
Marjenoti — KOReader plugin.

Shows annotation notes in the right page margin next to their highlights.
Notes are pinned to the highlight's top edge, left-aligned to the margin,
and stack without overlapping. An "L" hairline rule anchors each note like
a gloss in a critical edition.
]]

local Blitbuffer    = require("ffi/blitbuffer")
local DataStorage   = require("datastorage")
local Device        = require("device")
local Font          = require("ui/font")
local LuaSettings   = require("luasettings")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget    = require("ui/widget/textwidget")
local UIManager     = require("ui/uimanager")
local Widget        = require("ui/widget/widget")
local _             = require("gettext")
local Screen        = Device.screen
local Pluginaro     = require("pluginaro")

-- ── Font defaults ─────────────────────────────────────────────────────────────
local DEFAULT_FONT_SIZE = 11

-- Find the best available serif at module load time.
-- Priority: e-ink-optimised → scholarly → general serif → fallback.
local _FALLBACK_FACE, DEFAULT_FONT_NAME
do
    local candidates = {
        "Literata",          -- designed for e-ink readers
        "Bookerly",          -- Amazon's Kindle reading font
        "Brill",             -- scholarly, optimised for small academic text
        "Cardo",             -- scholarly, classical languages
        "Crimson Pro",
        "Lora",
        "Alegreya",
        "Vollkorn",
        "Cormorant Garamond",
        "Bitter",
        "Merriweather",
        "Old Standard TT",
        "DejaVu Serif",
        "Tinos",
        "NotoSerif",         -- KOReader built-in key (no space)
        "Noto Serif",
        "FreeSerif",
        "infofont",
    }
    for _, candidate in ipairs(candidates) do
        local ok, face = pcall(function() return Font:getFace(candidate, DEFAULT_FONT_SIZE) end)
        if ok and face then
            _FALLBACK_FACE    = face
            DEFAULT_FONT_NAME = candidate
            break
        end
    end
    if not _FALLBACK_FACE then
        _FALLBACK_FACE    = Font:getFace("infofont", DEFAULT_FONT_SIZE)
        DEFAULT_FONT_NAME = "infofont"
    end
end

-- ── Layout constants ──────────────────────────────────────────────────────────
local MAX_LINES  = 6   -- maximum lines per note box
local NOTE_V_GAP = 4   -- min vertical gap between stacked note boxes (px)
local VRULE_W    = 4   -- left vertical rule (px)
local HRULE_W    = 2   -- top horizontal border (px)
local RULE_GAP   = 9   -- space between left rule and note text (px)
local PAD_V      = 7   -- top and bottom padding inside box (px)
local PAD_R      = 5   -- right padding inside box (px)
local LEFT_GAP   = 10  -- gap from text-block right edge to note box (px)
local RIGHT_GAP  = 12  -- gap from note box to screen right edge (px)

local function sanitize(s)
    return (s:gsub("[\r\n\t]+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- ── Widget ────────────────────────────────────────────────────────────────────

local MarginNotes = Widget:extend{
    name        = "marjenoti",
    is_doc_only = true,
    _items      = nil,
    _nx         = nil,
    _note_w     = nil,
    _line_h     = nil,
    _face       = nil,
    _font_name  = nil,
    _font_size  = nil,
    settings    = nil,
}

function MarginNotes:init()
    self._items = {}
    self.settings   = LuaSettings:open(DataStorage:getSettingsDir() .. "/marjenoti.lua")
    self._font_name = self.settings:readSetting("font_name") or DEFAULT_FONT_NAME
    self._font_size = self.settings:readSetting("font_size") or DEFAULT_FONT_SIZE
    self:_apply_font()
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
end

function MarginNotes:_apply_font()
    self._line_h = nil  -- invalidate cached line height
    local ok, face = pcall(function() return Font:getFace(self._font_name, self._font_size) end)
    if ok and face then
        self._face = face
    else
        self._face = _FALLBACK_FACE
    end
end

function MarginNotes:onReaderReady()
    self.view = self.ui.view
    self.view:registerViewModule("marjenoti", self)
    self:_update_items()
end

function MarginNotes:_line_height()
    if not self._line_h then
        local p = TextWidget:new{ text = "A", face = self._face }
        self._line_h = p:getSize().h
        p:free()
    end
    return self._line_h
end

----------------------------------------------------------------------
-- Pre-compute note positions (doc API allowed here)
----------------------------------------------------------------------

function MarginNotes:_text_block_right(doc, sh, sw)
    -- Reflowable docs (CRE): scan visible words and take the max right edge —
    -- mirrors vortuyo's min_x_left logic on the opposite side of the page.
    -- Falls back to a 78%-of-screen heuristic for paged docs (PDF) or if
    -- paginmapo.lua is not bundled (defensive — should always be present).
    if doc.info and not doc.info.has_pages then
        local ok_ws, WordSource = pcall(require, "paginmapo")
        if ok_ws then
            local ok, words = pcall(WordSource.collect_words, doc, sh)
            if ok and words and #words > 0 then
                local max_right = 0
                for _, w in ipairs(words) do
                    local b = w.sbox
                    if b and b.x + b.w > max_right then
                        max_right = b.x + b.w
                    end
                end
                if max_right > 0 then return max_right end
            end
        end
    end
    return math.floor(sw * 0.78)
end

function MarginNotes:_update_items()
    self._items  = {}
    self._nx     = nil
    self._note_w = nil

    local ui  = self.ui
    local doc = ui and ui.document
    if not doc then return end
    local anns = ui.annotation and ui.annotation.annotations
    if not anns then return end

    local sh = Screen:getHeight()
    local sw = Screen:getWidth()
    local lh = self:_line_height()

    local raw = {}

    for _, ann in pairs(anns) do
        if ann.note and ann.note ~= "" and ann.pos0 and ann.pos1 then
            local ok, boxes = pcall(function()
                return doc:getScreenBoxesFromPositions(ann.pos0, ann.pos1, true)
            end)
            if ok and boxes and #boxes > 0 then
                local y_min, y_max = math.huge, -math.huge
                for _, b in ipairs(boxes) do
                    if b.y < y_min then y_min = b.y end
                    if b.y + b.h > y_max then y_max = b.y + b.h end
                end
                if y_max > 0 and y_min < sh then
                    table.insert(raw, { y_top = y_min, note = sanitize(ann.note) })
                end
            end
        end
    end
    if #raw == 0 then return end

    -- Right edge of the page TEXT BLOCK, not of the selection boxes.
    -- A short mid-line highlight must not pull the note into the running text.
    local text_right = self:_text_block_right(doc, sh, sw)
    local margin_w   = sw - text_right
    local note_w     = margin_w - LEFT_GAP - RIGHT_GAP
    if note_w < 40 then return end
    local nx     = text_right + LEFT_GAP
    local text_w = note_w - VRULE_W - RULE_GAP - PAD_R

    for _, r in ipairs(raw) do
        local tw = TextBoxWidget:new{ text = r.note, face = self._face, width = text_w }
        local actual_h = math.min(tw:getSize().h, MAX_LINES * lh)
        tw:free()
        table.insert(self._items, {
            y_top  = r.y_top,
            note   = r.note,
            text_h = actual_h,
            bh     = actual_h + PAD_V * 2,
        })
    end

    table.sort(self._items, function(a, b) return a.y_top < b.y_top end)
    self._nx     = nx
    self._note_w = note_w
end

function MarginNotes:onPageUpdate()    self:_update_items() end
function MarginNotes:onPosUpdate()     self:_update_items() end
function MarginNotes:onUpdatePos()     self:_update_items() end

function MarginNotes:onAnnotationsModified()
    self:_update_items()
    if self.view then UIManager:setDirty(self.view.dialog, "partial") end
end

function MarginNotes:onCloseDocument()
    self._items  = {}
    self._nx     = nil
    self._note_w = nil
end

----------------------------------------------------------------------
-- Drawing (no doc API calls here)
----------------------------------------------------------------------

function MarginNotes:paintTo(bb, x, y)
    if not self._items or #self._items == 0 then return end
    local nx     = self._nx
    local note_w = self._note_w
    if not nx or not note_w then return end

    local sh  = Screen:getHeight()
    local bot = -32768

    for _, item in ipairs(self._items) do
        local bh = item.bh
        local ay = math.max(item.y_top, bot + NOTE_V_GAP)
        if ay + bh > sh then ay = sh - bh end
        bot = ay + bh
        self:_draw_note(bb, x, y, nx, note_w, ay, bh, item)
    end
end

function MarginNotes:_draw_note(bb, x, y, nx, note_w, ay, bh, item)
    -- white background
    bb:paintRect(x + nx, y + ay, note_w, bh, Blitbuffer.COLOR_WHITE)

    -- hairline left rule (full height)
    bb:paintRect(x + nx, y + ay, VRULE_W, bh, Blitbuffer.COLOR_BLACK)

    -- hairline top rule — "L" corner, like a critical-edition gloss mark
    bb:paintRect(x + nx, y + ay, note_w, HRULE_W, Blitbuffer.COLOR_BLACK)

    -- note text
    local text_w = note_w - VRULE_W - RULE_GAP - PAD_R
    local tw = TextBoxWidget:new{
        text   = item.note,
        face   = self._face,
        width  = text_w,
        height = item.text_h,
    }
    tw:paintTo(bb, x + nx + VRULE_W + RULE_GAP, y + ay + PAD_V)
    tw:free()
end

----------------------------------------------------------------------
-- Menu
----------------------------------------------------------------------

function MarginNotes:_font_list()
    -- Enumerate all fonts KOReader has registered (bundled + user-imported),
    -- sorted alphabetically. This mirrors what KOReader's own font picker shows.
    local names = {}
    for name, _ in pairs(Font.fonts) do
        table.insert(names, name)
    end
    table.sort(names)
    return names
end

function MarginNotes:addToMainMenu(menu_items)
    local font_items = {}
    for _, name in ipairs(self:_font_list()) do
        local n = name
        table.insert(font_items, {
            text = n,
            checked_func = function() return self._font_name == n end,
            callback = function()
                self._font_name = n
                self.settings:saveSetting("font_name", n)
                self.settings:flush()
                self:_apply_font()
                self:_update_items()
                if self.view then UIManager:setDirty(self.view.dialog, "partial") end
            end,
        })
    end

    local size_items = {}
    for _, sz in ipairs({ 9, 10, 11, 12, 13, 14 }) do
        local s = sz
        table.insert(size_items, {
            text = tostring(s),
            checked_func = function() return self._font_size == s end,
            callback = function()
                self._font_size = s
                self.settings:saveSetting("font_size", s)
                self.settings:flush()
                self:_apply_font()
                self:_update_items()
                if self.view then UIManager:setDirty(self.view.dialog, "partial") end
            end,
        })
    end

    local sub_items = {
        {
            text           = _("Note font"),
            sub_item_table = font_items,
        },
        {
            text           = _("Font size"),
            sub_item_table = size_items,
        },
    }

    local ext_rows = Pluginaro.build_ext_menu("marjenoti")
    if #ext_rows > 0 then
        table.insert(sub_items, {
            text = _("Rozszerzenia"),
            sub_item_table = ext_rows,
        })
    end

    menu_items.marjenoti = {
        text           = _("Marjenoti"),
        sorting_hint   = "more_tools",
        sub_item_table = sub_items,
    }
end

function MarginNotes:onFlushSettings()
    if self.settings then self.settings:flush() end
end

return MarginNotes
