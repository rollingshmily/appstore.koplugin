local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local Blitbuffer = require("ffi/blitbuffer")
local http = require("socket.http")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local json = require("json")
local util = require("util")

local _ = require("appstore_gettext")

local M = {}

M.SETTINGS_KEY = "translator_models"
M.SELECTED_KEY = "translator_selected_model"

M.TEMPLATES = {
    {
        label = _("OpenRouter"),
        key = "openrouter",
        config = {
            model = "qwen/qwen3-14b:free",
            base_url = "https://openrouter.ai/api/v1/chat/completions",
            api_key = "",
            additional_parameters = { temperature = 0.2, max_tokens = 8192 },
        },
    },
    {
        label = _("OpenAI-Compatible"),
        key = "openai_custom",
        config = {
            model = "gpt-4o-mini",
            base_url = "https://api.openai.com/v1/chat/completions",
            api_key = "",
            additional_parameters = { temperature = 0.2, max_tokens = 8192 },
        },
    },
    {
        label = _("DeepSeek"),
        key = "deepseek",
        config = {
            model = "deepseek-chat",
            base_url = "https://api.deepseek.com/v1/chat/completions",
            api_key = "",
            additional_parameters = { temperature = 0.2, max_tokens = 8192 },
        },
    },
    {
        label = _("Ollama (local)"),
        key = "ollama",
        config = {
            model = "llama3.2",
            base_url = "http://localhost:11434/v1/chat/completions",
            api_key = "ollama",
            additional_parameters = { temperature = 0.2, max_tokens = 8192 },
        },
    },
    {
        label = _("Groq"),
        key = "groq",
        config = {
            model = "llama-3.3-70b-versatile",
            base_url = "https://api.groq.com/openai/v1/chat/completions",
            api_key = "",
            additional_parameters = { temperature = 0.2, max_tokens = 8192 },
        },
    },
    {
        label = _("Mistral"),
        key = "mistral",
        config = {
            model = "mistral-small-latest",
            base_url = "https://api.mistral.ai/v1/chat/completions",
            api_key = "",
            additional_parameters = { temperature = 0.2, max_tokens = 8192 },
        },
    },
}

local function trim(value)
    return util.trim(value or "")
end

local function deepcopy(value)
    if type(value) ~= "table" then
        return value
    end
    local copy = {}
    for key, child in pairs(value) do
        copy[key] = deepcopy(child)
    end
    return copy
end

local function getModels(appstore)
    return appstore.settings:readSetting(M.SETTINGS_KEY) or {}
end

local function saveModels(appstore, models)
    appstore.settings:saveSetting(M.SETTINGS_KEY, models)
    appstore.settings:flush()
end

function M.getSelectedModel(appstore)
    local selected_key = appstore.settings:readSetting(M.SELECTED_KEY)
    local models = getModels(appstore)
    if selected_key and models[selected_key] then
        local cfg = deepcopy(models[selected_key])
        cfg.provider = selected_key
        return cfg
    end
end

local function saveModel(appstore, key, cfg)
    local models = getModels(appstore)
    models[key] = cfg
    saveModels(appstore, models)
end

local function deleteModel(appstore, key)
    local models = getModels(appstore)
    models[key] = nil
    saveModels(appstore, models)
    if appstore.settings:readSetting(M.SELECTED_KEY) == key then
        appstore.settings:delSetting(M.SELECTED_KEY)
        appstore.settings:flush()
    end
end

local function validate(fields)
    local key = trim(fields[1])
    if key == "" then
        return false, _("Provider key is required.")
    end
    if not key:match("^[%w_]+$") then
        return false, _("Provider key may contain only letters, digits, and underscores.")
    end
    if trim(fields[2]) == "" then
        return false, _("Model is required.")
    end
    if trim(fields[3]) == "" then
        return false, _("Base URL is required.")
    end
    if trim(fields[4]) == "" then
        return false, _("API key is required.")
    end
    return true
end

local function fieldsToConfig(fields)
    return {
        model = trim(fields[2]),
        base_url = trim(fields[3]),
        api_key = trim(fields[4]),
        additional_parameters = {
            temperature = tonumber(fields[5]) or 0.2,
            max_tokens = tonumber(fields[6]) or 8192,
        },
    }
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
        return nil, _("decode error")
    end
    return parsed
end

local function testModel(cfg)
    local additional = cfg.additional_parameters or {}
    local body = json.encode({
        model = cfg.model,
        messages = {
            { role = "user", content = "Reply with the single word: pong" },
        },
        temperature = additional.temperature or 0.2,
        max_tokens = 16,
        stream = false,
    })
    local parsed, err = requestJson(cfg.base_url, {
        ["Authorization"] = "Bearer " .. cfg.api_key,
        ["HTTP-Referer"] = "https://github.com/rollingshmily/appstore.koplugin",
        ["X-Title"] = "appstore.koplugin",
        ["User-Agent"] = "KOReader-AppStore",
    }, body)
    if not parsed then
        return false, err
    end
    local choices = parsed.choices
    local content = choices and choices[1] and choices[1].message and choices[1].message.content
    if not content or content == "" then
        local msg = parsed.error and parsed.error.message
        return false, msg or _("empty model response")
    end
    return true, content
end

local function showModelForm(appstore, template, existing_key, on_done)
    local MultiInputDialog = require("ui/widget/multiinputdialog")
    local cfg = existing_key and getModels(appstore)[existing_key] or template.config
    cfg = cfg or {}
    local additional = cfg.additional_parameters or {}
    local dialog
    dialog = MultiInputDialog:new{
        title = existing_key and _("Edit model provider") or _("Add model provider"),
        fields = {
            {
                description = _("Provider key"),
                text = existing_key or template.key or "openai_custom",
                hint = _("Letters, digits, underscores"),
            },
            {
                description = _("Model"),
                text = cfg.model or "",
            },
            {
                description = _("Base URL"),
                text = cfg.base_url or "",
                hint = _("Full /v1/chat/completions endpoint"),
            },
            {
                description = _("API key"),
                text = cfg.api_key or "",
                hint = _("Bearer token for this provider"),
            },
            {
                description = _("Temperature"),
                text = tostring(additional.temperature or 0.2),
                hint = "0.2",
            },
            {
                description = _("Max tokens"),
                input_type = "number",
                text = tostring(additional.max_tokens or 8192),
                hint = "8192",
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    background = Blitbuffer.COLOR_WHITE,
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Test"),
                    background = Blitbuffer.COLOR_WHITE,
                    callback = function()
                        local fields = dialog:getFields()
                        local ok, err = validate(fields)
                        if not ok then
                            UIManager:show(InfoMessage:new{ text = err, timeout = 4 })
                            return
                        end
                        local cfg = fieldsToConfig(fields)
                        NetworkMgr:runWhenOnline(function()
                            local test_ok, info = testModel(cfg)
                            UIManager:show(InfoMessage:new{
                                text = test_ok and string.format(_("Connection OK: %s"), tostring(info):sub(1, 120)) or string.format(_("Connection failed: %s"), tostring(info)),
                                timeout = test_ok and 5 or 8,
                            })
                        end)
                    end,
                },
                {
                    text = _("Save"),
                    background = Blitbuffer.COLOR_WHITE,
                    is_enter_default = true,
                    callback = function()
                        local fields = dialog:getFields()
                        local ok, err = validate(fields)
                        if not ok then
                            UIManager:show(InfoMessage:new{ text = err, timeout = 4 })
                            return
                        end
                        local key = trim(fields[1])
                        if existing_key and existing_key ~= key then
                            deleteModel(appstore, existing_key)
                        end
                        saveModel(appstore, key, fieldsToConfig(fields))
                        appstore.settings:saveSetting(M.SELECTED_KEY, key)
                        appstore.settings:flush()
                        UIManager:close(dialog)
                        UIManager:show(InfoMessage:new{ text = string.format(_("Saved and selected '%s'."), key), timeout = 3 })
                        if on_done then on_done() end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

local function showTemplatePicker(appstore, on_done)
    local dialog
    local buttons = {}
    for _, template in ipairs(M.TEMPLATES) do
        local tpl = template
        table.insert(buttons, {{
            text = tpl.label,
            callback = function()
                UIManager:close(dialog)
                showModelForm(appstore, tpl, nil, on_done)
            end,
        }})
    end
    dialog = ButtonDialog:new{
        title = _("Choose model template"),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

local function showModelActions(appstore, key, on_done)
    local selected_key = appstore.settings:readSetting(M.SELECTED_KEY)
    local dialog
    dialog = ButtonDialog:new{
        title = key,
        title_align = "center",
        buttons = {
            {
                {
                    text = selected_key == key and _("Selected") or _("Use for README translation"),
                    callback = function()
                        appstore.settings:saveSetting(M.SELECTED_KEY, key)
                        appstore.settings:flush()
                        UIManager:close(dialog)
                        UIManager:show(InfoMessage:new{ text = string.format(_("Selected '%s'."), key), timeout = 3 })
                        if on_done then on_done() end
                    end,
                },
            },
            {
                {
                    text = _("Edit"),
                    callback = function()
                        UIManager:close(dialog)
                        showModelForm(appstore, { key = key }, key, on_done)
                    end,
                },
                {
                    text = _("Test"),
                    callback = function()
                        local cfg = getModels(appstore)[key]
                        NetworkMgr:runWhenOnline(function()
                            local test_ok, info = testModel(cfg)
                            UIManager:show(InfoMessage:new{
                                text = test_ok and string.format(_("Connection OK: %s"), tostring(info):sub(1, 120)) or string.format(_("Connection failed: %s"), tostring(info)),
                                timeout = test_ok and 5 or 8,
                            })
                        end)
                    end,
                },
            },
            {
                {
                    text = _("Delete"),
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:show(ConfirmBox:new{
                            text = string.format(_("Delete custom model '%s'?"), key),
                            ok_text = _("Delete"),
                            ok_callback = function()
                                deleteModel(appstore, key)
                                if on_done then on_done() end
                            end,
                        })
                    end,
                },
            },
            {
                {
                    text = _("Close"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function M.genCustomModelsSubMenu(appstore)
    local items = {
        {
            text = _("Add a new model…"),
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                showTemplatePicker(appstore, function()
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end)
            end,
            separator = true,
        },
    }

    local models = getModels(appstore)
    local selected_key = appstore.settings:readSetting(M.SELECTED_KEY)
    local keys = {}
    for key in pairs(models) do
        table.insert(keys, key)
    end
    table.sort(keys)

    if #keys == 0 then
        table.insert(items, {
            text = _("(no custom models yet)"),
            enabled = false,
        })
    else
        for _, key in ipairs(keys) do
            table.insert(items, {
                text = string.format("%s%s", selected_key == key and "✓ " or "", key),
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    showModelActions(appstore, key, function()
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end)
                end,
            })
        end
    end

    return items
end

return M
