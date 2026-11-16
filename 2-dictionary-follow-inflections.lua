--[[
Follow short StarDict inflection redirects automatically, e.g.
"the inflexion of / la flessione della parola schiantare".

Follows the suggested word through KOReader's normal lookup, with the same
enabled dictionaries, per-book exclusions, fuzzy-search preference and
language plugins used by holding a word. Never selects a dictionary.
Keeps the original book selection/query and the normal result window.
Missing entries, circular redirects and excessively long chains keep the
original result, so the suggested headword can still be looked up manually.

Install in koreader/patches/ and restart KOReader. No dictionary is modified.
]]

local ReaderDictionary = require("apps/reader/modules/readerdictionary")
local util = require("util")

-- These are dictionary-entry phrases, not KOReader UI translations.
-- Longest/bilingual phrases come first. Matching ignores case, HTML
-- formatting and line breaks; the target retains its original spelling.
local PREFIXES = {
    "the inflexion of / la flessione della parola",
    "the inflection of / la flessione della parola",
    "the inflexion of",
    "the inflection of",
    "an inflection of",
    "inflection of",
    "inflexion of",
    "inflected form of",
    "la flessione della parola",
    "flessione della parola",
    "forma flessa di",
    "forme fléchie de",
    "flexion de",
    "flexión de",
    "forma flexionada de",
    "flexionsform von",
    "flexão de",
}

local MAX_DEPTH = 4
local MAX_LOOKUPS = 8 -- extra normal lookups per original lookup
local MAX_STEPS = 256 -- also bound branching/repeated cached redirects
local MAX_REDIRECT_BYTES = 1024
local MAX_TARGET_BYTES = 160

local function redirectTarget(result)
    local definition = result.definition
    if type(result.dict) ~= "string" or result.dict == ""
            or type(definition) ~= "string" or result.no_result
            or #definition > MAX_REDIRECT_BYTES then return end
    local text = definition:gsub("<!%[CDATA%[(.-)%]%]>", "%1")
    text = util.htmlToPlainText(text):gsub("\u{00A0}", " "):gsub("%s+", " ")
    text = util.trim(text)
    local lower = util.stringLower(text)
    for _, prefix in ipairs(PREFIXES) do
        if lower:sub(1, #prefix) == prefix then
            local rest = text:sub(#prefix + 1)
            -- Require a delimiter after the phrase, not a partial word.
            local target = rest:match("^%s+(.+)$") or rest:match("^:%s*(.+)$")
            if not target then return end
            target = util.trim(target):gsub("^:%s*", "")
            local quotes = { { '"', '"' }, { "'", "'" }, { "«", "»" }, { "“", "”" }, { "‘", "’" } }
            for _, pair in ipairs(quotes) do
                if target:sub(1, #pair[1]) == pair[1] and target:sub(-#pair[2]) == pair[2] then
                    target = util.trim(target:sub(#pair[1] + 1, -#pair[2] - 1))
                    break
                end
            end
            -- Do not guess between multiple suggested headwords or follow
            -- entries that also contain explanations/examples.
            if target == "" or #target > MAX_TARGET_BYTES
                    or target:find("[,;:!?<>{}%[%]=/]") then return end
            local _, spaces = target:gsub(" ", "")
            if spaces > 5 then return end
            return target
        end
    end
end

local original_startSdcv = ReaderDictionary.startSdcv

function ReaderDictionary:startSdcv(word, dict_names, fuzzy_search)
    local results = original_startSdcv(self, word, dict_names, fuzzy_search)
    if type(results) ~= "table" or results.lookup_cancelled then return results end

    -- Same options as onLookupWord -> stardictLookup for a held word.
    -- Do not restrict the next lookup to the redirect's source dictionary.
    local names = self.enabled_dict_names
    if names and self.doc_disabled_dicts then
        local filtered = {}
        for _, name in ipairs(names) do
            if not self.doc_disabled_dicts[name] then filtered[#filtered + 1] = name end
        end
        names = filtered
    end
    if names and #names == 0 then return results end
    local disable_fuzzy
    if self.ui.doc_settings then
        disable_fuzzy = self.disable_fuzzy_search
    else
        disable_fuzzy = self.disable_fuzzy_search_fm
    end

    -- Per-lookup state: no timers, simulated gestures, extra windows or
    -- mutable global guards. The original lookup remains cancellable.
    local cache, lookups, steps, cancelled, exhausted = {}, 0, 0, false, false
    local function key(result)
        return result.dict .. "\0" .. (result.word or "")
    end
    local function resolve(result, path, depth)
        steps = steps + 1
        if steps > MAX_STEPS then exhausted = true; return end
        local target = redirectTarget(result)
        if not target then return { result } end
        if cancelled or depth >= MAX_DEPTH then return end
        target = self:cleanSelection(target)
        if not target or target == "" then return end
        local current_key = key(result)
        if target == result.word or path[current_key] then return end

        local candidates = cache[target]
        if candidates == nil then
            if lookups >= MAX_LOOKUPS then return end
            lookups = lookups + 1
            local found = original_startSdcv(self, target, names, not disable_fuzzy)
            if found and found.lookup_cancelled then
                cancelled = true
                return
            end
            candidates = {}
            for _, candidate in ipairs(found or {}) do
                if type(candidate.dict) == "string" and candidate.dict ~= "" and not candidate.no_result
                        and type(candidate.definition) == "string"
                        and util.trim(candidate.definition) ~= "" then
                    candidates[#candidates + 1] = candidate
                end
            end
            cache[target] = candidates
        end
        if #candidates == 0 then return end

        path[current_key] = true
        local resolved = {}
        for _, candidate in ipairs(candidates) do
            local entries = resolve(candidate, path, depth + 1)
            if exhausted then break end
            if entries then
                for _, entry in ipairs(entries) do resolved[#resolved + 1] = entry end
            end
        end
        path[current_key] = nil
        if cancelled or exhausted or #resolved == 0 then return end
        return resolved
    end

    local output, seen = {}, {}
    for _, result in ipairs(results) do
        local resolved = not cancelled and not exhausted and resolve(result, {}, 0)
        for _, entry in ipairs(resolved or { result }) do
            local identity = entry.dict .. "\0" .. entry.word .. "\0" .. entry.definition
            if not seen[identity] then
                output[#output + 1] = entry
                seen[identity] = true
            end
        end
    end
    if cancelled then output.lookup_cancelled = true end
    return output
end
