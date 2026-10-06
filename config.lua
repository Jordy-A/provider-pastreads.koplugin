local _ = require("gettext")

-- Keep in sync with latest.json and the packaged zip filename.
local VERSION = "1.0.0"

local API_BASE = "https://pb.pastreads.com"
local DOWNLOADS_BASE = "https://www.pastreads.com/koreader/downloads"
local LATEST_JSON_URL = DOWNLOADS_BASE .. "/latest.json"

return {
    VERSION = VERSION,
    API_BASE = API_BASE,
    INGEST_URL = API_BASE .. "/api/ingest/koreader",
    DOWNLOADS_BASE = DOWNLOADS_BASE,
    LATEST_JSON_URL = LATEST_JSON_URL,
}
