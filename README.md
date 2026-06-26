# standard-site-quarto

A [Quarto](https://quarto.org) extension that embeds [standard.site](https://standard.site) publications and documents into a Quarto website — a **one-way, read-only bridge**. Give it an `at://` URI; at render time the extension fetches the record from the author's Personal Data Server (PDS) and bakes it into static HTML.

No JavaScript, no client-side network requests, no secrets.

## Install

```bash
quarto add agbocsardi/standard-site-quarto
```

Commit the resulting `_extensions/` directory to your project.

## Usage

Embed a single document in full:

````markdown
{{< standard-document uri="at://did:plc:qqcz624yyb7ruo4fxay5k7py/site.standard.document/3mp6kwt3p6lk5" >}}
````

A compact card:

````markdown
{{< standard-document uri="at://did:plc:…/site.standard.document/rkey" mode="card" >}}
````

A publication's recent documents as a feed of cards:

````markdown
{{< standard-publication uri="at://did:plc:…/site.standard.publication/rkey" limit="5" >}}
````

`standard-doc` is an alias for `standard-document`.

### Options

**`{{< standard-document >}}`**

| Option | Default | Description |
|---|---|---|
| `uri` *(required)* | — | `at://…/site.standard.document/<rkey>` |
| `mode` | `full` | `full` inlines the body; `card` shows a compact card |
| `show-cover` | `true` | suppress the cover in `full` mode with `show-cover="false"` |

**`{{< standard-publication >}}`**

| Option | Default | Description |
|---|---|---|
| `uri` *(required)* | — | `at://…/site.standard.publication/<rkey>` |
| `limit` | `10` | max document cards to list |

## How it works

This extension only **reads**. It never authenticates and never writes records — the consumer side of standard.site.

The Bluesky AppView (`public.api.bsky.app`) does not index `site.standard.*` records, so every fetch goes **directly to the author's PDS**, resolved via the [PLC directory](https://plc.directory):

1. Parse `at://` → DID + collection + rkey
2. Resolve DID → PDS endpoint (cached for the render)
3. `com.atproto.repo.getRecord` / `listRecords` / `sync.getBlob` on that PDS

All fetching happens at `quarto render` time. The record and any cover image are written into the pandoc mediabag and baked into the static output. The trade-off is staleness — re-render to refresh.

### About `textContent`

The `content` field is an **open union**: each platform invents its own block types (pckt uses `blog.pckt.content`, others differ), so there is no single format to render. This extension renders `textContent` — the plain-text representation the schema asks every document to provide. Rich native-block rendering is future work.

## Finding a URI

- A document's `at://` URI is in its page's `<link rel="site.standard.document" href="at://…">` head tag.
- A publication's URI is in the domain's `/.well-known/site.standard.publication` file.
- Browse records at [PDSLs](https://pdsls.dev).

## Development

```bash
# quick test against live records
quarto render example.qmd

# the docs site is a Quarto website under docs/
quarto preview docs/
```

`docs/_extensions` is a symlink to the repo-root `_extensions/`, so the docs site renders against the in-tree extension.

## License

MIT
