# CMS reference app — friction log (Slice 1: pages + admin)

Building a minimal CMS — one content type (pages), Markdown body, a catch-all
`/{slug}` public route, and a password-gated admin — from the public docs, logging
every place a first user would stall. Severity: 🟢 minor · 🟡 real · 🔴 blocker.

| # | Where | What happened | Sev | Fix / workaround |
|---|-------|---------------|-----|------------------|
| 1 | time/date | Reached for `time::now()` for an `updated_at` timestamp → **`Module 'time' not loaded`**. The module is **`date`**, and `date::now()` returns a formatted *string*, not an int. | 🟢 | Use **`date::timestamp()`** for a unix int. A user expecting `time::` stumbles — the date/time surface is all under `date::` (`date::now`, `date::timestamp`, `date::format`, …). |
| 2 | routing | **Route match is registration order, first-match-wins.** The catch-all `/{slug}` will happily match `/admin` if it is registered *first* — silently shadowing the whole admin. | 🟡 | Register the catch-all **LAST**. It works, but it's an implicit contract: a user who puts `/{slug}` at the top loses `/admin` with no error. **Core candidate (fail-loud, next core turn):** at route registration, warn if a new route is shadowed by an already-registered catch-all — `startup WARN "route /admin unreachable: shadowed by /{slug}"`, a sibling of the `session Secure` warning. |
| 3 | template `<select>` | No confirmed support for `==` expressions inside `{#if}`, so pre-selecting the current `status` in a `<select>` isn't obviously doable in the template alone. | 🟢 | **Compute the view flags in code** (`draft_sel`/`pub_sel` strings) and interpolate them — keep templates dumb. A clean pattern regardless; templates stay presentational. |
| 4 | escape / XSS | Needed to know whether Markdown-rendered HTML is safe to emit and whether `{$var}` escapes. **Answer (verified):** `{$var}` **auto-escapes** (`<b>` → `&lt;b&gt;`), `{!$var}` is the explicit **raw** opt-out, and `markdown_to_html` **pre-escapes raw HTML in the source** (a `<script>` in the body renders inert as `&lt;script&gt;`). The *second* Markdown vector — `[link](javascript:…)` — is **best-effort** filtered by the module's `descheme`, not proven-exhaustive. | 🟢 | Secure-by-default for the raw-HTML vector; URL-scheme filtering is best-effort. This slice is **single-author** (owner authors their own pages → self-XSS is meaningless), so sufficient. **When RBAC lands (low-priv author → admin's browser), this becomes security-critical → add the `sanitize` module.** Label precisely: "raw HTML escaped; URL schemes best-effort," not "cannot inject script." |

## Slice 2: media library (upload / list / embed / serve / delete)

| # | Where | What happened | Sev | Fix / workaround |
|---|-------|---------------|-----|------------------|
| 5 | `request::file` | **The original client filename was dropped.** `request::file()` returned only `path` / `mime` / `size` / `sha256` — the multipart parser extracted the `Content-Disposition` `filename` but discarded it. A media library can't show "logo.png"; files are named by sha256. This is the slice's real measurement — deeper than the A/B fork below: the name isn't recoverable at any layer. | 🔴 → ✅ | **Fixed in core** (`ce4aa35`): `request::file()` now returns `filename` (basename, control-chars stripped, untrusted → escape on display). The return-value **docs were also stale** (`$file["name"]`/`temp_path` — neither existed) → corrected (`aa7fad7`). |
| 6 | `file::mkdir` | Expected to need it to create the upload dir — **it doesn't exist, and isn't needed.** `file::store($file, "subdir")` creates the dir itself, dedupes by sha256, blocks path-traversal subdirs, and refuses to write under the web root. | 🟢 | The predicted `file::mkdir` trigger was **pre-empted** by a purpose-built API. Read what exists before adding. |
| 7 | `request::file` reject | A disallowed MIME / oversize file makes `request::file()` **throw**, while a *missing* file returns **null** — an asymmetric contract. An upload of a `.txt` 500'd until wrapped. | 🟢 | `try/catch` around `request::file()` (the docs example does this). Documented, but the null-vs-throw split is easy to miss if you only saw "returns null". |
| 8 | serving | No `response::file` / binary response exists. Serving an image = `file::read` (bytes) + `response::text` + `Content-Type` **after** the body. | 🟢 | **Works — bytes round-trip byte-identical** (LOOK strings are binary-safe; a 67-byte PNG served intact as `image/png`). A `response::file(path, mime)` helper would be nicer ergonomics, but nothing is missing. |
| 9 | `UPLOAD_URL` | `file::store`'s returned `url` is `UPLOAD_URL` + subdir — set `UPLOAD_URL=/media` with subdir `"media"` and you get `/media/media/…` (**doubled**). | 🟢 | Build the public URL yourself (`/media/` + `name`) and serve via your own route. API-ergonomics candidate for a later core/docs pass. |

**A/B fork result (the slice's design measurement):** **B (a `media` table) won.** `file::list` returns
`{name, dir, size}` with **no mtime**, and files are sha256-named — so a "newest-first, show the
original name" library is impossible on `file::list` alone. The table carries `original` +
`created_at`. So `file::list` is genuinely useful (directory discovery) but **not** the right tool
for a media library — and it still awaits its first real consumer.

**Core candidate logged:** at route registration, warn when a new route is shadowed by an
already-registered catch-all (Slice 1 #2) — a fail-loud sibling of the `session Secure` warning.

**Guard-class boundary (worth knowing):** the `filename` drift (#5) was a **return-shape** drift —
`request::file` *existed* and was *documented*, but the documented **key** (`$file["name"]`) was a
ghost. `docs_conformance` checks that every documented `mod::fn` *exists*, not that its return shape
matches — so this drift passed every existing net, and the docs example survived only because it
never touched the ghost key. The only real net for return-shape drift is "the example must run **and**
touch every documented key." A heavy rule — noted here as a limit, not built.

## Slice 3: blog (posts + pagination)

**A clean slice — the finding is the absence of friction.** Pagination was the whole point (it's the
one thing pages didn't exercise), and it just worked: `LIMIT ? OFFSET ?` with bound params, `SELECT
COUNT(*) AS n` for the total, `request::get("page") ?? "1"` + `type::to_int` + a `< 1` clamp for the
page number, and `{#if $has_prev}`/`{#if $has_next}` for the pager links. Verified: page 1 shows the
5 newest, page 2 the remaining 2, **page 3 (past the end) renders a clean empty list at HTTP 200**
(not an error), and `?page=abc` / `?page=-5` clamp to page 1. Route priority held again (`/blog` and
`/blog/{slug}` registered before `/{slug}`), and the admin CRUD loop was a near-verbatim reuse of the
pages loop. Nothing new tripped — a language handling its most common web pattern without ceremony.

*(Deliberately deferred, to be named by real use: post excerpts on the index, taxonomy
categories/tags, and an RSS feed — the last will re-raise the "no `xml::` module, build the string
yourself" question when a slice names it.)*

## Performance: per-request Markdown was the one real cost (→ render-on-save)

Once the app worked, one honest question: how fast is a real content page? Measured (single
keep-alive connection, 2 CPUs, app on a local FS — **not** a bind mount, which adds ~9 ms of
per-request file I/O and would drown the signal):

| Route | before | after | |
|-------|--------|-------|--|
| `/blog` (DB + template, no Markdown) | 199 µs | 183 µs | the DB+template floor is already fast |
| `/blog/post-5` (DB + Markdown) | 932 µs | **135 µs** | 7× |
| `/welcome` (DB + Markdown, larger body) | 2274 µs | **147 µs** | 15× |

The cost was **re-rendering Markdown on every request** — the `markdown` module is pure LOOK doing
~10 `regex_replace` passes over the body, and a served page paid it every time. The fix is the
classic CMS design, **render-on-save**: convert Markdown → HTML once when the page is saved, store
it in a `body_html` column, and serve that. Content pages then render at the ~150 µs template floor.
This is why the app keeps *both* columns — `body` (the Markdown source the admin edits) and
`body_html` (served). Note this made a **full-response `route_cache` unnecessary**: at ~150 µs there
is little left to cache, and render-on-save has no cache-invalidation problem (the HTML is rewritten
on every edit). Measurement fired the "do we need caching?" question and answered *no — move the
work off the request path instead.* *(Scope: this verdict is for **this** CMS's shape — mostly
single-row pages. A heavy, multi-query composition page (a dashboard, a faceted listing) could
re-open the `route_cache` question; the lever stays on the shelf with that trigger.)*

## What worked cleanly (the baseline)

- **migrate** — `pk` / `string(N) unique` / **`text`** / `int default=…` compiled to correct
  SQLite DDL; `fresh` drops + re-migrates + seeds idempotently.
- **Catch-all routing** — `/{slug}` + `request::param("slug")` cleanly serves DB-backed pages;
  registration-order priority (once you know it) makes `/admin` and `/{slug}` coexist.
- **Auth** — `session::start` / `regenerate` (on login) / `set` / `get` / `destroy`, gated with
  `crypto::constant_compare` against `env("ADMIN_PASSWORD")`. Timing-safe, no plaintext `==`.
- **Admin CRUD** — `request::post`, `response::redirect` / `status`, the create→edit→delete→
  draft↔publish loop — all clean, **0 VM fallback** on the published binary.
- **Markdown** — the vendored `markdown` module (`markdown_to_html`) rendered headings, bold,
  lists, links out of the box, with the XSS hardening above.
- **Templates** — `{#extends}` / `{#block}` / `{#each … as …}` / `{#if}` / `{$x.field}` dot-access,
  one theme dir switched by `THEME=` — same mechanism as the QR-menu app, reused with zero changes.

## Environment note (not a LOOK finding)

Under the Windows Docker **bind mount**, a *relative* `sqlite://cms.db` occasionally read "no such
table" because the server opened the DB before the bind-mount flushed `setup.lk`'s writes — a
9p/virtiofs write-latency artifact, not a LOOK bug (a container-local or real-disk path works, and
the QR-menu app uses a relative SQLite path in production). Use an absolute `DB_DSN` when running
over a Windows bind mount.

## Deliberately out of scope (later slices)

Media/uploads (`file::mkdir` trigger lands here), taxonomy (categories/tags), multiple content
types, RBAC (`rbac` module), hooks/plugins, and full-response `route_cache` — each waits for this
app's real use to *name* it, rather than being designed before it's needed.
