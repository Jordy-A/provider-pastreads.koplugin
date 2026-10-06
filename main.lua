local Provider = require("provider")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")

-- Provider plugins load before exporter, so exporter.koplugin is not yet on
-- package.path. Prepend it so pastreads can require("base").
local function ensureExporterBaseOnPath()
    local candidates = {
        "plugins/exporter.koplugin",
        DataStorage:getDataDir() .. "/plugins/exporter.koplugin",
    }
    local info = debug.getinfo(1, "S")
    if info and info.source then
        local here = info.source:match("^@(.+)/[^/]+$")
        if here then
            table.insert(candidates, 1, here .. "/../exporter.koplugin")
        end
    end
    for _, root in ipairs(candidates) do
        if lfs.attributes(root .. "/base.lua", "mode") == "file" then
            package.path = root .. "/?.lua;" .. package.path
            return
        end
    end
end

ensureExporterBaseOnPath()

local PastReadsImpl = require("pastreads")

local PastReadsProvider = WidgetContainer:extend{
    name = "provider-pastreads",
    is_doc_only = false,
}

function PastReadsProvider:init()
    -- Used by the updater to replace this plugin in place.
    PastReadsImpl.plugin_path = self.path
    Provider:register("exporter", "pastreads", PastReadsImpl)
end

return PastReadsProvider
