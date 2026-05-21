-- Generic update channel: fetch manifest.json, download files, verify
-- SHA-256, atomic-rename into the plugin directory.
--
-- Mirrors coverdownloader.koplugin/updater.lua and
-- hypothesis.koplugin/updater.lua. The three files are intentionally
-- near-identical so the behavior is consistent across plugins; main.lua
-- loads this via dofile() to dodge package.loaded["updater"] sharing.

local logger = require("logger")
local socket_url = require("socket.url")
local http = require("socket.http")
local ltn12 = require("ltn12")
local _has_socketutil, socketutil = pcall(require, "socketutil")
local _has_https, https = pcall(require, "ssl.https")
local _has_sha2, sha2 = pcall(require, "ffi/sha2")

local function load_json()
    for _, name in ipairs({ "rapidjson", "cjson", "json", "JSON" }) do
        local ok, mod = pcall(require, name)
        if ok and mod and mod.decode and mod.encode then return mod end
    end
    return nil
end
local JSON = load_json()

local Updater = {}

local function pickRequestFn(url)
    if url:lower():match("^https://") then
        if not _has_https then return nil, "no_https_module" end
        return https.request
    end
    return http.request
end

local function rawGet(url)
    local request_fn, err = pickRequestFn(url)
    if not request_fn then return nil, err end

    local sink_table = {}
    local req = {
        url = url,
        method = "GET",
        sink = ltn12.sink.table(sink_table),
        headers = {
            ["Accept"] = "*/*",
            ["Cache-Control"] = "no-cache, no-store, max-age=0",
            ["Pragma"] = "no-cache",
            ["User-Agent"] = "KOReader-AppStore-Updater/0.1",
        },
    }
    if _has_socketutil then
        socketutil:set_timeout(
            socketutil.LARGE_BLOCK_TIMEOUT or 10,
            socketutil.LARGE_TOTAL_TIMEOUT or 60
        )
    end
    local _r, code, resp_headers = request_fn(req)
    if _has_socketutil then socketutil:reset_timeout() end
    return code, table.concat(sink_table), resp_headers
end

local function httpGet(url)
    local cur = url
    for _ = 1, 5 do
        local code, body, h = rawGet(cur)
        if type(code) ~= "number" then
            return nil, tostring(code or "network_error")
        end
        if code == 301 or code == 302 or code == 303 or code == 307 or code == 308 then
            local loc = h and (h.location or h.Location)
            if not loc then return nil, string.format("http_%d_no_location", code) end
            cur = socket_url.absolute(cur, loc)
        elseif code >= 200 and code < 300 then
            return body, nil
        else
            return nil, string.format("http_%d", code)
        end
    end
    return nil, "too_many_redirects"
end

local function urlDir(url)
    local proto, host, path = url:match("^(https?://)([^/]+)(/.*)$")
    if not proto then return nil end
    local dir = path:match("^(.*/)[^/]*$") or "/"
    return proto .. host .. dir
end

local function appendQuery(url, key, value)
    local sep = url:find("?", 1, true) and "&" or "?"
    return url .. sep .. key .. "=" .. value
end

local function resolveFileUrl(manifest_url, base_url, path, sha)
    if path:match("^https?://") then return path end
    local base = base_url
    if not base or base == "" then base = urlDir(manifest_url) end
    if not base then return nil end
    if not base:match("/$") then base = base .. "/" end
    local full = base .. path
    if sha and sha ~= "" then
        full = appendQuery(full, "h", sha:sub(1, 16))
    end
    return full
end

local function sha256Hex(s)
    if not _has_sha2 or not sha2 or not sha2.sha256 then return nil end
    local ok, h = pcall(sha2.sha256, s)
    if not ok then return nil end
    return h
end

local function writeFile(path, content)
    local f, err = io.open(path, "wb")
    if not f then return false, err end
    f:write(content)
    f:close()
    return true
end

local function safePath(p)
    if not p or p == "" then return nil end
    if p:match("^/") or p:match("^[A-Za-z]:[/\\]") then return nil end
    if p:find("%.%.") then return nil end
    -- LuaJIT pattern parser treats embedded NUL as string terminator, so
    -- "[\0]" raises "missing ']'". Use plain find to detect NUL bytes.
    if p:find("\0", 1, true) then return nil end
    return p
end

local function cacheBust(url, token)
    token = token or tostring(os.time())
    local busted = appendQuery(url, "_t", token)
    if url:match("^https://gh%-proxy%.com/https://raw%.githubusercontent%.com/") then
        local inner = appendQuery(url:sub(#"https://gh-proxy.com/" + 1), "_t", token)
        busted = appendQuery("https://gh-proxy.com/" .. inner, "_t", token)
    end
    return busted
end

function Updater.fetchManifest(manifest_url)
    if not JSON then return nil, "no_json_module" end
    if not manifest_url or manifest_url == "" then return nil, "no_url" end
    local fresh_url = cacheBust(manifest_url)
    local body, err = httpGet(fresh_url)
    if not body then return nil, err end
    local ok, parsed = pcall(JSON.decode, body)
    if not ok or type(parsed) ~= "table" then return nil, "parse_failed" end
    if type(parsed.version) ~= "string" or type(parsed.files) ~= "table" then
        return nil, "invalid_manifest"
    end
    return parsed, nil
end

function Updater.install(manifest_url, manifest, plugin_dir, progress_cb)
    if not plugin_dir or plugin_dir == "" then return false, "no_plugin_dir" end

    local staged = {}
    local n = #manifest.files
    for i, entry in ipairs(manifest.files) do
        local rel = safePath(entry.path)
        if not rel then return false, "bad_path: " .. tostring(entry.path) end
        if progress_cb then progress_cb(i, n, rel) end
        local url = resolveFileUrl(manifest_url, manifest.base_url, entry.path, entry.sha256)
        if not url then return false, "no_base_url" end
        local body, derr = httpGet(url)
        if not body then return false, string.format("download_%s: %s", rel, derr) end
        if entry.sha256 and entry.sha256 ~= "" then
            local got = sha256Hex(body)
            if got and got:lower() ~= entry.sha256:lower() then
                return false, "hash_mismatch: " .. rel
            end
        end
        table.insert(staged, { path = rel, content = body })
    end

    for _, item in ipairs(staged) do
        local final = plugin_dir .. "/" .. item.path
        local subdir = final:match("^(.*)/[^/]+$")
        if subdir and subdir ~= plugin_dir then
            os.execute(string.format("mkdir -p '%s'", subdir:gsub("'", "'\\''")))
        end
        local tmp = final .. ".new"
        local ok, werr = writeFile(tmp, item.content)
        if not ok then return false, "write_failed: " .. tostring(werr) end
        local renamed, rerr = os.rename(tmp, final)
        if not renamed then
            os.remove(tmp)
            return false, "rename_failed: " .. tostring(rerr)
        end
    end

    return true, nil
end

local function splitVersion(v)
    local segs = {}
    for n in tostring(v):gmatch("(%d+)") do
        table.insert(segs, tonumber(n) or 0)
    end
    return segs
end

function Updater.compareVersions(local_v, remote_v)
    if not local_v or not remote_v then return 0 end
    if local_v == remote_v then return 0 end
    local a, b = splitVersion(local_v), splitVersion(remote_v)
    local n = math.max(#a, #b)
    for i = 1, n do
        local ai, bi = a[i] or 0, b[i] or 0
        if ai < bi then return -1 end
        if ai > bi then return 1 end
    end
    return 0
end

return Updater
