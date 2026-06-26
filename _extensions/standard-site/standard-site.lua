-- standard-site.lua — Quarto shortcodes to embed standard.site publications
-- and documents into a Quarto website, one-way (read-only).
--
-- Usage:
--   {{< standard-document uri="at://did:.../site.standard.document/rkey" >}}
--   {{< standard-publication uri="at://did:.../site.standard.publication/rkey" >}}
--
-- Both fetch at build time (Quarto render) from the author's PDS and bake the
-- result into static HTML. No JavaScript, no client-side network, no secrets.

local Atproto = require("atproto")

-- --------------------------------------------------------------------------
-- Small helpers
-- --------------------------------------------------------------------------

local function tag(msg) return "[standard-site] " .. msg end

-- Return a visible, styled error block instead of throwing. A single bad URI
-- should never abort an entire website render.
local function errBlock(msg)
  quarto.log.error(tag(msg))
  return pandoc.Div(
    { pandoc.Para({ pandoc.Strong({ pandoc.Str("[standard-site] ") }),
                    pandoc.Str(tostring(msg)) }) },
    { class = "standard-site-error" }
  )
end

local function info(msg) quarto.log.output(tag(msg)) end

-- Read the doc/site collection from an at:// URI (the last-but-one segment).
local function collectionOf(uri)
  return uri:match("at://[^/]+/([^/]+)")
end

-- Pull & validate the at:// uri from shortcode kwargs/args. Returns (uri) or
-- (nil, errBlock) — centralizes the duplicated validation in both shortcodes.
local function requireUri(kwargs, args, shortName, collection)
  local uri = pandoc.utils.stringify(kwargs["uri"] or args[1] or "")
  if uri == "" then
    return nil, errBlock(shortName .. " requires an at:// uri (uri= or positional).")
  end
  if collectionOf(uri) ~= collection then
    return nil, errBlock(shortName .. " expects a " .. collection .. " URI, got: " .. uri)
  end
  return uri
end

local MONTHS = {
  "January", "February", "March", "April", "May", "June",
  "July", "August", "September", "October", "November", "December",
}

-- Format an ISO datetime as "14 April 2026". Returns nil if unparseable.
local function formatDate(iso)
  if type(iso) ~= "string" then return nil end
  local y, m, d = iso:match("^(%d%d%d%d)-(%d%d)-(%d%d)")
  if not y then return nil end
  return tonumber(d) .. " " .. MONTHS[tonumber(m)] .. " " .. y
end

-- Finish a byline: append " · <date>" if present, return a Para or nil if empty.
local function bylinePara(byline, publishedAt)
  local date = formatDate(publishedAt)
  if date then
    if #byline > 0 then table.insert(byline, pandoc.Str(" · ")) end
    table.insert(byline, pandoc.Str(date))
  end
  if #byline == 0 then return nil end
  return pandoc.Para(byline)
end

-- Split a plaintext body into pandoc Para blocks, one per line. Real
-- standard.site textContent uses single newlines as paragraph separators
-- (verified against live records: 0 blank-line breaks), so each non-empty
-- line is its own paragraph. Native content unions are platform-specific
-- (e.g. blog.pckt.content blocks) and left for later.
local function textBodyToBlocks(text)
  local blocks = {}
  if not text or text == "" then return blocks end
  for para in text:gmatch("([^\n]+)") do
    para = para:gsub("^%s+", ""):gsub("%s+$", "")
    if para ~= "" then
      table.insert(blocks, pandoc.Para(pandoc.Str(para)))
    end
  end
  return blocks
end

-- Ensure the extension's stylesheet ships with HTML output.
local function ensureDeps()
  if not quarto.doc.is_format("html:js") then return end
  quarto.doc.add_html_dependency({
    name = "standard-site",
    version = "0.1.0",
    stylesheets = { "styles.css" },
  })
end

-- Fetch a cover image blob into the mediabag; return the src name or nil.
local function coverSrc(docUri, coverBlob)
  if type(coverBlob) ~= "table" then return nil end
  local cid = coverBlob.ref and coverBlob.ref["$link"] or coverBlob.cid
  if not cid then return nil end
  local did = docUri:match("^at://([^/]+)")
  local name = Atproto.getBlob(did, cid, coverBlob.mimeType, "standard-site/cover-" .. cid)
  return name
end

-- --------------------------------------------------------------------------
-- Inline (full-content) document renderer
-- --------------------------------------------------------------------------

local function renderDocumentFull(docValue, pubValue, docUri, opts)
  local blocks = {}
  local div = pandoc.Div({}, { class = "standard-site-document" })

  -- Cover image
  if opts.showCover ~= false and docValue.coverImage then
    local src = coverSrc(docUri, docValue.coverImage)
    if src then
      local img = pandoc.Image({ pandoc.Str("") }, src, "", { class = "standard-site-cover" })
      table.insert(blocks, pandoc.Para({ img }))
    end
  end

  -- Title
  if docValue.title and docValue.title ~= "" then
    table.insert(blocks, pandoc.Header(2, { pandoc.Str(docValue.title) },
      { class = "standard-site-title" }))
  end

  -- Byline: publication name (linked) + date
  local byline = {}
  local canonical = Atproto.canonicalUrl(docValue, pubValue)
  local pubName = pubValue and pubValue.name
  if pubName and pubName ~= "" then
    local nameInlines = { pandoc.Str(pubName) }
    if canonical then
      table.insert(byline, pandoc.Link(nameInlines, canonical))
    else
      for _, n in ipairs(nameInlines) do table.insert(byline, n) end
    end
  end
  local p = bylinePara(byline, docValue.publishedAt)
  if p then table.insert(blocks, p) end

  -- Tags
  if type(docValue.tags) == "table" and #docValue.tags > 0 then
    local tagInlines = {}
    for i, t in ipairs(docValue.tags) do
      if i > 1 then table.insert(tagInlines, pandoc.Str(" ")) end
      table.insert(tagInlines, pandoc.Span({ pandoc.Str(t) },
        { class = "standard-site-tag" }))
    end
    table.insert(blocks, pandoc.Para(tagInlines))
  end

  -- Description as a lead, but only when it is NOT the opening of the body.
  -- Platforms often store a truncated excerpt as `description`, so we compare
  -- a 40-char prefix to avoid printing the same text twice.
  local bodyText = docValue.textContent or ""
  local descIsBodyPrefix = false
  if docValue.description and bodyText ~= "" then
    local n = math.min(40, #docValue.description)
    descIsBodyPrefix = bodyText:sub(1, n) == docValue.description:sub(1, n)
  end
  if docValue.description and docValue.description ~= "" and not descIsBodyPrefix then
    table.insert(blocks, pandoc.Para({ pandoc.Emph({ pandoc.Str(docValue.description) }) }))
  end

  -- Body: textContent rendered as paragraphs.
  local body = textBodyToBlocks(bodyText)
  if #body == 0 then
    -- No inline content: fall back to the description, else a clear note.
    if docValue.description and docValue.description ~= "" then
      table.insert(blocks, pandoc.Para({ pandoc.Str(docValue.description) }))
    else
      table.insert(blocks, pandoc.Para({
        pandoc.Emph({ pandoc.Str("This document has no inline content; it links out to its canonical URL.") })
      }))
    end
  else
    for _, b in ipairs(body) do table.insert(blocks, b) end
  end

  -- Footer: canonical link
  if canonical then
    table.insert(blocks, pandoc.Para({
      pandoc.Span({ pandoc.Str("↗ Read on the original site: ") },
        { class = "standard-site-canonical-label" }),
      pandoc.Link({ pandoc.Str(canonical) }, canonical),
    }))
  end

  div.content = blocks
  return div
end

-- --------------------------------------------------------------------------
-- Card (compact) document renderer — used in feeds and mode="card"
-- --------------------------------------------------------------------------

local function renderDocumentCard(docValue, pubValue, docUri)
  local div = pandoc.Div({}, { class = "standard-site-card" })
  local blocks = {}
  local canonical = Atproto.canonicalUrl(docValue, pubValue)

  -- Cover
  if docValue.coverImage then
    local src = coverSrc(docUri, docValue.coverImage)
    if src then
      local img = pandoc.Image({ pandoc.Str(docValue.title or "") }, src, "",
        { class = "standard-site-card-cover" })
      table.insert(blocks, pandoc.Para({ img }))
    end
  end

  -- Title (linked)
  if docValue.title and docValue.title ~= "" then
    local titleInlines = { pandoc.Str(docValue.title) }
    if canonical then
      table.insert(blocks, pandoc.Header(3,
        { pandoc.Link(titleInlines, canonical) }, { class = "standard-site-card-title" }))
    else
      table.insert(blocks, pandoc.Header(3, titleInlines, { class = "standard-site-card-title" }))
    end
  end

  -- Description
  if docValue.description and docValue.description ~= "" then
    table.insert(blocks, pandoc.Para({ pandoc.Str(docValue.description) }))
  end

  -- Byline
  local byline = {}
  local pubName = pubValue and pubValue.name
  if pubName and pubName ~= "" then
    table.insert(byline, pandoc.Span({ pandoc.Str(pubName) }, { class = "standard-site-pub-name" }))
  end
  local p = bylinePara(byline, docValue.publishedAt)
  if p then table.insert(blocks, p) end

  div.content = blocks
  return div
end

-- --------------------------------------------------------------------------
-- Resolve the publication referenced by a document's `site` field.
-- `site` is normally an at:// site.standard.publication ref; may also be a
-- bare https URL for loose documents (then we return nil — no publication).
-- --------------------------------------------------------------------------

local function resolvePublication(siteField)
  if type(siteField) == "string" and siteField:match("^at://") then
    local pub = Atproto.getRecord(siteField)
    if pub and pub.value then return pub.value end
  end
  return nil
end

-- --------------------------------------------------------------------------
-- shortcodes
-- --------------------------------------------------------------------------

-- {{< standard-document uri="at://..." mode="full|card" show-cover=true >}}
local function standardDocument(args, kwargs, meta)
  if not quarto.doc.is_format("html") then return pandoc.Null() end
  ensureDeps()

  local uri, err = requireUri(kwargs, args, "standard-document", "site.standard.document")
  if not uri then return err end

  local mode = pandoc.utils.stringify(kwargs["mode"] or "full")
  local showCoverRaw = pandoc.utils.stringify(kwargs["show-cover"] or "true")
  local opts = { showCover = (showCoverRaw ~= "false") }

  info("fetching document " .. uri)
  local record, err = Atproto.getRecord(uri)
  if not record then return errBlock(tostring(err)) end
  local docValue = record.value

  local pubValue = resolvePublication(docValue.site)

  if mode == "card" then
    return renderDocumentCard(docValue, pubValue, uri)
  end
  return renderDocumentFull(docValue, pubValue, uri, opts)
end

-- {{< standard-publication uri="at://..." limit=10 >}}
local function standardPublication(args, kwargs, meta)
  if not quarto.doc.is_format("html") then return pandoc.Null() end
  ensureDeps()

  local uri, err = requireUri(kwargs, args, "standard-publication", "site.standard.publication")
  if not uri then return err end

  local limit = tonumber(pandoc.utils.stringify(kwargs["limit"] or "10")) or 10

  info("fetching publication " .. uri)
  local pubRecord, err = Atproto.getRecord(uri)
  if not pubRecord then return errBlock(tostring(err)) end
  local pubValue = pubRecord.value

  local did = uri:match("^at://([^/]+)")
  info("listing documents for " .. did)
  local listed, err2 = Atproto.listRecords(did, "site.standard.document", 100)
  if not listed then return errBlock(tostring(err2)) end

  -- Keep only documents belonging to THIS publication, newest first.
  local docs = {}
  for _, r in ipairs(listed.records or {}) do
    if r.value and r.value.site == uri then
      table.insert(docs, r)
    end
  end
  table.sort(docs, function(a, b)
    local da = a.value.publishedAt or ""
    local db = b.value.publishedAt or ""
    return da > db
  end)

  local div = pandoc.Div({}, { class = "standard-site-publication" })
  local blocks = {}

  -- Publication header
  table.insert(blocks, pandoc.Header(2,
    { pandoc.Str(pubValue.name or "Publication") }, { class = "standard-site-pub-title" }))
  if pubValue.description and pubValue.description ~= "" then
    table.insert(blocks, pandoc.Para({ pandoc.Str(pubValue.description) }))
  end

  -- Document cards
  if #docs == 0 then
    table.insert(blocks, pandoc.Para({
      pandoc.Emph({ pandoc.Str("No documents found for this publication.") }) }))
  else
    local n = math.min(limit, #docs)
    for i = 1, n do
      table.insert(blocks, renderDocumentCard(docs[i].value, pubValue, docs[i].uri))
    end
  end

  div.content = blocks
  return div
end

return {
  ["standard-document"] = standardDocument,
  ["standard-doc"] = standardDocument, -- shorter alias
  ["standard-publication"] = standardPublication,
}
