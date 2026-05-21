local logger = require("logger")
local BaseGetText = require("gettext")

local GetText = {}
GetText.translation = {}
GetText.current_lang = "C"

local function cEscape(what_full, what)
    if what == "n" then return "\n" end
    if what == "r" then return "\r" end
    if what == "t" then return "\t" end
    if what == "\\" then return "\\" end
    if what == '"' then return '"' end
    return what_full
end

local function addTranslation(msgid, msgstr)
    if msgid and msgid ~= "" and msgstr and msgstr ~= "" then
        GetText.translation[msgid] = msgstr:gsub("(\\(.))", cEscape)
    end
end

local function normalizeLang(lang)
    if not lang or lang == "" or lang == "C" then
        return nil
    end
    lang = tostring(lang):gsub("%.%w+$", "")
    if lang:match("^en[_-]") or lang == "en" then
        return nil
    end
    return lang:gsub("-", "_")
end

local function parsePoFile(path)
    local po = io.open(path, "r")
    if not po then
        return false
    end

    local data = {}
    local current
    local fuzzy = false

    local function flush()
        if not fuzzy then
            addTranslation(data.msgid, data.msgstr)
        end
        data = {}
        current = nil
        fuzzy = false
    end

    for line in po:lines() do
        if line == "" then
            flush()
        elseif line:match("^#,%s*fuzzy") then
            fuzzy = true
        elseif not line:match("^#") then
            local key, value = line:match('^%s*([%a_%[%]0-9]+)%s+"(.*)"%s*$')
            if key then
                current = key
                data[current] = (data[current] or "") .. value:gsub('\\"', '"'):gsub("\\n", "\n"):gsub("\\\\", "\\")
            else
                value = line:match('^%s*"(.*)"%s*$')
                if current and value then
                    data[current] = (data[current] or "") .. value:gsub('\\"', '"'):gsub("\\n", "\n"):gsub("\\\\", "\\")
                end
            end
        end
    end
    flush()
    po:close()
    return true
end

function GetText.changeLang(lang)
    GetText.translation = {}
    GetText.current_lang = "C"

    lang = normalizeLang(lang)
    if not lang then
        return false
    end

    local source = debug.getinfo(1, "S").source:sub(2)
    local plugin_dir = source:match("^(.*/)appstore_gettext%.lua$") or ""
    local candidates = {
        plugin_dir .. "l10n/" .. lang .. ".po",
        plugin_dir .. "l10n/" .. lang .. "/appstore.po",
        plugin_dir .. "l10n/" .. lang .. "/koreader.po",
    }

    for _, path in ipairs(candidates) do
        if parsePoFile(path) then
            GetText.current_lang = lang
            logger.dbg("AppStore loaded translation", path)
            return true
        end
    end

    logger.dbg("AppStore translation not found for", lang)
    return false
end

local mt = {}
function mt.__call(_, msgid)
    return GetText.translation[msgid] or BaseGetText(msgid)
end

function GetText.ngettext(msgid, msgid_plural, n)
    return BaseGetText.ngettext(msgid, msgid_plural, n)
end

function GetText.pgettext(msgctxt, msgid)
    return BaseGetText.pgettext(msgctxt, msgid)
end

function GetText.npgettext(msgctxt, msgid, msgid_plural, n)
    return BaseGetText.npgettext(msgctxt, msgid, msgid_plural, n)
end

setmetatable(GetText, mt)
GetText.changeLang(BaseGetText.current_lang)

return GetText
