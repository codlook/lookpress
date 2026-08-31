# LOOK CMS — Design (Phase 0)

Status: **draft for approval.** No code until this is approved. This document makes the
shape decisions; implementation follows.

## What this is

A content management system built on LOOK. Not "WordPress but faster" — it targets
WordPress's five *structural* loads, not its feature list:

| WP's structural load | Our structural answer |
|---|---|
| Every request renders (PHP+MySQL+cache+CDN, invalidation hell) | **Static-first**: publish = generate HTML; request = serve a file |
| Extensions = arbitrary in-process code (the source of most WP hacks) | **Declared capabilities + audit** now; themes **cannot** run code (enforced) |
| Content = a mutable MySQL blob (partial revisions, no audit, painful migration) | **Immutable, versioned content core**; export = plain files |
| Content types = a plugin's job (ACF/CPT-UI, shortcode lock-in) | **Structural content types**: define fields → CRUD + JSON API auto-generated |
| "Don't touch it, it works" (sites rot because updates are risky) | **Atomic publish + real rollback** (pointer move over immutable revisions) |

**Audience (honest):** technical site owners and agencies — *not* non-developers. The editing
surface is Markdown + structured fields. "Content editors" becomes accurate only once theme
customization (color/logo forms) lands; "site builders / non-developers" is deliberately not claimed.

## Claim set — every claim is measured or trivially enforced

```
✓ µs static file serving        (to be MEASURED in Phase 2)
✓ structural content types      (field def → CRUD + API)
✓ plain-file portability         (export = markdown + front-matter)
✓ themes cannot run code         (file-type gate: reject a theme package containing .lk)
✓ declared + audited capabilities (manifest visible, calls logged)
✗ "runtime-enforced sandbox"     → a TARGET, not a claim (needs adversarial testing)
✗ "for non-developers"           → narrowed to technical owners / agencies
```

---

## Pillar ① — Versioned content core (immutable revisions)

**Decision: immutable, append-only revisions + pointers on a stable content row.**
(Not `content_id + rev_no` *or* immutable-append — both: rev_no is the human address,
append-only is the integrity discipline that makes rollback/diff/audit free.)

```
content     id · type · slug · status · current_rev · published_rev · created_at · updated_at
revisions   id · content_id · rev_no · title · body_md · body_html · fields_json
            · author_id · created_at · note        (NEVER updated — only inserted)
```

Rules:
- **Save** → INSERT a new revision; `content.current_rev` → the new row. Nothing is overwritten.
- **Publish** → `content.published_rev = <rev id>`; `status = published`. The published site reads
  `published_rev` only.
- **Rollback** → point `published_rev` at an older revision. One pointer move = real rollback.
- **Diff** → compare two revision rows (title / body / fields).
- **Audit** → each revision carries `author_id`, `created_at`, `note`.
- **Export** → dump the published revision as `slug.md` with YAML front-matter (portable, git-friendly);
  or full history for backup.

Why this beats WP: a WP revision is partial (not all fields, not media) and rollback is unreliable.
Here a revision is the complete **editorial** state (title / body / fields), and the pointer *is*
the source of truth for that.

**Honest boundary — identity is not versioned.** `slug` and `type` live on the `content` row, not in
the revision. So a rollback restores content but **not the URL**: if the slug changed between
revisions, moving `published_rev` back does not bring the old slug back. In v1 we say this plainly —
**changing a slug breaks its old URL.** A `redirects` table (old slug → 301) is **trigger-gated**: it
ships on the first real slug change (WP solves this with `_wp_old_slug`; until then, at least our
label is honest). So the precise claim is: *"a revision is the complete editorial state; identity is
a property of the content, not the revision."*

`body_md` is the source (edited); `body_html` is rendered **at save** (render-on-save, measured 15×
in the reference app) so serving never re-renders.

---

## Pillar ② — Structural content types (types are content, not code)

**Decision: types live in a `content_types` table (admin CRUD), serialized as JSON; `page` and
`post` are seeded built-ins.** Not LOOK assoc in source — that would require a code edit to add a
type (the ACF-plugin trap, inverted). A type is data.

```
content_types   id · slug · label · fields_json
  fields_json = [ { "name":"title", "type":"text",     "required":true },
                  { "name":"body",  "type":"markdown"  },
                  { "name":"cover", "type":"media"      },
                  { "name":"tags",  "type":"relation", "to":"tag", "many":true } ]
```

Field types: `text · textarea · markdown · int · decimal · bool · date · select(choices)
· media(→media) · relation(→another type)`.

The type engine reads a type and auto-generates: the admin create/edit form, server-side
validation, and `GET /api/{type}` (JSON).

**Taxonomy is not a subsystem — it's a `relation` field.** A "category" is just a content type; a
post's categories are a `relation` (many) to it. The old plan's separate taxonomy/1.1 becomes a
*feature* of the type engine, not a slice. Structured field values live in the revision's
`fields_json`, so they are **versioned with the content** (WP stores these in scattered post-meta).

Relation queries ("all posts in this category") are **free in v1** — the full-rebuild walk already
scans every content item, so building a category page is a filter over data we're reading anyway.
If relation *filtering* ever gets hot (large sites, faceted lists on the dynamic side), a
`relation_index` table (content_id ↔ related_id) is **trigger-gated** — it ships when a measured
query says `fields_json` scanning is too slow, not before.

---

## Pillar ③ — Static-first publish (full-rebuild in v1)

**Decision: publish = full rebuild into a fresh directory + atomic swap. Incremental is deferred
until a *measured* trigger.**

```
Publish  → render every published item (pages, posts, list pages, category pages,
           home, sitemap.xml, rss.xml) into build-next/ → atomic swap (mv/symlink) → build/
Request  → nginx (or LOOK static mode) serves build/ — µs, no practical traffic ceiling
Dynamic  → /admin · form POST · search · /preview/{rev} (draft = instant, never static)
```

**Preview is admin-session-gated.** `/preview/{rev}` requires an admin session; the `rev` id is
assumed *guessable*, so the session — not an unguessable URL — is the protection. An unauthenticated
preview URL leaks draft content by id-guessing, a classic CMS hole; the design forbids it here so it
can't be decided ad-hoc later.

**Read-surface invariant (generalizes the above — the whole leak class in one rule).** Every *public*
read surface — the static build, **search**, **`GET /api/{type}`**, and feeds (rss/sitemap) — reads
`published_rev` **only**. Draft / `current_rev` state is reachable **exclusively** through
admin-session surfaces (`/admin`, `/preview`). Feeds and the static build are safe by construction
(they are generated from published content); **search** and the **type API** must carry the
`published_rev` qualifier *explicitly*. Writing it here stops Phase 1's API and Phase 2's search from
each re-deciding it ad-hoc (and leaking drafts by query or by id).

- **Phase 2 measures full-rebuild time at 100 / 1,000 / 10,000 pages.** The incremental trigger
  becomes a *number* ("rebuild > X s"), not a guess. It's plausible 10k pages rebuild in seconds and
  incremental never ships.
- **Golden gate (only if/when incremental is built):** incremental output ≡ full-rebuild output,
  **byte-identical** — a differential guard for invalidation correctness. This is the sibling of the
  engine differential guard, and it makes "our cache is never stale" provable rather than hoped.

Search: start with SQL `LIKE`, **measure** on N posts; adopt FTS5 only if a measured number says so.
(Search reads `published_rev` only — see the read-surface invariant above.)

**Media is not copied into the build.** Uploaded files stay in `UPLOAD_DIR` (outside the web root)
and are served from their own `/media/{name}` route/alias; static pages just reference that URL. The
build directory holds HTML, not a duplicated media tree — so a publish never re-copies gigabytes of
uploads, and the atomic swap stays cheap.

---

## Pillar ④ — Extensions & themes

### Capabilities — declared + audited (no enforcement claim in v1)

```
package manifest:  { "capabilities": ["db.read", "mail.send", "http.out"] }
runtime v1      :  capabilities shown in admin · their use is logged (audit)
                   NO runtime-enforcement claim
enforcement     :  separate R&D turn — call-stack-aware capability masking on builtin
                   dispatch — shipped ONLY after adversarial escape tests pass
                   (builtin-ref leak · file:: to a neighbor's data · metaprogramming)
```

Still ahead of WP (which has no manifest at all). The product is **not** gated on enforcement.

### Themes — presentational only, enforced by a file-type gate

**Decision: a theme package = templates + assets + `theme.json`. Nothing else. `lk theme-install`
REJECTS any theme package that contains a `.lk` file.** Structural, trivial to enforce, and it earns
the claim: **"themes cannot run code — by design."** Theme logic (widgets, dynamic bits) is a
*separate* package that goes through the hook system and declares its capabilities — never the theme.

```json
theme.json {
  "name": "business", "version": "1.0.0", "author": "codlook",
  "supports": ["page", "post"],
  "templates": { "home":"home.html", "page":"page.html", "post":"post.html",
                 "list":"blog.html", "category":"category.html", "404":"notfound.html" },
  "options": [
    { "key":"primary_color", "type":"color",  "default":"#2d6cdf" },
    { "key":"logo",          "type":"media" },
    { "key":"font",          "type":"select", "choices":["system","serif"], "default":"system" }
  ],
  "assets": ["css/style.css", "js/main.js"]
}
```

`options` are edited from the admin (color/logo/font forms) → stored in config → injected into
templates. **This is the non-developer value** — and the day it ships, the audience label can widen
to "content editors." Multiple themes install as packages; `THEME=` (or an admin setting) picks one.

**Type → template resolution.** For content of type `T`, the theme uses `{T}.html` if it exists,
else falls back to `page.html`; **when the fallback is used, the publish log records a NOTE (never
silent).** This is why `theme.json` `supports` is *advisory*, not a hard gate — a theme can still
render a type it never heard of via the `page` fallback, and the build log tells you it happened.
(Without this rule, a type created in the admin — the Phase-1 proof — would have no defined template
and the decision would be made ad-hoc in Phase 2.)

---

## Phases (slice discipline — each with FRICTION.md, each claim measured)

```
Faz 0  repo (codlook/look-cms) + THIS design doc  → your approval gate
Faz 1  ① versioned core + ② type engine; migrate the live cms.codlook.com page/post
       (first real data migration — our own migrate under test; backup + rollback rehearsal FIRST)
Faz 2  ③ static full-rebuild + REBUILD-TIME MEASUREMENT (100/1k/10k) → incremental trigger = a number
Faz 3  multi-theme as packages (presentational-only, .lk-rejection enforced)
────────────────────────  trigger-gated from here  ────────────────────────
capability ENFORCEMENT → R&D turn (real demand + adversarial tests)
multi-user / RBAC / CSRF → when a second author is invited (2.x lock: hardening before invite)
incremental static → when rebuild > X s (the number from Faz 2)
```

## Not building in v1 (same discipline)

```
page builder · comments · multisite · WYSIWYG · plugin marketplace (the package registry is it)
Gutenberg-style blocks (structural content types solve this without a blob)
```

## Risks (honest)

```
Static invalidation graph → biggest technical risk → deferred behind a measured trigger + the byte-identical gate
Capability enforcement    → hot-path core work → its own turn, its own ablation, no rush, honest label until proven
Faz 1 data migration      → on the LIVE cms.codlook.com → backup + rollback rehearsal before the migration
Scope                     → five pillars is large + a maintenance commitment → slice discipline, "done" definitions, FRICTION per phase
```

---

## Open questions for your approval

1. **Name / repo:** `codlook/look-cms` (consistent with the live subdomain)?
2. **Default DB:** SQLite (single file, zero setup; MySQL/Postgres available via DSN) — confirm?
3. **Revision retention:** keep *all* revisions forever, or prune to the last N per content item
   (with published revisions always kept)? Recommendation: keep all in v1 (cheap on SQLite), add a
   prune setting later if a real site's history grows large.
4. **`page` vs `post` as built-in types:** seed both, or start with just `post` (blog) and let `page`
   be created via the type engine as the first proof it works? Recommendation: seed both (they exist
   in the live app and must migrate cleanly), and create a *third* type from the admin in Faz 1 as
   the type-engine proof.
