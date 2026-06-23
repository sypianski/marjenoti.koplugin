--[[
WordSource: collect visible word/sentence anchors from a CRengine document.

Each item:
    { text, xp0, xp1, next_xp0, sbox, sent_end }

Sentence boundary rules:
  ! ? ؟ ۔  — always end a sentence
  \n        — paragraph break always ends a sentence
  .         — ends a sentence ONLY if the next word starts with an uppercase
              letter (prevents M.I.T., Dr., e.g., etc. from splitting)
]]

local logger = require("logger")

local WordSource = {}

local MAX_WORDS_PER_PAGE = 400
local MAX_SENT_WORDS     = 150  -- safety fallback; real boundary is punctuation

-- Extract the path up to the deepest recognized block-level ancestor.
-- Returns nil when no recognized block ancestor is found (e.g. CRengine float
-- boxes created by CSS ::first-letter dropcap styling).  Returning nil instead
-- of the full xpointer prevents false paragraph-break fires for such elements.
local function xp_para(xp)
    if not xp then return nil end
    return xp:match("^(.*/(p%b[]))")
        or xp:match("^(.*/(h%d%b[]))")
        or xp:match("^(.*/(li%b[]))")
        or xp:match("^(.*/(blockquote%b[]))")
        or xp:match("^(.*/(section%b[]))")
        or xp:match("^(.*/(div%b[]))")
        or xp:match("^(.*/(dd%b[]))")
        or xp:match("^(.*/(dt%b[]))")
        -- no fallback: nil = unrecognized structure, not a real paragraph break
end

-- Return the DocFragment portion of an xpointer, or "/" for single-file EPUBs.
-- A change in DocFragment always represents a section break (different HTML file).
local function xp_docfrag(xp)
    if not xp then return nil end
    return xp:match("^(/body/DocFragment%b[])") or "/"
end

-- Return true when xp lives inside an h1–h9 element.
local function xp_is_heading(xp)
    if not xp then return false end
    return xp:match("/(h%d%b[])") ~= nil
end

-- inter  : text between current word-end and next word-start
-- next_w : text of the next word (used for the period-uppercase check)
local function is_sent_boundary(inter, next_w)
    if not inter or inter == "" then return false end
    if inter:find("\n")        then return true end   -- paragraph break
    if inter:find("[!%?]")     then return true end   -- unconditional
    if inter:find("\xD8\x9F") then return true end   -- ؟ Arabic question mark
    if inter:find("\xDB\x94") then return true end   -- ۔ Arabic full stop
    -- Period ends a sentence only when:
    --   (a) it is followed by optional closing marks then whitespace — rules
    --       out A.I., M.I.T., etc. where the period is adjacent to the next letter
    --   (b) AND the next word starts with an uppercase letter
    -- Normalize Unicode closing quotes to ASCII so the pattern works for curly
    -- quotes (U+201D ", U+2019 ', U+00BB ») as well as straight ones.
    local inter_n = inter
        :gsub("\xE2\x80\x9D", '"')   -- U+201D RIGHT DOUBLE QUOTATION MARK "
        :gsub("\xE2\x80\x99", "'")   -- U+2019 RIGHT SINGLE QUOTATION MARK '
        :gsub("\xC2\xBB",     '"')   -- U+00BB RIGHT-POINTING DOUBLE ANGLE »
    if inter_n:find("%.[\"%')%]]*%s") then
        local c = next_w and next_w:sub(1, 1) or ""
        return c ~= "" and c:match("%u") ~= nil
    end
    return false
end

----------------------------------------------------------------------
-- Off-screen sentence-end finder
----------------------------------------------------------------------

-- Walk forward from start_xp (ignoring screen bounds) until a sentence
-- boundary is found.  Returns the xp to use as xp1 for the extended
-- sentence — same convention as collect_sentences_from_words (start of
-- the next word, so the trailing gap with punctuation is included).
function WordSource.find_sentence_end(doc, start_xp, ref_xp)
    if not start_xp then return nil end
    -- Don't extend when start_xp is already in a different block than ref_xp.
    if ref_xp then
        local rp, sp = xp_para(ref_xp), xp_para(start_xp)
        if rp and sp and rp ~= sp then return nil end
        local rf, sf = xp_docfrag(ref_xp), xp_docfrag(start_xp)
        if rf and sf and rf ~= sf then return nil end
    end
    local start_para = xp_para(start_xp)
    local start_frag = xp_docfrag(start_xp)
    local cur = start_xp
    for _ = 1, MAX_SENT_WORDS * 4 do
        local wend = doc:getNextVisibleWordEnd(cur)
        if not wend then return cur end
        local text = doc:getTextFromXPointers(cur, wend)
        if not text or text == "" then return wend end
        local nxt  = doc:getNextVisibleWordStart(wend)
        local inter = nxt and doc:getTextFromXPointers(wend, nxt) or nil
        -- Stop when the walk crosses into a new block.
        if nxt then
            local np = xp_para(nxt)
            local nf = xp_docfrag(nxt)
            if (start_para and np and np ~= start_para)
            or (start_frag and nf and nf ~= start_frag) then
                return nxt
            end
        end
        -- Peek at the first few chars of the next word for the
        -- period-uppercase check inside is_sent_boundary.
        local next_text = ""
        if nxt then
            local ne = doc:getNextVisibleWordEnd(nxt)
            if ne then
                next_text = (doc:getTextFromXPointers(nxt, ne) or ""):sub(1, 4)
            end
        end
        if is_sent_boundary(inter, next_text) or not nxt then
            return nxt or wend
        end
        cur = nxt
    end
    return cur  -- safety fallback
end

----------------------------------------------------------------------
-- Off-screen sentence-start finder
----------------------------------------------------------------------

-- Walk forward from the block ancestor of first_visible_xp until
-- reaching it, tracking sentence boundaries along the way.  Returns
-- the xp0 where the containing sentence actually begins (off-screen),
-- or nil when no backward extension is needed.
function WordSource.find_sentence_start(doc, first_visible_xp)
    if not first_visible_xp then return nil end
    local para = xp_para(first_visible_xp)
    if not para then return nil end
    local frag = xp_docfrag(first_visible_xp)

    local cur = doc:getNextVisibleWordStart(para)
    if not cur then return nil end
    if cur == first_visible_xp then return nil end

    local sent_start = cur
    for _ = 1, MAX_SENT_WORDS * 4 do
        local wend = doc:getNextVisibleWordEnd(cur)
        if not wend then break end
        local nxt = doc:getNextVisibleWordStart(wend)
        if not nxt then break end
        if nxt == first_visible_xp then break end

        local np = xp_para(nxt)
        local nf = xp_docfrag(nxt)
        if (np and para and np ~= para)
        or (nf and frag and nf ~= frag) then
            break
        end

        local inter = doc:getTextFromXPointers(wend, nxt)
        local next_text = ""
        local ne = doc:getNextVisibleWordEnd(nxt)
        if ne then
            next_text = (doc:getTextFromXPointers(nxt, ne) or ""):sub(1, 4)
        end
        if is_sent_boundary(inter, next_text) then
            sent_start = nxt
        end

        cur = nxt
    end

    if sent_start == first_visible_xp then return nil end
    return sent_start
end

----------------------------------------------------------------------
-- Word collection
----------------------------------------------------------------------

function WordSource.collect_words(doc, screen_h)
    local items = {}
    local top_xp = doc:getXPointer()
    if not top_xp then return items end

    local cur = doc:getNextVisibleWordStart(top_xp)
    if not cur then return items end

    for _ = 1, MAX_WORDS_PER_PAGE do
        local word_end = doc:getNextVisibleWordEnd(cur)
        if not word_end then break end

        local text = doc:getTextFromXPointers(cur, word_end)
        local nxt  = doc:getNextVisibleWordStart(word_end)

        if not text or text == "" then
            if not nxt or nxt == cur then break end
            cur = nxt
        else
            local sboxes = doc:getScreenBoxesFromPositions(cur, word_end, true)
            local sbox   = sboxes and sboxes[1]
            if sbox then
                if sbox.y > screen_h then break end
                if sbox.y + sbox.h >= 0 then
                    local inter = nxt and doc:getTextFromXPointers(word_end, nxt) or nil
                    table.insert(items, {
                        text     = text,
                        xp0      = cur,
                        xp1      = word_end,
                        next_xp0 = nxt,
                        inter    = inter,   -- stored for the second-pass boundary check
                        sbox     = sbox,
                        sent_end = false,   -- filled below
                    })
                end
            end
            if not nxt or nxt == cur then break end
            cur = nxt
        end
    end

    -- Second pass: sentence boundary via inter-word punctuation, xpointer block
    -- path change, DocFragment change, or sbox y-gap fallback.
    for i = 1, #items do
        local nxt       = items[i + 1]
        local next_text = nxt and nxt.text or ""
        local by_text   = is_sent_boundary(items[i].inter, next_text)
        local by_struct = false
        if nxt then
            local p1 = xp_para(items[i].xp0)
            local p2 = xp_para(nxt.xp0)
            -- Recognized block ancestors differ = paragraph break.
            local diff_block = p1 ~= nil and p2 ~= nil and p1 ~= p2
            -- Different DocFragment = different HTML file = always a section break.
            local f1 = xp_docfrag(items[i].xp0)
            local f2 = xp_docfrag(nxt.xp0)
            local diff_frag = f1 ~= nil and f2 ~= nil and f1 ~= f2
            by_struct = diff_block or diff_frag
        end
        local by_para   = false
        if nxt and items[i].sbox and nxt.sbox then
            local gap = nxt.sbox.y - (items[i].sbox.y + items[i].sbox.h)
            -- Only use y-gap when the word has a recognized block ancestor;
            -- dropcap float boxes (xp_para → nil) produce misleading sbox
            -- positions and would otherwise generate a false sentence break.
            by_para = xp_para(items[i].xp0) ~= nil
                and gap > items[i].sbox.h * 0.5
        end
        local by_heading = false
        if xp_is_heading(items[i].xp0) then
            if not nxt then
                by_heading = true
            else
                local cp = xp_para(items[i].xp0)
                local np = xp_para(nxt.xp0)
                by_heading = (np == nil) or (cp ~= nil and np ~= cp)
            end
        end
        items[i].sent_end = by_text or by_struct or by_para or by_heading
    end

    logger.dbg("visel: collected", #items, "words")
    return items
end

----------------------------------------------------------------------
-- Sentence collection
----------------------------------------------------------------------

function WordSource.collect_sentences_from_words(words)
    local items = {}
    local i = 1
    while i <= #words do
        local s = i
        while i <= #words and (i - s) < MAX_SENT_WORDS and not words[i].sent_end do
            i = i + 1
        end
        local e = math.min(i, #words)
        i = e + 1

        -- Extend xp1 into the inter-word gap to include trailing ."' etc.
        -- Only skip extension when the next CRengine *word itself* starts with
        -- an opening quote — that quote sits at next_xp0, and with exclusive
        -- xp1 semantics it would be included.  We do NOT check the gap text:
        -- doing so also prevents the period from being included (both live in
        -- the same gap) and the trade-off is worse than occasionally having the
        -- opening quote of the next sentence fall inside the current selection.
        local next_w  = words[e + 1]
        local inter_e = words[e].inter or ""
        local tail3_e = inter_e:sub(-3)
        -- Opening quote belonging to the next sentence may sit in the inter-word
        -- gap (when CRengine doesn't include it in next word's text).  Detect it
        -- either way: as the next word's leading character OR as the last character
        -- of the gap.  In both cases stop the extension before the gap so we don't
        -- pull the opening quote into this sentence's highlight.
        local next_opens_quote = (next_w and (
            next_w.text:sub(1,1) == '"' or next_w.text:sub(1,1) == "'"
            or next_w.text:sub(1,3) == "\xE2\x80\x9C"   -- " U+201C
            or next_w.text:sub(1,3) == "\xE2\x80\x98"   -- ' U+2018
            or next_w.text:sub(1,2) == "\xC2\xAB"        -- « U+00AB
            or next_w.text:sub(1,2) == "\xC2\xBB"        -- » U+00BB (opener in Finnish/Swedish)
            or next_w.text:sub(1,3) == "\xE2\x80\xB9"   -- ‹ U+2039
            or next_w.text:sub(1,3) == "\xE2\x80\xBA"   -- › U+203A (opener in some conventions)
            or next_w.text:sub(1,3) == "\xE2\x80\x9E"   -- „ U+201E
            or next_w.text:sub(1,3) == "\xE2\x80\x9A"   -- ‚ U+201A
            or next_w.text:sub(1,3) == "\xE2\x80\x94"   -- — U+2014 dialogue dash
        )) or (
            inter_e:sub(-1) == '"' or inter_e:sub(-1) == "'"
            or tail3_e == "\xE2\x80\x9C" or tail3_e == "\xE2\x80\x98"
            or inter_e:sub(-1) == "(" or inter_e:sub(-1) == "["
            or inter_e:sub(-2) == "\xC2\xAB"             -- « U+00AB
            or inter_e:sub(-2) == "\xC2\xBB"             -- » U+00BB
            or tail3_e == "\xE2\x80\xB9"                 -- ‹ U+2039
            or tail3_e == "\xE2\x80\xBA"                 -- › U+203A
            or tail3_e == "\xE2\x80\x9E"                 -- „ U+201E
            or tail3_e == "\xE2\x80\x9A"                 -- ‚ U+201A
            or tail3_e == "\xE2\x80\x94"                 -- — U+2014
        )
        local xp1 = (words[e].next_xp0 and not next_opens_quote)
            and words[e].next_xp0 or words[e].xp1

        -- Try to include a leading opening quote by decrementing the char offset
        -- in words[s].xp0 by 1.  Works when the quote sits in the gap immediately
        -- before words[s].xp0 in the same CRengine text node.
        local xp0 = words[s].xp0
        if s > 1 then
            local ib    = words[s - 1].inter or ""
            local tail3 = ib:sub(-3)
            if ib:sub(-1) == '"' or ib:sub(-1) == "'"
                    or tail3 == "\xE2\x80\x9C" or tail3 == "\xE2\x80\x98"
                    or ib:sub(-1) == "(" or ib:sub(-1) == "["
                    or ib:sub(-2) == "\xC2\xAB"           -- « U+00AB
                    or tail3 == "\xE2\x80\xB9"            -- ‹ U+2039
                    or tail3 == "\xE2\x80\x9E"            -- „ U+201E
                    or tail3 == "\xE2\x80\x9A"            -- ‚ U+201A
                    or tail3 == "\xE2\x80\x94" then       -- — U+2014 dialogue dash
                local base, off = xp0:match("^(.+)%.(%d+)$")
                if base and tonumber(off) >= 1 then
                    xp0 = base .. "." .. (tonumber(off) - 1)
                end
            end
        end
        local parts     = {}
        local word_list = {}
        for j = s, e do
            table.insert(parts, words[j].text)
            table.insert(word_list, {
                text     = words[j].text,
                xp0      = words[j].xp0,
                xp1      = words[j].xp1,
                next_xp0 = words[j].next_xp0,
                sbox     = words[j].sbox,
            })
        end
        table.insert(items, {
            text      = table.concat(parts, " "),
            xp0       = xp0,
            xp1       = xp1,
            sbox      = words[s].sbox,
            para      = xp_para(words[s].xp0),  -- paragraph identity for Up/Down nav
            word_list = word_list,
        })
    end
    logger.dbg("visel: collected", #items, "sentences")
    return items
end

function WordSource.collect_sentences(doc, screen_h)
    local words = WordSource.collect_words(doc, screen_h)
    return WordSource.collect_sentences_from_words(words)
end

----------------------------------------------------------------------
-- Page-boundary detection
----------------------------------------------------------------------

-- Returns true when the page view starts at a sentence boundary (so the first
-- collected sentence is complete).  Returns false when the page starts
-- mid-sentence (continuation from the previous page).
function WordSource.page_starts_at_boundary(doc)
    local top_xp = doc:getXPointer()
    if not top_xp then return true end
    local first_xp = doc:getNextVisibleWordStart(top_xp)
    if not first_xp then return true end
    -- Different DocFragment = new HTML file in the spine = clean boundary.
    if xp_docfrag(top_xp) ~= xp_docfrag(first_xp) then return true end
    local ok, pre = pcall(function()
        return doc:getTextFromXPointers(top_xp, first_xp)
    end)
    if not ok then return true end
    -- Empty gap: top_xp is at the first word.  Treat as clean unless the word
    -- starts with a lowercase letter, which is a strong signal of continuation.
    if pre == "" then
        local ok2, w = pcall(function()
            return doc:getTextFromXPointers(first_xp,
                doc:getNextVisibleWordEnd(first_xp))
        end)
        if ok2 and w and w:sub(1,1):match("%l") then return false end
        return true
    end
    if pre:find("[%.!%?]") then return true end
    if pre:find("\xD8\x9F") then return true end
    if pre:find("\xDB\x94") then return true end
    if pre:find("\n")        then return true end
    return false
end


return WordSource
