#!/usr/bin/env lua
-- autobrr-setup.lua
-- Lua setup for the autobrr service (modules/services/autobrr/default.nix),
-- run from the unit's postStart. Same jobs, same order:
--
--   1. ensure the autobrr API key row exists in the sqlite database
--   2. wait for the autobrr API to be ready
--   3. create *arr -> autobrr Webhook notifications (list-trigger on media
--      add/delete) only for arrs that use a list (currently Radarr), so the
--      list refreshes within seconds
--   4. create autobrr download clients for each *arr if missing
--   5. create/reconcile per-*arr filters (priority 1000-1002): Radarr is
--      gated by its list (shows matching); Sonarr/Lidarr are plain category
--      filters that route by announce category and let the arr decide
--   6. create/reconcile the cross-seed filter (priority 2000): an External
--      webhook asks cross-seed to inject matched announces directly into
--      Deluge before any arr filter sees them
--   7. remove stale lists and filters from earlier architectures
--   8. refresh the lists, then create the Gotify notification agent
--
-- Dependencies (nixpkgs): lua5_3, lua53Packages.{cjson,luasocket,luasql-sqlite3}
--
-- Nix passes a JSON overrides file as arg[1] (see setupConfig in default.nix)
-- holding the runtime values that only exist at eval time: the autobrr API
-- base/DB paths, key and Gotify token files, per-arr API keys and fallback
-- categories. Without arg[1] the static CONFIG defaults apply, and the env
-- vars below exist so this copy can run against the test harness.

local json = require "cjson"
local http = require "socket.http"
local ltn12 = require "ltn12"
local socket = require "socket"

local CONFIG = {
  autobrr_base = "http://127.0.0.1:7474/autobrr/api",
  autobrr_api_key = os.getenv("AUTOBRR_API_KEY"),
  autobrr_db = "/var/lib/autobrr/autobrr.db",
  api_key_file = "/var/lib/autobrr/apiKey",
  gotify_token_file = "/etc/nixos/secrets/gotify-token",
  gotify_host = "http://127.0.0.1:6789",
  -- Cross-seed announce endpoint. The API key is injected by Nix; the env
  -- fallback keeps this copy usable with the local test harness.
  cross_seed_announce_url = "http://127.0.0.1:2468/api/announce",
  cross_seed_api_key = os.getenv("CROSS_SEED_API_KEY") or "CROSS_SEED_API_KEY",
  -- Filters/lists from earlier architectures that get deleted on boot. Sonarr
  -- and Lidarr lists are gone because their title matching is unreliable;
  -- Radarr is the only list-gated arr (movies have stable titles). The
  -- category filters ("* Fallback", catch-all) were superseded by per-arr
  -- filters that route by announce category.
  stale_filters = {
    "arrs",
    "Sonarr Fallback",
    "Radarr Fallback",
    "Lidarr Fallback",
    "arrs Catch-all",
  },
  stale_lists = { "Sonarr", "Lidarr" },
  arrs = {
    {
      name = "Sonarr",
      type = "SONARR",
      base = "http://127.0.0.1:8989/sonarr/api/v3",
      host = "http://127.0.0.1:8989/sonarr",
      api_key = os.getenv("SONARR_API_KEY") or "SONARR_API_KEY",
      filter_priority = 1000,
      -- Category gate: every TV* announce goes to Sonarr, which decides.
      use_list = false,
      fallback_categories = { "TV*" },
      events = { onSeriesAdd = true, onSeriesDelete = true },
    },
    {
      name = "Radarr",
      type = "RADARR",
      base = "http://127.0.0.1:7878/radarr/api/v3",
      host = "http://127.0.0.1:7878/radarr",
      api_key = os.getenv("RADARR_API_KEY") or "RADARR_API_KEY",
      filter_priority = 1001,
      -- List-gated: only releases matching a monitored movie title are pushed.
      use_list = true,
      fallback_categories = {},
      events = { onMovieAdded = true, onMovieDelete = true },
    },
    {
      name = "Lidarr",
      type = "LIDARR",
      base = "http://127.0.0.1:8686/lidarr/api/v1",
      host = "http://127.0.0.1:8686/lidarr",
      api_key = os.getenv("LIDARR_API_KEY") or "LIDARR_API_KEY",
      filter_priority = 1002,
      -- Category gate: every music announce goes to Lidarr, which decides.
      use_list = false,
      fallback_categories = { "Audio*", "Music*", "FLAC*", "MP3*" },
      events = { onArtistAdd = true, onArtistDelete = true },
    },
  },
}

json.encode_empty_table_as_object(false)
local empty_array = json.array_mt
local function empty() return setmetatable({}, empty_array) end

-- --- tiny HTTP client ----------------------------------------------------

local function http_request(method, url, headers, body)
  body = body or ""
  if body ~= "" then
    headers["Content-Length"] = tostring(#body)
  end
  local sink = {}
  local res, code, _, status = http.request{
    url = url,
    method = method,
    headers = headers,
    source = ltn12.source.string(body),
    sink = ltn12.sink.table(sink),
  }
  if not res then
    return nil, tostring(code) .. (status and (" " .. status) or "")
  end
  if code >= 400 then
    return nil, ("%s %s"):format(code, status or "error")
  end
  local text = table.concat(sink)
  if text == "" then return empty() end
  local ok, data = pcall(json.decode, text)
  if not ok then return nil, "invalid JSON response" end
  return data
end

-- --- autobrr API client --------------------------------------------------

local Autobrr = {}
Autobrr.__index = Autobrr

function Autobrr.new(base, token)
  return setmetatable({ base = base, token = token }, Autobrr)
end

function Autobrr:request(method, path, payload)
  local headers = { ["X-API-Token"] = self.token }
  if payload ~= nil then
    headers["Content-Type"] = "application/json"
  end
  return http_request(method, self.base .. path, headers, payload and json.encode(payload))
end

function Autobrr:get(path) return self:request("GET", path) end
function Autobrr:post(path, payload) return self:request("POST", path, payload) end
function Autobrr:put(path, payload) return self:request("PUT", path, payload) end
function Autobrr:patch(path, payload) return self:request("PATCH", path, payload) end
function Autobrr:delete(path) return self:request("DELETE", path) end

function Autobrr:is_ready()
  local _, code = http.request{
    url = self.base .. "/healthz/readiness",
    method = "GET",
    headers = {},
    sink = ltn12.sink.table({}),
  }
  return type(code) == "number" and code >= 200 and code < 300
end

-- --- helpers -------------------------------------------------------------

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return content:gsub("%s+$", "")
end

local function find_by_name(items, name)
  for _, item in ipairs(items or {}) do
    if item.name == name then return item end
  end
end

-- --- config overrides (arg[1], generated by Nix) ---------------------------

-- Merge a JSON overrides file into CONFIG. Scalars replace their CONFIG
-- counterpart directly; arrs are matched by name so the static defaults for
-- everything Nix does not know about (ports, hosts, priorities, events) stay
-- intact.
local function load_config(path)
  if not path then return end
  local f = io.open(path, "rb")
  if not f then return end
  local text = f:read("*a")
  f:close()
  local ok, overrides = pcall(json.decode, text)
  if not ok or type(overrides) ~= "table" then
    print(("autobrr-setup: ignoring unreadable config %s"):format(path))
    return
  end
  for k, v in pairs(overrides) do
    if k ~= "arrs" then CONFIG[k] = v end
  end
  for _, ov in ipairs(overrides.arrs or empty()) do
    local arr = find_by_name(CONFIG.arrs, ov.name)
    if arr then
      if ov.api_key then arr.api_key = ov.api_key end
      if ov.fallback_categories then arr.fallback_categories = ov.fallback_categories end
    end
  end
end

-- --- step 1: make sure the API key row exists in the database ------------

local function ensure_api_key_in_db(db, key)
  local ok, luasql = pcall(require, "luasql.sqlite3")
  if not ok then return end
  local f = io.open(db, "rb")
  if not f then return end
  f:close()
  local env = luasql.sqlite3()
  local con = env:connect(db); if not con then env:close(); return end
  pcall(con.execute, con, ("INSERT OR IGNORE INTO api_key (name, key, scopes) VALUES ('nixos', '%s', '{}');"):format((tostring(key):gsub("'", "''"))))
  con:close()
  env:close()
end

-- --- step 3: *arr -> autobrr webhook notifications -----------------------

local function ensure_webhook(arr, webhook_url, autobrr_token)
  local auth = { ["X-Api-Key"] = arr.api_key }

  local notifications = http_request("GET", arr.base .. "/notification", auth)
  if notifications and find_by_name(notifications, "autobrr") then
    print(("autobrr-setup: %s webhook notification already exists"):format(arr.name))
    return true
  end

  local payload = {
    name = "autobrr",
    implementation = "Webhook",
    configContract = "WebhookSettings",
    tags = empty(),
    fields = {
      { name = "url", value = webhook_url },
      { name = "method", value = 1 },
      { name = "username", value = "" },
      { name = "password", value = "" },
      { name = "headers", value = { { key = "X-API-Token", value = autobrr_token } } },
    },
  }
  for k, v in pairs(arr.events) do payload[k] = v end

  print(("autobrr-setup: creating %s webhook notification..."):format(arr.name))
  auth["Content-Type"] = "application/json"
  local created = http_request("POST", arr.base .. "/notification?forceSave=true",
    auth, json.encode(payload))
  if created then
    print(("autobrr-setup: created %s webhook notification"):format(arr.name))
    return true
  end
  print(("autobrr-setup: failed to create %s webhook notification (non-fatal)"):format(arr.name))
  return false
end

-- --- step 4: autobrr download clients ------------------------------------

local function ensure_download_client(autobrr, arr)
  local clients = autobrr:get("/download_clients")
  if clients and find_by_name(clients, arr.name) then
    return true
  end
  print(("autobrr-setup: creating %s target..."):format(arr.name))
  local created, err = autobrr:post("/download_clients", {
    enabled = true,
    host = arr.host,
    name = arr.name,
    settings = { apikey = arr.api_key, basic = {}, external_download_client_id = 0 },
    type = arr.type,
  })
  print(created and ("autobrr-setup: created %s target"):format(arr.name)
    or ("autobrr-setup: failed to create %s target (%s) (non-fatal)"):format(arr.name, err))
  return created
end

-- --- step 5/6: filters, lists and fallbacks -------------------------------

local function ensure_filter_id(autobrr, name)
  local filters = autobrr:get("/filters")
  if filters then
    local f = find_by_name(filters, name)
    if f then return f.id end
  end
  print(("autobrr-setup: creating %s filter..."):format(name))
  autobrr:post("/filters", {
    name = name,
    enabled = true,
    resolutions = empty(),
    codecs = empty(),
    sources = empty(),
    containers = empty(),
  })
  local after = autobrr:get("/filters")
  local f = after and find_by_name(after, name)
  return f and f.id
end

-- The autobrr API only persists a filter's indexers/actions/lists via PUT or
-- PATCH; POST stores just the bare row. Reconcile therefore creates bare, then
-- PATCHes the full payload on every boot. PATCH (updatePartial) only touches
-- the fields present in the body, so list-managed fields like `shows` (which
-- the title list writes) are not clobbered — a PUT here would wipe them on
-- every boot until the list refresh repopulated them.
--
-- clear_list_fields is set for filters that are no longer list-gated: it
-- explicitly zeroes the list-managed `shows`/`albums`/`artists`, otherwise a
-- stale list's frozen titles would keep gating the filter forever.
local function reconcile_filter(autobrr, name, priority, categories, indexers, actions, clear_list_fields)
  local id = ensure_filter_id(autobrr, name)
  if not id then
    print(("autobrr-setup: failed to create %s filter"):format(name))
    return
  end
  local payload = {
    name = name,
    enabled = true,
    priority = priority,
    min_size = "25MB",
    max_size = "1TB",
    indexers = indexers,
    resolutions = empty(),
    codecs = empty(),
    sources = empty(),
    containers = empty(),
    actions = actions,
  }
  if categories then
    payload.match_categories = table.concat(categories, ",")
  end
  if clear_list_fields then
    payload.shows = ""
    payload.albums = ""
    payload.artists = ""
  end
  local ok, err = autobrr:patch(("/filters/%d"):format(id), payload)
  print(ok and ("autobrr-setup: reconciled %s filter id=%d"):format(name, id)
    or ("autobrr-setup: failed to reconcile %s filter (%s), retried next boot"):format(name, err))
end

-- The cross-seed filter is intentionally broader than the arr filters: no
-- size, category, quality, title or list gates. Its External WEBHOOK POSTs each
-- announce to cross-seed's /api/announce. cross-seed returns 200 only for a
-- release that matches an existing library torrent and injects it directly
-- into Deluge; 204 means no match, so the filter rejects and the announce
-- falls through to the arr filters; 202 means the source is still downloading
-- and autobrr retries at the configured interval.
--
-- The only action is TEST: a 200 marks this higher-priority filter as matched,
-- which stops the lower-priority arr filters from also pushing the same
-- announce. There is deliberately no download action on this filter.
local function reconcile_cross_seed_filter(autobrr, indexers)
  local name = "cross-seed"
  local id = ensure_filter_id(autobrr, name)
  if not id then
    print("autobrr-setup: failed to create cross-seed filter")
    return
  end

  -- StoreFilterActions updates actions with an id and inserts ones without,
  -- but never removes actions omitted from the payload. Reuse an existing TEST
  -- action and delete the rest after the PATCH so this filter always ends with
  -- exactly one action.
  local path = ("/filters/%d"):format(id)
  local current = autobrr:get(path)
  local action = { name = name, type = "TEST", enabled = true }
  local stale_actions = empty()
  if current and current.actions then
    for _, existing in ipairs(current.actions) do
      if existing.type == "TEST" and not action.id then
        action.id = existing.id
      elseif existing.id and existing.id > 0 then
        stale_actions[#stale_actions + 1] = existing.id
      end
    end
  end

  -- Explicitly clear every gate that could survive from an older version of
  -- this filter. Omitted PATCH fields are left untouched by autobrr.
  local payload = {
    name = name,
    enabled = true,
    priority = 2000,
    min_size = "",
    max_size = "",
    delay = 0,
    max_downloads = 0,
    max_downloads_unit = "",
    max_downloads_period = 0,
    max_downloads_window_type = "",
    announce_types = empty(),
    scene = false,
    origins = empty(),
    except_origins = empty(),
    match_releases = "",
    except_releases = "",
    use_regex = false,
    match_release_groups = "",
    except_release_groups = "",
    bonus = empty(),
    freeleech = false,
    freeleech_percent = "",
    smart_episode = false,
    shows = "",
    seasons = "",
    episodes = "",
    resolutions = empty(),
    codecs = empty(),
    sources = empty(),
    containers = empty(),
    match_hdr = empty(),
    except_hdr = empty(),
    match_other = empty(),
    except_other = empty(),
    years = "",
    months = "",
    days = "",
    artists = "",
    albums = "",
    match_release_types = empty(),
    except_release_types = "",
    formats = empty(),
    quality = empty(),
    media = empty(),
    perfect_flac = false,
    cue = false,
    log = false,
    log_score = 0,
    match_categories = "",
    except_categories = "",
    match_uploaders = "",
    except_uploaders = "",
    match_record_labels = "",
    except_record_labels = "",
    match_language = empty(),
    except_language = empty(),
    tags = "",
    except_tags = "",
    tags_any = "",
    except_tags_any = "",
    tags_match_logic = "",
    except_tags_match_logic = "",
    match_release_tags = "",
    except_release_tags = "",
    use_regex_release_tags = false,
    match_description = "",
    except_description = "",
    use_regex_description = false,
    min_seeders = 0,
    max_seeders = 0,
    min_leechers = 0,
    max_leechers = 0,
    release_profile_duplicate_id = 0,
    indexers = indexers,
    actions = { action },
    external = {
      {
        name = name,
        index = 0,
        type = "WEBHOOK",
        enabled = true,
        webhook_host = CONFIG.cross_seed_announce_url,
        webhook_method = "POST",
        webhook_headers = "x-api-key=" .. tostring(CONFIG.cross_seed_api_key),
        webhook_data = '{ "name": {{ toRawJson .TorrentName }}, "guid": "{{ .TorrentUrl }}", "link": "{{ .TorrentUrl }}", "tracker": {{ toRawJson .IndexerName }} }',
        webhook_expect_status = 200,
        webhook_retry_status = "202",
        webhook_retry_attempts = 100,
        webhook_retry_delay_seconds = 900,
        on_error = "REJECT",
      },
    },
  }

  local ok, err = autobrr:patch(path, payload)
  if not ok then
    print(("autobrr-setup: failed to reconcile cross-seed filter (%s), retried next boot"):format(err))
    return
  end
  for _, action_id in ipairs(stale_actions) do
    autobrr:delete(("/actions/%d"):format(action_id))
  end
  print(("autobrr-setup: reconciled cross-seed filter id=%d"):format(id))
end

local function ensure_list(autobrr, arr)
  local lists = autobrr:get("/lists")
  local existing = lists and find_by_name(lists, arr.name)
  local payload = {
    name = arr.name,
    type = arr.type,
    enabled = true,
    client_id = arr.client_id,
    headers = empty(),
    tags_included = empty(),
    tags_excluded = empty(),
    filters = { { id = arr.filter_id, name = arr.name } },
    match_release = false,
    include_unmonitored = false,
    include_alternate_titles = true,
  }
  if existing then
    if existing.id > 0 then
      payload.id = existing.id
      print(("autobrr-setup: reconciling %s list..."):format(arr.name))
      local ok, err = autobrr:put(("/lists/%d"):format(existing.id), payload)
      print(ok and ("autobrr-setup: reconciled %s list"):format(arr.name)
        or ("autobrr-setup: failed to reconcile %s list (%s), retried on next boot"):format(arr.name, err))
    else
      print(("autobrr-setup: %s list exists but has no id, skipping"):format(arr.name))
    end
  else
    print(("autobrr-setup: creating %s list..."):format(arr.name))
    local ok, err = autobrr:post("/lists", payload)
    print(ok and ("autobrr-setup: created %s list (title sync triggered)"):format(arr.name)
      or ("autobrr-setup: failed to create %s list (%s), retried on next boot"):format(arr.name, err))
  end
end

local function remove_stale_filters(autobrr)
  for _, stale in ipairs(CONFIG.stale_filters) do
    local filters = autobrr:get("/filters")
    local f = filters and find_by_name(filters, stale)
    if f then
      local ok, err = autobrr:delete(("/filters/%d"):format(f.id))
      print(ok and ("autobrr-setup: removed superseded '%s' filter"):format(stale)
        or ("autobrr-setup: failed to remove superseded '%s' filter (%s)"):format(stale, err))
    end
  end
end

-- Stale lists must be deleted, not just left orphaned: an orphaned list keeps
-- refreshing and re-writing `shows` into the filter it still references, which
-- would re-gate a filter that is now meant to be a plain category filter.
local function remove_stale_lists(autobrr)
  for _, stale in ipairs(CONFIG.stale_lists) do
    local lists = autobrr:get("/lists")
    local l = lists and find_by_name(lists, stale)
    if l and l.id > 0 then
      local ok, err = autobrr:delete(("/lists/%d"):format(l.id))
      print(ok and ("autobrr-setup: removed superseded '%s' list"):format(stale)
        or ("autobrr-setup: failed to remove superseded '%s' list (%s)"):format(stale, err))
    end
  end
end

-- Configured indexers live at /indexer/options on autobrr 1.90+; older
-- releases expose the same list at /indexers. Archived indexers are rejected
-- by the filter API, so never send their ids. Both endpoints are tried on each
-- attempt to keep boot reconciliation working across versions.
local function configured_indexers(autobrr)
  local function collect(data, out)
    if type(data) ~= "table" then return end
    for _, ix in ipairs(data) do
      local id = tonumber(ix.id) or 0
      if id > 0 and ix.archived ~= true then
        out[#out + 1] = { id = id, name = ix.name }
      end
    end
  end

  for _ = 1, 5 do
    local indexers = empty()
    collect(autobrr:get("/indexer/options"), indexers)
    if #indexers == 0 then
      collect(autobrr:get("/indexers"), indexers)
    end
    if #indexers > 0 then return indexers end
    socket.sleep(5)
  end
  return empty()
end

-- --- step 8: list refresh + Gotify ----------------------------------------

local function ensure_gotify(autobrr, token)
  if not token then return end
  local notifications = autobrr:get("/notification")
  if notifications and find_by_name(notifications, "Gotify") then
    return
  end
  print("autobrr-setup: creating Gotify notification agent...")
  local ok, err = autobrr:post("/notification", {
    enabled = true,
    type = "GOTIFY",
    name = "Gotify",
    events = { "PUSH_APPROVED", "PUSH_ERROR" },
    host = CONFIG.gotify_host,
    token = token,
  })
  print(ok and "autobrr-setup: created Gotify notification agent"
    or ("autobrr-setup: failed to create Gotify agent (%s) (non-fatal)"):format(err))
end

-- --- main -----------------------------------------------------------------

local function main()
  local api_key = CONFIG.autobrr_api_key
    or read_file(CONFIG.api_key_file)
    or (CONFIG.api_key_file_fallback and read_file(CONFIG.api_key_file_fallback))
  if not api_key then
    print("autobrr-setup: API key not found, skipping")
    os.exit(0)
  end
  ensure_api_key_in_db(CONFIG.autobrr_db, api_key)

  local autobrr = Autobrr.new(CONFIG.autobrr_base, api_key)
  local webhook_url = CONFIG.autobrr_base .. "/webhook/lists/trigger/arr"

  print("autobrr-setup: waiting for autobrr to be ready...")
  local ready = false
  for _ = 1, 30 do
    if autobrr:is_ready() then
      ready = true
      break
    end
    socket.sleep(1)
  end
  if not ready then
    print("autobrr-setup: autobrr not ready after 30 s, skipping")
    os.exit(0)
  end
  print("autobrr-setup: autobrr is ready")

  for _ = 1, 6 do
    local all = true
    for _, arr in ipairs(CONFIG.arrs) do
      if arr.use_list then
        all = ensure_webhook(arr, webhook_url, api_key) and all
      end
    end
    if all then break end
    socket.sleep(5)
  end

  for _, arr in ipairs(CONFIG.arrs) do
    ensure_download_client(autobrr, arr)
  end

  local indexers = configured_indexers(autobrr)
  if #indexers > 0 then
    local names = {}
    for _, ix in ipairs(indexers) do names[#names + 1] = ix.name end
    print(("autobrr-setup: attaching %d indexers to filters: %s"):format(#indexers, table.concat(names, ", ")))
    -- Cross-seed only needs indexers; it does not depend on the *arr download
    -- clients, so reconcile it before and independently of that readiness gate.
    reconcile_cross_seed_filter(autobrr, indexers)
  else
    print("autobrr-setup: no configured indexers found; skipping filter reconciliation to protect existing filter connections")
  end

  local clients = autobrr:get("/download_clients")
  local ids = {}
  for _, arr in ipairs(CONFIG.arrs) do
    local c = clients and find_by_name(clients, arr.name)
    ids[arr.name] = c and c.id
  end

  local all_clients = true
  for _, arr in ipairs(CONFIG.arrs) do
    if not ids[arr.name] then all_clients = false end
  end

  if not all_clients then
    print("autobrr-setup: download clients not found, skipping *arr filters")
  elseif #indexers == 0 then
    print("autobrr-setup: no configured indexers found, skipping *arr filters")
  else
    remove_stale_filters(autobrr)
    remove_stale_lists(autobrr)

    for _, arr in ipairs(CONFIG.arrs) do
      local filter_id = ensure_filter_id(autobrr, arr.name)
      if filter_id then
        arr.filter_id = filter_id
        arr.client_id = ids[arr.name]
        local action = { { name = arr.name, type = arr.type, enabled = true, client_id = ids[arr.name] } }
        local categories = nil
        if not arr.use_list then
          categories = arr.fallback_categories
        end
        reconcile_filter(autobrr, arr.name, arr.filter_priority, categories, indexers, action, not arr.use_list)
        if arr.use_list then
          ensure_list(autobrr, arr)
        end
      end
    end

    local use_lists = false
    for _, arr in ipairs(CONFIG.arrs) do
      if arr.use_list then use_lists = true end
    end
    if use_lists then
      local ok, err = autobrr:post("/lists/refresh")
      print(ok and "autobrr-setup: refreshed lists"
      or ("autobrr-setup: list refresh failed (%s) (non-fatal)"):format(err))
    end
  end

  ensure_gotify(autobrr, read_file(CONFIG.gotify_token_file))
  print("autobrr-setup: done")
end

load_config(arg[1])
main()
