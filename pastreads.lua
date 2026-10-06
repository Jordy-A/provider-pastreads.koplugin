local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")

local config = require("config")
local update = require("update")

local PastReadsExporter = require("base"):new{
    name = "pastreads",
    title = _("PastReads"),
    is_remote = true,
    -- Set by provider-pastreads main.lua (path of this .koplugin).
    plugin_path = nil,
}

-- Exporter base intends remotes to skip the Share menu, but the and/or init
-- is unreliable. Set explicitly so "Share as pastreads" stays available.
PastReadsExporter.shareable = true

function PastReadsExporter:isReadyToExport()
    return self.settings.token ~= nil and self.settings.token ~= ""
end

local function enableMenuItem(self)
    return {
        text = _("Export to PastReads"),
        checked_func = function()
            return self:isEnabled()
        end,
        enabled_func = function()
            return self:isReadyToExport()
        end,
        callback = function()
            self:toggleEnabled()
        end,
        separator = true,
    }
end

local function tokenMenuItem(self)
    local dialog_title = _("Set access token")
    return {
        text = dialog_title,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            local auth_dialog
            auth_dialog = InputDialog:new{
                title = dialog_title,
                input = self.settings.token or "",
                input_type = "text",
                buttons = {
                    {
                        {
                            text = _("Cancel"),
                            id = "close",
                            callback = function()
                                UIManager:close(auth_dialog)
                            end,
                        },
                        {
                            text = _("Set token"),
                            callback = function()
                                local token = auth_dialog:getInputText()
                                if token and token:match("%S") then
                                    self.settings.token = token:match("^%s*(.-)%s*$")
                                else
                                    self.settings.token = nil
                                end
                                UIManager:close(auth_dialog)
                                touchmenu_instance:updateItems()
                            end,
                        },
                    },
                },
            }
            UIManager:show(auth_dialog)
            auth_dialog:onShowKeyboard()
        end,
    }
end

local function pastReadsSubMenu(self)
    return {
        enableMenuItem(self),
        tokenMenuItem(self),
        update.menuItem(self.plugin_path),
    }
end

-- Newer Exporter: genTargetSubMenu → genTargetMenu (needs explicit title; base
-- falls back to capitalizing `name` → "Pastreads" when title is missing).
function PastReadsExporter:genTargetSubMenu()
    return pastReadsSubMenu(self)
end

function PastReadsExporter:genTargetMenu()
    return {
        text = _("PastReads"),
        checked_func = function()
            return self:isEnabled()
        end,
        hold_callback = function(touchmenu_instance)
            self:toggleEnabled()
            touchmenu_instance:updateItems()
        end,
        sub_item_table = pastReadsSubMenu(self),
    }
end

-- Older Exporter / provider fallback: getMenuTable only.
function PastReadsExporter:getMenuTable()
    return {
        text = _("PastReads"),
        checked_func = function()
            return self:isEnabled()
        end,
        sub_item_table = pastReadsSubMenu(self),
    }
end

--- Build canonical PastReads ingest body ({ highlights, notes }) for all books.
local function booknotesToCanonical(t)
    local highlights = {}
    local notes = {}
    local index = 0

    for _, booknotes in ipairs(t) do
        local source_title = booknotes.title or "Unknown Title"
        local author = booknotes.author
        if author and author ~= "" then
            author = author:gsub("\n", ", ")
        else
            author = "Unknown Author"
        end

        for _, chapter in ipairs(booknotes) do
            for _, clipping in ipairs(chapter) do
                local content = clipping.text
                if type(content) == "string" and content:match("%S") then
                    index = index + 1
                    local page = clipping.page
                    local location_start
                    if type(page) == "number" then
                        location_start = page
                    elseif type(page) == "string" then
                        location_start = tonumber(page)
                    end
                    local time = clipping.time
                    local highlighted_at
                    if type(time) == "number" then
                        highlighted_at = os.date("!%Y-%m-%dT%TZ", time)
                    end

                    local id = string.format(
                        "koreader-%s-%s-%d",
                        tostring(time or 0),
                        tostring(page or 0),
                        index
                    )

                    local highlight = {
                        id = id,
                        content = content,
                        sourceTitle = source_title,
                        author = author,
                        locationStart = location_start,
                        locationEnd = location_start,
                        highlightedAt = highlighted_at,
                    }
                    if type(clipping.color) == "string" and clipping.color:match("%S") then
                        highlight.color = clipping.color
                    end
                    table.insert(highlights, highlight)

                    if type(clipping.note) == "string" and clipping.note:match("%S") then
                        table.insert(notes, {
                            content = clipping.note,
                            sourceTitle = source_title,
                            author = author,
                            highlightId = id,
                            locationStart = location_start,
                            locationEnd = location_start,
                            highlightedAt = highlighted_at,
                        })
                    end
                end
            end
        end
    end

    local body = {
        highlights = highlights,
    }
    -- Omit empty notes: Lua encodes {} as a JSON object, not [].
    if #notes > 0 then
        body.notes = notes
    end
    return body
end

function PastReadsExporter:export(t)
    if not self:isReadyToExport() then
        return false
    end

    -- Export passes { booknotes, … }; Share passes a single booknotes table.
    local books = (type(t) == "table" and t.title ~= nil) and { t } or t
    if type(books) ~= "table" then
        return false
    end

    local body = booknotesToCanonical(books)
    if #body.highlights == 0 and #(body.notes or {}) == 0 then
        logger.dbg("PastReads: nothing to export")
        return true
    end

    local json_headers = {
        ["Authorization"] = "Bearer " .. self.settings.token,
    }

    local result, err = self:makeJsonRequest(config.INGEST_URL, "POST", body, json_headers)
    if not result then
        logger.warn("PastReads: ingest failed", err)
        return false
    end
    return true
end

--- Share menu passes one booknotes table (not an array).
function PastReadsExporter:share(booknotes)
    return self:export(booknotes)
end

return PastReadsExporter
