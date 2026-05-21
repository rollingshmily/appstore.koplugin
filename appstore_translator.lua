local http = require("socket.http")
local ltn12 = require("ltn12")
local json = require("json")
local logger = require("logger")
local DataStorage = require("datastorage")
local util = require("util")
local lfs = require("libs/libkoreader-lfs")

local Translator = {}

local CACHE_DIR = DataStorage:getDataDir() .. "/cache/appstore/translations"
local API_URL = "https://api.mymemory.translated.net/get"
local MAX_QUERY_LEN = 500 -- MyMemory API limit per request

--- Ensure cache directory exists
local function ensureCacheDir()
    util.makePath(CACHE_DIR)
end

--- Generate cache key from text (hash-based filename)
local function getCacheKey(text)
    -- Simple hash: use first 32 chars + length
    local safe = text:gsub("[^%w]", "_"):sub(1, 32)
    return safe .. "_" .. #text
end

--- Read cached translation
local function readCache(text)
    local key = getCacheKey(text)
    local path = CACHE_DIR .. "/" .. key .. ".txt"
    local f = io.open(path, "r")
    if f then
        local content = f:read("*a")
        f:close()
        if content and content ~= "" then
            return content
        end
    end
    return nil
end

--- Write translation to cache
local function writeCache(text, translation)
    ensureCacheDir()
    local key = getCacheKey(text)
    local path = CACHE_DIR .. "/" .. key .. ".txt"
    local f = io.open(path, "w")
    if f then
        f:write(translation)
        f:close()
    end
end

--- URL encode a string
local function urlEncode(str)
    if str then
        str = str:gsub("\n", " ")
        str = str:gsub("([^%w%-%.%_%~])", function(c)
            return string.format("%%%02X", string.byte(c))
        end)
    end
    return str
end

--- Translate a single chunk (up to 500 chars) via MyMemory API
local function translateChunk(text, sourceLang, targetLang)
    if not text or text == "" then
        return ""
    end

    sourceLang = sourceLang or "en"
    targetLang = targetLang or "zh-CN"

    local encoded = urlEncode(text)
    local url = string.format("%s?q=%s&langpair=%s|%s", API_URL, encoded, sourceLang, targetLang)

    local response = {}
    local _, code = http.request{
        url = url,
        sink = ltn12.sink.table(response),
        headers = {
            ["User-Agent"] = "KOReader-AppStore",
        },
    }

    code = tonumber(code)
    if code ~= 200 then
        return nil, string.format("HTTP %s", tostring(code))
    end

    local body = table.concat(response)
    local ok, parsed = pcall(json.decode, body)
    if not ok or type(parsed) ~= "table" then
        return nil, "decode error"
    end

    if parsed.responseStatus ~= 200 and parsed.responseStatus ~= "200" then
        return nil, parsed.responseDetails or "API error"
    end

    local translated = parsed.responseData and parsed.responseData.translatedText
    if not translated or translated == "" then
        return nil, "empty result"
    end

    return translated
end

--- Split text into chunks for translation
--- Tries to split at sentence boundaries when possible
local function splitIntoChunks(text, maxLen)
    maxLen = maxLen or MAX_QUERY_LEN
    local chunks = {}

    if #text <= maxLen then
        table.insert(chunks, text)
        return chunks
    end

    local remaining = text
    while #remaining > 0 do
        if #remaining <= maxLen then
            table.insert(chunks, remaining)
            break
        end

        -- Try to find a good break point (sentence end, comma, space)
        local breakPos = maxLen
        local searchStart = math.max(1, maxLen - 100)

        -- Look for sentence endings
        for pos = maxLen, searchStart, -1 do
            local c = remaining:sub(pos, pos)
            if c == "." or c == "!" or c == "?" or c == ";" then
                breakPos = pos
                break
            end
        end

        -- If no sentence end, try comma or space
        if breakPos == maxLen then
            for pos = maxLen, searchStart, -1 do
                local c = remaining:sub(pos, pos)
                if c == "," or c == " " or c == "\n" then
                    breakPos = pos
                    break
                end
            end
        end

        table.insert(chunks, remaining:sub(1, breakPos))
        remaining = remaining:sub(breakPos + 1)
    end

    return chunks
end

--- Translate text from source language to target language
--- Returns translated text or nil, error message
function Translator.translate(text, sourceLang, targetLang)
    if not text or text == "" then
        return ""
    end

    -- Check cache first
    local cached = readCache(text)
    if cached then
        return cached
    end

    sourceLang = sourceLang or "en"
    targetLang = targetLang or "zh-CN"

    -- Split into chunks for long texts
    local chunks = splitIntoChunks(text)
    local translatedParts = {}

    for i, chunk in ipairs(chunks) do
        local result, err = translateChunk(chunk, sourceLang, targetLang)
        if result then
            table.insert(translatedParts, result)
        else
            logger.warn("Translator chunk failed:", i, err)
            -- Use original text as fallback
            table.insert(translatedParts, chunk)
        end

        -- Small delay between chunks to avoid rate limiting
        if i < #chunks then
            -- KOReader doesn't have a simple sleep, but HTTP request latency provides natural spacing
        end
    end

    local fullTranslation = table.concat(translatedParts)

    -- Cache the result
    if fullTranslation and fullTranslation ~= "" then
        writeCache(text, fullTranslation)
    end

    return fullTranslation
end

--- Check if text appears to be non-Chinese (needs translation)
function Translator.needsTranslation(text)
    if not text or text == "" then
        return false
    end
    -- Count Chinese characters
    local chineseCount = 0
    local totalCount = 0
    for char in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        totalCount = totalCount + 1
        local byte = string.byte(char, 1)
        if byte >= 0xE4 and byte <= 0xE9 then
            -- Likely Chinese character (UTF-8 range for CJK)
            chineseCount = chineseCount + 1
        end
    end

    -- If less than 10% Chinese, consider it needs translation
    return totalCount > 0 and (chineseCount / totalCount) < 0.1
end

--- Clear translation cache
function Translator.clearCache()
    ensureCacheDir()
    local removed = 0
    for entry in lfs.dir(CACHE_DIR) do
        if entry ~= "." and entry ~= ".." then
            local path = CACHE_DIR .. "/" .. entry
            if lfs.attributes(path, "mode") == "file" then
                os.remove(path)
                removed = removed + 1
            end
        end
    end
    return removed
end

return Translator
