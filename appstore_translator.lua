local http = require("socket.http")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local json = require("json")
local logger = require("logger")
local DataStorage = require("datastorage")
local util = require("util")
local lfs = require("libs/libkoreader-lfs")
local ModelEditor = require("appstore_modeleditor")
local LuaSettings = require("luasettings")

local ok_cfg, AppStoreConfig = pcall(require, "appstore_configuration")
if not ok_cfg then
    AppStoreConfig = {}
end

local Translator = {}

local SETTINGS_PATH = DataStorage:getSettingsDir() .. "/appstore.lua"
local AppStoreSettings = LuaSettings:open(SETTINGS_PATH)

function Translator.setSettings(settings)
    AppStoreSettings = settings or AppStoreSettings
end

local CACHE_DIR = DataStorage:getDataDir() .. "/cache/appstore/translations"
local MYMEMORY_API_URL = "https://api.mymemory.translated.net/get"
local MYMEMORY_CHUNK_LEN = 500
local OPENAI_CHUNK_LEN = 6000

local function ensureCacheDir()
    util.makePath(CACHE_DIR)
end

local function getCacheKey(text, provider)
    local safe = tostring(text or ""):gsub("[^%w]", "_"):sub(1, 32)
    return tostring(provider or "default") .. "_" .. safe .. "_" .. #tostring(text or "")
end

local function readCache(text, provider)
    local key = getCacheKey(text, provider)
    local path = CACHE_DIR .. "/" .. key .. ".txt"
    local f = io.open(path, "r")
    if f then
        local content = f:read("*a")
        f:close()
        if content and content ~= "" then
            return content
        end
    end
end

local function writeCache(text, provider, translation)
    ensureCacheDir()
    local key = getCacheKey(text, provider)
    local path = CACHE_DIR .. "/" .. key .. ".txt"
    local f = io.open(path, "w")
    if f then
        f:write(translation)
        f:close()
    end
end

local function urlEncode(str)
    if str then
        str = str:gsub("\n", " ")
        str = str:gsub("([^%w%-%.%_%~])", function(c)
            return string.format("%%%02X", string.byte(c))
        end)
    end
    return str
end

local function splitIntoChunks(text, max_len)
    max_len = max_len or OPENAI_CHUNK_LEN
    local chunks = {}
    text = tostring(text or "")
    if #text <= max_len then
        return { text }
    end
    local remaining = text
    while #remaining > 0 do
        if #remaining <= max_len then
            table.insert(chunks, remaining)
            break
        end
        local break_pos = max_len
        local search_start = math.max(1, max_len - 1200)
        for pos = max_len, search_start, -1 do
            local c = remaining:sub(pos, pos)
            if c == "\n" or c == "." or c == "!" or c == "?" or c == ";" then
                break_pos = pos
                break
            end
        end
        table.insert(chunks, remaining:sub(1, break_pos))
        remaining = remaining:sub(break_pos + 1)
    end
    return chunks
end

local function requestJson(url, headers, body)
    local response = {}
    headers = headers or {}
    headers["Content-Type"] = headers["Content-Type"] or "application/json"
    headers["Accept"] = headers["Accept"] or "application/json"
    headers["Content-Length"] = tostring(#body)
    local request_fn = url:lower():match("^https://") and https.request or http.request
    local _, code = request_fn{
        url = url,
        method = "POST",
        headers = headers,
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(response),
    }
    code = tonumber(code)
    local response_body = table.concat(response)
    if code ~= 200 then
        return nil, string.format("HTTP %s: %s", tostring(code), response_body:sub(1, 300))
    end
    local ok, parsed = pcall(json.decode, response_body)
    if not ok or type(parsed) ~= "table" then
        return nil, "decode error"
    end
    return parsed
end

local function getOpenAISettings()
    local cfg = AppStoreConfig.translator or {}
    local openai = cfg.openai_compatible or cfg.openai or {}
    local selected = ModelEditor.getSelectedModel({ settings = AppStoreSettings }) or {}
    local additional = selected.additional_parameters or openai.additional_parameters or {}
    return {
        provider = selected.provider or openai.provider or "openai_compatible",
        base_url = selected.base_url or openai.base_url or "https://openrouter.ai/api/v1/chat/completions",
        api_key = selected.api_key or openai.api_key or "",
        model = selected.model or openai.model or "qwen/qwen3-14b:free",
        max_tokens = additional.max_tokens or openai.max_tokens or 8192,
        temperature = additional.temperature or openai.temperature or 0.2,
        extra_headers = selected.extra_headers or openai.extra_headers or {},
    }
end

local function translateOpenAIChunk(text, source_lang, target_lang)
    local settings = getOpenAISettings()
    if not settings.api_key or settings.api_key == "" then
        return nil, "OpenAI-compatible translator is not configured. Add and select a model in App Store > Custom Models."
    end
    local prompt = table.concat({
        "Translate the following README content to " .. (target_lang or "Simplified Chinese") .. ".",
        "Preserve Markdown structure, headings, lists, code blocks, links, and placeholders.",
        "Do not summarize. Do not add explanations. Return only the translated content.",
        "",
        text,
    }, "\n")
    local body = json.encode({
        model = settings.model,
        messages = {
            { role = "system", content = "You are a precise technical documentation translator." },
            { role = "user", content = prompt },
        },
        temperature = settings.temperature,
        max_tokens = settings.max_tokens,
        stream = false,
    })
    local headers = {
        ["Authorization"] = "Bearer " .. settings.api_key,
        ["HTTP-Referer"] = "https://github.com/rollingshmily/appstore.koplugin",
        ["X-Title"] = "appstore.koplugin",
        ["User-Agent"] = "KOReader-AppStore",
    }
    for key, value in pairs(settings.extra_headers or {}) do
        headers[key] = value
    end
    local parsed, err = requestJson(settings.base_url, headers, body)
    if not parsed then
        return nil, err
    end
    local choices = parsed.choices
    local content = choices and choices[1] and choices[1].message and choices[1].message.content
    if not content or content == "" then
        local msg = parsed.error and parsed.error.message
        return nil, msg or "empty model response"
    end
    return content
end

local function translateMyMemoryChunk(text, source_lang, target_lang)
    local encoded = urlEncode(text)
    local url = string.format("%s?q=%s&langpair=%s|%s", MYMEMORY_API_URL, encoded, source_lang or "en", target_lang or "zh-CN")
    local response = {}
    local _, code = http.request{
        url = url,
        sink = ltn12.sink.table(response),
        headers = { ["User-Agent"] = "KOReader-AppStore" },
    }
    code = tonumber(code)
    if code ~= 200 then
        return nil, string.format("HTTP %s", tostring(code))
    end
    local ok, parsed = pcall(json.decode, table.concat(response))
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

local function getProvider()
    local selected = ModelEditor.getSelectedModel({ settings = AppStoreSettings })
    if selected and selected.api_key and selected.api_key ~= "" then
        return selected.provider or "openai_compatible"
    end
    local cfg = AppStoreConfig.translator or {}
    return cfg.provider or "openai_compatible"
end

local function getCacheProviderKey(provider)
    if provider ~= "mymemory" then
        local settings = getOpenAISettings()
        return table.concat({
            tostring(provider or "openai_compatible"),
            tostring(settings.base_url or ""),
            tostring(settings.model or ""),
            tostring(settings.temperature or ""),
            tostring(settings.max_tokens or ""),
        }, "|")
    end
    return provider
end

function Translator.translate(text, source_lang, target_lang)
    if not text or text == "" then
        return ""
    end

    local provider = getProvider()
    local cache_provider = getCacheProviderKey(provider)
    local cached = readCache(text, cache_provider)
    if cached then
        return cached
    end

    source_lang = source_lang or "en"
    target_lang = target_lang or "Simplified Chinese"

    local max_len = provider == "mymemory" and MYMEMORY_CHUNK_LEN or OPENAI_CHUNK_LEN
    local chunks = splitIntoChunks(text, max_len)
    local translated_parts = {}

    for i, chunk in ipairs(chunks) do
        local result, err
        if provider == "mymemory" then
            result, err = translateMyMemoryChunk(chunk, source_lang, "zh-CN")
        else
            result, err = translateOpenAIChunk(chunk, source_lang, target_lang)
        end
        if not result then
            logger.warn("AppStore translator chunk failed", provider, i, err)
            return nil, err or "translation failed"
        end
        table.insert(translated_parts, result)
    end

    local full_translation = table.concat(translated_parts, "\n\n")
    if full_translation and full_translation ~= "" then
        writeCache(text, cache_provider, full_translation)
    end
    return full_translation
end

function Translator.needsTranslation(text)
    if not text or text == "" then
        return false
    end
    local chinese_count = 0
    local total_count = 0
    for char in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        total_count = total_count + 1
        local byte = string.byte(char, 1)
        if byte >= 0xE4 and byte <= 0xE9 then
            chinese_count = chinese_count + 1
        end
    end
    return total_count > 0 and (chinese_count / total_count) < 0.1
end

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
