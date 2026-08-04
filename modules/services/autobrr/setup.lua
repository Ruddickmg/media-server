#!/usr/bin/env lua
-- autobrr-setup.lua
-- Lua setup for the autobrr service (modules/services/autobrr/default.nix),
-- run from the unit's postStart. Same jobs, same order:
--
--   1. ensure the autobrr API key row exists in the sqlite database
--   2. wait for the autobrr API to be ready
--   3. create *arr -> autobrr Webhook notifications (list-trigger on media
--      add/delete) so arr lists refresh within seconds
--   4. create autobrr download clients for each *arr if missing
--   5. create/reconcile per-*arr title filters (priority 1000-1002) linked to
--      autobrr lists with match_release=true (substring title matching)
--   6. create/reconcile low-priority fallback filters: category routing
--      (800-802) and a catch-all (500) that offers to every *arr
--   7. refresh the lists, then create the Gotify notification agent
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
  catch_all_priority = 500,
  stale_filters = { "cross-seed", "arrs" },
  arrs = {
    {
      name = "Sonarr",
      type = "SONARR",
      base = "http://127.0.0.1:8989/sonarr/api/v3",
      host = "http://127.0.0.1:8989/sonarr",
      api_key = os.getenv("SONARR_API_KEY") or "SONARR_API_KEY",
      filter_priority = 1000,
      fallback_priority = 800,
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
      fallback_priority = 801,
      fallback_categories = { "Movie*" },
      events = { onMovieAdded = true, onMovieDelete = true },
    },
    {
      name = "Lidarr",
      type = "LIDARR",
      base = "http://127.0.0.1:8686/lidarr/api/v1",
      host = "http://127.0.0.1:8686/lidarr",
      api_key = os.getenv("LIDARR_API_KEY") or "LIDARR_API_KEY",
      filter_priority = 1002,
      fallback_priority = 802,
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
  autobrr:post("/filters", { name = name, enabled = true })
  local after = autobrr:get("/filters")
  local f = after and find_by_name(after, name)
  return f and f.id
end

-- The autobrr API only persists a filter's indexers/actions via PUT; POST
-- stores just the bare row. Reconcile therefore creates bare, then PUTs the
-- full payload on every boot.
local function reconcile_filter(autobrr, name, priority, categories, indexers, actions)
  local id = ensure_filter_id(autobrr, name)
  if not id then
    print(("autobrr-setup: failed to create %s filter"):format(name))
    return
  end
  if #indexers == 0 then return end
  local payload = {
    name = name,
    enabled = true,
    priority = priority,
    min_size = "25MB",
    max_size = "1TB",
    indexers = indexers,
    actions = actions,
  }
  if categories then
    payload.match_categories = table.concat(categories, ",")
  end
  local ok, err = autobrr:put(("/filters/%d"):format(id), payload)
  print(ok and ("autobrr-setup: reconciled %s filter id=%d"):format(name, id)
    or ("autobrr-setup: failed to reconcile %s filter (%s), retried next boot"):format(name, err))
end

local function ensure_list(autobrr, arr)
  local lists = autobrr:get("/lists")
  local existing = lists and find_by_name(lists, arr.name)
  local payload = {
    name = arr.name,
    type = arr.type,
    enabled = true,
    client_id = arr.client_id,
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

-- --- step 7: list refresh + Gotify ----------------------------------------

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
      all = ensure_webhook(arr, webhook_url, api_key) and all
    end
    if all then break end
    socket.sleep(5)
  end

  for _, arr in ipairs(CONFIG.arrs) do
    ensure_download_client(autobrr, arr)
  end

  local indexers = {}
  for _ = 1, 5 do
    indexers = {}
    local data = autobrr:get("/indexers")
    if data then
      for _, ix in ipairs(data) do
        if ix.enabled then
          indexers[#indexers + 1] = { id = ix.id, name = ix.name }
        end
      end
    end
    if #indexers > 0 then break end
    socket.sleep(5)
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
  else
    remove_stale_filters(autobrr)

    for _, arr in ipairs(CONFIG.arrs) do
      local filter_id = ensure_filter_id(autobrr, arr.name)
      if filter_id then
        arr.filter_id = filter_id
        arr.client_id = ids[arr.name]
        local action = { { name = arr.name, type = arr.type, enabled = true, client_id = ids[arr.name] } }
        reconcile_filter(autobrr, arr.name, arr.filter_priority, nil, indexers, action)
        ensure_list(autobrr, arr)
      end
    end

    local catch_all_actions = {}
    for _, arr in ipairs(CONFIG.arrs) do
      catch_all_actions[#catch_all_actions + 1] = {
        name = arr.name, type = arr.type, enabled = true, client_id = ids[arr.name],
      }
    end

    for _, arr in ipairs(CONFIG.arrs) do
      if #arr.fallback_categories > 0 then
        local action = { { name = arr.name, type = arr.type, enabled = true, client_id = ids[arr.name] } }
        reconcile_filter(autobrr, arr.name .. " Fallback", arr.fallback_priority, arr.fallback_categories, indexers, action)
      end
    end

    reconcile_filter(autobrr, "arrs Catch-all", CONFIG.catch_all_priority, nil, indexers, catch_all_actions)

    local ok, err = autobrr:post("/lists/refresh")
    print(ok and "autobrr-setup: refreshed lists"
      or ("autobrr-setup: list refresh failed (%s) (non-fatal)"):format(err))
  end

  ensure_gotify(autobrr, read_file(CONFIG.gotify_token_file))
  print("autobrr-setup: done")
end

load_config(arg[1])
main()
