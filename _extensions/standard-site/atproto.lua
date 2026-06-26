-- atproto.lua — read-only AT Protocol client for standard.site records.
--
-- Why this exists: the Bluesky AppView (public.api.bsky.app) does NOT index
-- site.standard.* records. getRecord returns RecordNotFound and listRecords
-- returns MethodNotImplemented for those collections. So we always read
-- directly from the author's Personal Data Server (PDS), resolving the DID →
-- PDS endpoint via the PLC directory first.
--
-- Everything here is unauthenticated and read-only. No secrets, no writes.

local Atproto = {}

-- Endpoints
local PLC_URL = "https://plc.directory/"

-- Process-scoped caches so a single render hitting many docs by the same
-- author pays the PLC lookup once.
local PDS_CACHE = _G.STANDARD_SITE_PDS_CACHE or {}
_G.STANDARD_SITE_PDS_CACHE = PDS_CACHE

local RECORD_CACHE = _G.STANDARD_SITE_RECORD_CACHE or {}
_G.STANDARD_SITE_RECORD_CACHE = RECORD_CACHE

-- Small fetch helper around pandoc.mediabag.fetch with pcall.
-- Returns (mimetype, body) or (nil, err).
local function fetch(url)
  local ok, mt, body = pcall(pandoc.mediabag.fetch, url)
  if not ok then
    return nil, "network error fetching " .. url .. ": " .. tostring(mt)
  end
  if not body or body == "" then
    return nil, "empty response from " .. url
  end
  return mt, body
end

-- Parse an at:// URI into { did, collection, rkey }.
-- Accepts: at://did:plc:abc/site.standard.document/rkey
function Atproto.parseAtUri(uri)
  if type(uri) ~= "string" then return nil, "uri is not a string" end
  local did, collection, rkey = uri:match("^at://([^/]+)/([^/]+)/([^/%?]+)")
  if not (did and collection and rkey) then
    return nil, "could not parse at:// URI: " .. tostring(uri)
  end
  return { did = did, collection = collection, rkey = rkey }
end

-- Resolve a DID to its PDS service endpoint via the PLC directory.
-- Returns the bare endpoint URL (no trailing slash) or (nil, err).
function Atproto.resolvePds(did)
  if PDS_CACHE[did] then return PDS_CACHE[did] end

  local mt, body = fetch(PLC_URL .. did)
  if not mt then return nil, body end

  local ok, doc = pcall(quarto.json.decode, body)
  if not ok or type(doc) ~= "table" then
    return nil, "could not decode PLC document for " .. did
  end

  local endpoint
  for _, service in ipairs(doc.service or {}) do
    if service.id == "#atproto_pds" then
      endpoint = service.serviceEndpoint
      break
    end
  end
  if not endpoint then
    return nil, "no #atproto_pds service found for " .. did
  end

  endpoint = endpoint:gsub("/+$", "")
  PDS_CACHE[did] = endpoint
  return endpoint
end

-- Fetch a record by its at:// URI from the author's PDS.
-- Returns the decoded getRecord response (with .uri, .cid, .value) or (nil, err).
function Atproto.getRecord(uri)
  if RECORD_CACHE[uri] then return RECORD_CACHE[uri] end

  local parsed, err = Atproto.parseAtUri(uri)
  if not parsed then return nil, err end

  local pds, err2 = Atproto.resolvePds(parsed.did)
  if not pds then return nil, err2 end

  local url = string.format(
    "%s/xrpc/com.atproto.repo.getRecord?repo=%s&collection=%s&rkey=%s",
    pds, parsed.did, parsed.collection, parsed.rkey
  )
  local mt, body = fetch(url)
  if not mt then return nil, body end

  local ok, data = pcall(quarto.json.decode, body)
  if not ok or type(data) ~= "table" then
    return nil, "could not decode record response for " .. uri
  end
  if data.error then
    return nil, string.format("record error for %s: %s (%s)",
      uri, data.error, data.message or "")
  end

  RECORD_CACHE[uri] = data
  return data
end

-- List records in a collection for a repo (used for publication feeds).
-- Returns { records = { {uri=, cid=, value=} } } or (nil, err).
function Atproto.listRecords(did, collection, limit)
  local pds, err = Atproto.resolvePds(did)
  if not pds then return nil, err end

  local url = string.format(
    "%s/xrpc/com.atproto.repo.listRecords?repo=%s&collection=%s&limit=%d",
    pds, did, collection, limit or 50
  )
  local mt, body = fetch(url)
  if not mt then return nil, body end

  local ok, data = pcall(quarto.json.decode, body)
  if not ok or type(data) ~= "table" then
    return nil, "could not decode listRecords response for " .. did
  end
  if data.error then
    return nil, string.format("listRecords error: %s (%s)",
      data.error, data.message or "")
  end
  return data
end

-- Fetch a blob (e.g. a cover image) into the pandoc mediabag and return a
-- name that can be used as an image src. `mime` gives a hint for the extension.
-- Returns the mediabag item name, or (nil, err).
function Atproto.getBlob(did, cid, mime, nameHint)
  if not cid or cid == "" then return nil, "no cid provided" end
  local pds, err = Atproto.resolvePds(did)
  if not pds then return nil, err end

  local url = string.format(
    "%s/xrpc/com.atproto.sync.getBlob?did=%s&cid=%s", pds, did, cid
  )
  local realMime, body = fetch(url)
  if not realMime then return nil, body end

  local ext = "img"
  if mime then
    ext = mime:match("/(%w+)$") or "img"
  elseif realMime then
    ext = realMime:match("/(%w+)$") or "img"
  end
  local name = (nameHint or ("standard-site/" .. cid)) .. "." .. ext

  pandoc.mediabag.insert(name, realMime or mime or "application/octet-stream", body)
  return name
end

-- Given a document value and (optionally) its resolved publication value,
-- determine the canonical web URL to link the embed back to.
-- Priority: doc.canonicalUrl > publication.url + doc.path > doc.site (if https).
function Atproto.canonicalUrl(docValue, pubValue)
  if not docValue then return nil end
  if type(docValue.canonicalUrl) == "string" and docValue.canonicalUrl ~= "" then
    return docValue.canonicalUrl
  end
  local pubUrl
  if pubValue and type(pubValue.url) == "string" then pubUrl = pubValue.url end
  if not pubUrl and type(docValue.site) == "string" and docValue.site:match("^https?://") then
    pubUrl = docValue.site
  end
  if pubUrl and type(docValue.path) == "string" and docValue.path ~= "" then
    return pubUrl:gsub("/+$", "") .. docValue.path
  end
  return nil
end

return Atproto
