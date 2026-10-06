local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local http = require("socket.http")
local ltn12 = require("ltn12")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")
local rapidjson = require("rapidjson")
local socket = require("socket")
local socketutil = require("socketutil")
local ffiUtil = require("ffi/util")
local _ = require("gettext")
local T = require("ffi/util").template

local config = require("config")

local function httpGet(url)
    local sink = {}
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local code, _, status = socket.skip(1, http.request{
        url = url,
        method = "GET",
        sink = ltn12.sink.table(sink),
    })
    socketutil:reset_timeout()
    if code ~= 200 then
        return nil, status or tostring(code) or "network unreachable"
    end
    return table.concat(sink)
end

local function httpGetToFile(url, path)
    local file, err = io.open(path, "wb")
    if not file then
        return nil, err or "cannot open download path"
    end
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local code, _, status = socket.skip(1, http.request{
        url = url,
        method = "GET",
        sink = ltn12.sink.file(file),
    })
    socketutil:reset_timeout()
    -- sink.file closes the handle
    if code ~= 200 then
        os.remove(path)
        return nil, status or tostring(code) or "network unreachable"
    end
    return true
end

--- @return boolean true if remote is strictly newer than local
local function isNewer(remote, local_version)
    if type(remote) ~= "string" or type(local_version) ~= "string" then
        return false
    end
    if remote == local_version then
        return false
    end
    local function parts(v)
        local t = {}
        for n in (v:gsub("^v", "")):gmatch("%d+") do
            table.insert(t, tonumber(n) or 0)
        end
        return t
    end
    local a, b = parts(remote), parts(local_version)
    local n = math.max(#a, #b)
    for i = 1, n do
        local x, y = a[i] or 0, b[i] or 0
        if x > y then return true end
        if x < y then return false end
    end
    return false
end

local function findExtractedPluginDir(root)
    local direct = root .. "/provider-pastreads.koplugin"
    if lfs.attributes(direct, "mode") == "directory" then
        return direct
    end
    for entry in lfs.dir(root) do
        if entry ~= "." and entry ~= ".." then
            local path = root .. "/" .. entry
            if lfs.attributes(path, "mode") == "directory" then
                if entry == "provider-pastreads.koplugin"
                    or lfs.attributes(path .. "/_meta.lua", "mode") == "file" then
                    return path
                end
                local nested = findExtractedPluginDir(path)
                if nested then
                    return nested
                end
            end
        end
    end
end

local function unpackZip(zip_path, dest_dir)
    local ok_archiver, Archiver = pcall(require, "ffi/archiver")
    if ok_archiver and Archiver then
        if type(Archiver.unpack) == "function" then
            local ok, err = Archiver.unpack(zip_path, dest_dir)
            if ok then return true end
            logger.warn("PastReads update: Archiver.unpack failed", err)
        elseif Archiver.Extractor then
            local extractor = Archiver.Extractor:new{}
            if extractor and extractor.extract then
                local ok, err = extractor:extract(zip_path, dest_dir)
                if ok then return true end
                logger.warn("PastReads update: Extractor failed", err)
            end
        end
    end

    -- Fallback for devices with unzip on PATH
    local cmd = string.format("unzip -o -q %q -d %q", zip_path, dest_dir)
    local ret = os.execute(cmd)
    if ret == true or ret == 0 then
        return true
    end
    return nil, "could not unpack update archive"
end

local function installUpdate(plugin_path, zip_url)
    if type(plugin_path) ~= "string" or plugin_path == "" then
        return nil, "plugin path unknown"
    end

    local cache = DataStorage:getDataDir() .. "/cache"
    if lfs.attributes(cache, "mode") ~= "directory" then
        lfs.mkdir(cache)
    end
    local zip_path = cache .. "/pastreads-plugin-update.zip"
    local extract_root = cache .. "/pastreads-plugin-update"
    os.remove(zip_path)
    ffiUtil.purgeDir(extract_root)
    lfs.mkdir(extract_root)

    UIManager:show(InfoMessage:new{
        text = _("Downloading PastReads plugin update…"),
        timeout = 2,
    })

    local ok_dl, err_dl = httpGetToFile(zip_url, zip_path)
    if not ok_dl then
        return nil, err_dl
    end

    local ok_un, err_un = unpackZip(zip_path, extract_root)
    if not ok_un then
        return nil, err_un
    end

    local src = findExtractedPluginDir(extract_root)
    if not src then
        return nil, "update archive missing provider-pastreads.koplugin"
    end

    -- Replace installed plugin directory.
    local parent = plugin_path:match("(.+)/[^/]+$") or plugin_path
    local dest_name = plugin_path:match("([^/]+)$") or "provider-pastreads.koplugin"
    local dest = parent .. "/" .. dest_name
    local backup = dest .. ".bak"
    ffiUtil.purgeDir(backup)
    if lfs.attributes(dest, "mode") == "directory" then
        os.rename(dest, backup)
    end

    local copied = false
    if type(ffiUtil.copyRecursive) == "function" then
        copied = ffiUtil.copyRecursive(src, dest)
    end
    if not copied then
        -- cp -a works across mounts better than rename on many devices.
        local ret = os.execute(string.format("cp -a %q %q", src, dest))
        copied = (ret == true or ret == 0)
    end
    if not copied then
        local renamed = os.rename(src, dest)
        copied = renamed and true or false
    end
    if not copied then
        if lfs.attributes(backup, "mode") == "directory" then
            os.rename(backup, dest)
        end
        return nil, "failed to install update files"
    end
    ffiUtil.purgeDir(backup)
    os.remove(zip_path)
    ffiUtil.purgeDir(extract_root)
    return true
end

local function openManualDownload(zip_url)
    local Device = require("device")
    if Device.openLink then
        Device:openLink(zip_url)
    end
end

local function runCheck(plugin_path)
    UIManager:show(InfoMessage:new{
        text = _("Checking for PastReads plugin updates…"),
        timeout = 1,
    })

    local body, err = httpGet(config.LATEST_JSON_URL)
    if not body then
        UIManager:show(InfoMessage:new{
            text = T(_("Could not check for updates:\n%1"), err or "unknown error"),
        })
        return
    end

    local data, decode_err = rapidjson.decode(body)
    if not data or type(data.version) ~= "string" then
        UIManager:show(InfoMessage:new{
            text = T(_("Invalid update metadata:\n%1"), decode_err or "bad JSON"),
        })
        return
    end

    local remote = data.version
    local zip_url = data.url
    if type(zip_url) ~= "string" or zip_url == "" then
        local filename = data.filename
        if type(filename) == "string" and filename ~= "" then
            zip_url = config.DOWNLOADS_BASE .. "/" .. filename
        else
            UIManager:show(InfoMessage:new{
                text = _("Update metadata is missing a download URL."),
            })
            return
        end
    end

    if not isNewer(remote, config.VERSION) then
        UIManager:show(InfoMessage:new{
            text = T(_("PastReads plugin is up to date (%1)."), config.VERSION),
        })
        return
    end

    UIManager:show(ConfirmBox:new{
        text = T(
            _("Update available: %1 → %2\n\nDownload and install now? KOReader must restart afterward."),
            config.VERSION,
            remote
        ),
        ok_text = _("Update"),
        cancel_text = _("Later"),
        ok_callback = function()
            local ok, install_err = installUpdate(plugin_path, zip_url)
            if ok then
                UIManager:askForRestart(
                    _("PastReads plugin updated. Please restart KOReader.")
                )
            else
                openManualDownload(zip_url)
                UIManager:show(InfoMessage:new{
                    text = T(
                        _("Automatic install failed (%1).\nOpened the download link — unzip into your KOReader plugins folder, then restart."),
                        install_err or "unknown"
                    ),
                })
            end
        end,
    })
end

local M = {}

function M.menuItem(plugin_path)
    return {
        text = _("Check for updates"),
        keep_menu_open = true,
        callback = function()
            NetworkMgr:runWhenOnline(function()
                runCheck(plugin_path)
            end)
        end,
        separator = true,
    }
end

return M
