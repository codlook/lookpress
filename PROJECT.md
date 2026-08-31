# LOOK CMS — Design (Platform)

Status: **draft for approval (platform revision).** This supersedes the publishing-engine draft.
No code beyond the shared foundation (Phases 1–2) until this is approved.

## What this is — a site platform, not a publishing engine

WordPress's real power is not speed. It is that **one install can become anything over time** — a
blog grows a store (WooCommerce), a membership area, a multilingual corporate site, a booking
system — **without a developer rebuilding it.** A fast "content → theme → static output" engine
(Ghost/Kirby class) is *not* that. This document designs the platform: a core that hosts
transformation, and solves the structural loads underneath it.

**Audience:** technical site owners and agencies (an agency brings dozens of sites behind one
install — exactly the WP-fatigue market).

## The acceptance test — the commerce test

"Advanced" is not abstract. The platform is real **if and only if**:

> A commerce extension can be built on top, **without touching the core.**

Catalog = the type engine (②). Cart/checkout = dynamic islands (③). Payment = the `paytr` / `iyzico`
packages (their first named user). Order mail = `jobs::`. If that is buildable as an *extension*,
this is a platform. If it requires core surgery, it is a blog engine — however fast. This is the
**Phase 6 flagship proof**, and it is the definition of "done" for the platform thesis.

**The test carries its own minimum "done" (so it can't slip):**
```
catalog = the type engine  ·  cart/checkout = a dynamic island  ·  payment = paytr/iyzico in TEST MODE
order record + jobs:: mail  ·  built as a FIRST-PARTY extension
```
The test proves **the extension API carries the load** (routes, admin mount, type registration, hooks
for order lifecycle) — *not* third-party security (that is the flagship enforcement work, per §④).
**Live payment day** (real credentials, real charge) is the bulk-creds trigger — *your* day — and is
**not** part of the acceptance test; TEST-MODE payment is sufficient to prove the platform thesis.

## WordPress's six structural loads — and our structural answers

| # | WP's structural load | Our structural answer |
|---|---|---|
| 1 | Every request renders (PHP+MySQL+cache+CDN, invalidation hell) | **Static-first** — publish generates HTML; dynamic islands stay live |
| 2 | Extensions = arbitrary in-process code (most WP hacks) | **Built-in app services** (fewer third-party plugins) + **declared+audited** extension manifests; hard enforcement is the roadmap flagship (see §Honesty) |
| 3 | Content = a mutable blob (partial revisions, painful migration) | **Immutable, versioned content core**; export = plain files |
| 4 | Content types = a plugin's job (ACF/CPT-UI) | **Structural types**: define fields → CRUD + JSON API auto-generated |
| 5 | Updates are risky ("don't touch it, it works") | **Atomic publish + real rollback** (pointer over immutable revisions) |
| 6 | **Multilingual = an expensive, fragile plugin patch (WPML/Polylang)** | **Structural translation**: a translation group over the versioned core — the most concrete "solve the real problem" case, and a direct fit for the TR market (half of TR SMB sites want TR+EN) |

## Seven pillars

**①–③ are the content subsystem** (unchanged from the engine draft; they are the right foundation
for a platform too — no work is lost):

- **① Versioned content core** — `content` (identity: slug/type/status/pointers) + `revisions`
  (immutable, append-only: title/body_md/body_html/fields_json/author/note). Rollback = a pointer
  move; diff = two rows; export = markdown + front-matter. *Identity (slug/type) is not versioned —
  a slug change breaks the old URL until a trigger-gated `redirects` (301) table ships.*
  **⑥-ready from day one (a two-line decision taken NOW to avoid a live-data migration later):** the
  `content` row carries a `lang` column (default `tr`), and a slug is unique per **`(lang, slug)`**,
  not globally. Phase 5's multilingual (⑥) then adds only a `translation_group` link — no schema
  migration on live data. (Design-first: the alternative is an *accepted, documented* future
  migration; we chose the two lines. This decision is taken in the Phase-1 Step-2 schema, not ad-hoc.)
- **② Structural content types** — types live in a `content_types` table (admin CRUD, JSON), not in
  code. Field types incl. `relation` → **taxonomy is a relation field, not a subsystem.** Field
  values live in the revision's `fields_json` (versioned). Relation-index table is trigger-gated.
- **③ Static-first publish** — publish = full rebuild → atomic swap (incremental deferred behind a
  measured rebuild-time trigger; byte-identical golden gate when it ships). **Dynamic islands are
  first-class here, not an afterthought** — cart, checkout, a membership area, forms, search, and
  admin are served live; everything else is static. Media is served from `/media` (never copied into
  the build). **Read-surface invariant:** every public read surface (static build, search,
  `/api/{type}`, feeds) reads `published_rev` only; drafts are reachable only through admin-session
  surfaces (`/admin`, `/preview`).
  **Output-path collision aborts the build (loudly).** Because `UNIQUE(lang,type,slug)` lets two
  types share a slug, uniqueness of the *rendered URL* is now a **build-time** property — the types'
  `url_pattern`s must not collide. If two content items would render to the same output path, the
  build **aborts and names both slugs**, never silently letting the last writer win. (Design-first
  sibling of the golden gate: a correctness claim carries its enforcement point — here, the point is
  the build step, and the moment `UNIQUE(lang,type,slug)` moved URL-uniqueness out of the DB.)

**④–⑦ are what make it a platform** (new, first-class — not deferred):

- **④ Extension platform** — the transformation layer. An extension is a package that can:
  register **hooks** (content lifecycle `on_save`/`on_publish`, `before_render`, admin events),
  register **routes** (its own public + admin URLs), **mount admin pages**, register **content
  types programmatically**, and read/write its own **settings**. It ships a **capability manifest**
  (`{"capabilities": ["db.read","mail.send","http.out"]}`).
  - **Trust model (honest — the core of the platform's security thesis):** *first-party* extensions
    (commerce, forms — the ones we write) are trusted. *Third-party* extensions carry a
    declared+audited manifest, and **until hard enforcement ships, a third-party extension has the
    same trust model as a WordPress plugin — "install at your own risk," visible manifest, logged
    calls.** We do **not** claim "extensions cannot exceed their manifest" until that is
    runtime-enforced *and adversarially tested* (call-stack-aware capability masking on builtin
    dispatch; escape surface: builtin-ref leak, `file::` to a neighbor's data, metaprogramming).
    Hard enforcement is the **roadmap flagship** — the one sentence WP structurally cannot say — and
    it is claimed only when proven, never gated on for the product to ship.
  - **This trust layer is visible in the admin:** each installed extension shows a **first-party /
    third-party badge** and its declared capabilities. Cheap, and consistent with the honest label —
    the site owner sees the trust boundary, not a false "all safe" impression.
  - v1 differentiator without enforcement: (a) built-in app services (⑤) mean far fewer third-party
    extensions are needed, and (b) a clean manifest + audit trail is already ahead of WP (no manifest
    at all).

- **⑤ Application services (built-in, not plugins)** — the things that are plugin-hell in WP,
  provided by the core so a site owner never installs a third-party plugin for them:
  users + roles + auth (PBKDF2, reset via `mail::`+`jobs::`, login rate-limit), **scheduled publish**
  (`timer::`+`jobs::` already exist — its absence is exactly what made the plan feel "simple"),
  **webhooks**, a **write API + tokens** (headless-friendly), and a **form engine**
  (contact/lead forms → `jobs::` mail, honeypot + rate-limit).

- **⑥ Multilingual — structural** — translation is a natural property of the versioned core: a
  `translation_group` links a content item's language variants; each variant is normal versioned
  content. Language routing (`/en/...` or a per-domain map), a language switcher, and per-language
  publish state. No WPML-class plugin, no serialized-URL surgery.

- **⑦ Admin = product (scoped honestly)** — a media library, a menu manager, and a real editor
  (Markdown-backed but with a media picker and live preview) — this is where the label can widen to
  "content editors." **Engineering caveat baked in:** this is the largest and least
  LOOK-differentiated work (frontend UX, not a language advantage; WP's admin is millions of lines).
  So the stance is **"good-enough admin + API-first,"** not WP-admin parity. The write API (⑤) makes
  the admin *one client, not the only one* — an agency can build a custom admin against the API.

## Sequencing invariant — security before extensibility

Users/RBAC/CSRF (⑤) and the extension API (④) **must** land before any third-party or commerce
extension. You cannot open a platform to extensions before the multi-user security model exists.
This is the reference-app's "harden before a second author" lock, scaled to the platform.

## Phases (slice discipline — each with FRICTION.md, each claim measured)

```
Faz 0  repo + this design doc                                   ✓ (approved; being revised to platform)
Faz 1  ① versioned core + ② type engine                         → shared foundation (both products)
       migrate live cms.codlook.com (backup + rollback rehearsal FIRST — DONE, proven by output)
       migration re-renders body_html from body_md + DIFF REPORT (golden gate, migration version)
Faz 2  ③ static full-rebuild + REBUILD-TIME MEASUREMENT (100/1k/10k → incremental trigger = a number)
Faz 3  ④ extension platform — hooks · route/type registration · admin mount · settings · capability manifest
Faz 4  ⑤ app services — users/RBAC/CSRF · scheduled publish · webhooks · write API + tokens · form engine
       (security lands here — before any extension is third-party or commerce)
Faz 5  ⑥ multilingual (structural) + ⑦ admin UX (media library · menu manager · editor)
Faz 6  🏁 COMMERCE EXTENSION — the acceptance test. Catalog=②, cart/checkout=dynamic island,
       payment=paytr/iyzico packages, order mail=jobs::. Built as an EXTENSION, core untouched.
       → the paytr/iyzico/netgsm live-test day is finally triggered (your credentials)
────────────────────────  trigger-gated beyond v1  ────────────────────────
capability ENFORCEMENT (the flagship) → its own R&D turn, adversarial escape tests, honest label until proven
incremental static → when measured rebuild > X s
```

## Honesty line (unchanged, and now load-bearing)

```
✓ µs static serving (measured next)          ✓ structural content types
✓ plain-file portability                     ✓ themes cannot run code (.lk install gate)
✓ structural multilingual                    ✓ built-in app services (fewer third-party plugins)
✓ declared + audited extension manifests     (visible + logged — already ahead of WP)
✗ "extensions cannot exceed their manifest"  → the flagship TARGET; third-party trust = WP-like until proven
✗ "runtime sandbox"                          → target, not claim (now the platform's security thesis)
✗ "WP-admin parity"                          → not chased; good-enough admin + API-first
✗ "for non-developers"                       → technical owners / agencies; "content editors" once ⑦ ships
```

**Cost, stated plainly:** this is a **6–12+ month platform arc with a maintenance commitment**
(security patches, WP-migration tooling, support). That is what "a WordPress alternative" signs up
for; a small plan would not have avoided it, only hidden it.

## Not building even as a platform (v1)

Page builder / Gutenberg blocks (structural types replace them) · a plugin *marketplace* (the LOOK
package registry is it) · comments in core (a first-party extension when demanded) · multisite ·
WYSIWYG beyond the Markdown-backed editor.

## Open questions for approval

1. Name / repo: `codlook/look-cms` — already created. Confirm the platform re-scope replaces the
   engine PROJECT.md in it.
2. Default DB: SQLite (single file; MySQL/Postgres via DSN) — still correct for a platform, or
   default to MySQL for the multi-user/commerce load? Recommendation: **SQLite default, MySQL a
   documented one-flag switch** — measure before assuming a platform needs a server DB.
   **Deploy note (from this project's own measurement — the `jobs::` init-race investigation):**
   SQLite WAL requires a real filesystem; on **overlayfs (every default Docker container) WAL is
   unavailable** and the DB falls back to rollback-journal, where **concurrent writes (cart, order —
   exactly the commerce load) can deadlock.** So: **SQLite on Docker needs a mounted volume**, and
   the deploy docs must say so — without this line, the first Dockerized commerce user meets a lock.
3. Admin scope: confirm **"good-enough + API-first,"** not WP-admin parity, as the ⑦ ceiling.
4. Is the **commerce test** (Phase 6) accepted as the platform's definition of done?
