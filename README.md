# LookPress

**A Look-native web application & content platform.** Small core, static-first, API-first;
measured, not promised. Built on [LOOK](https://github.com/codlook/look).

Not "WordPress but faster," and not a publishing engine — a **platform**: one install can become a
blog, a store, a membership site, or a multilingual corporate site by adding extensions, **without
touching the core.** WordPress's real power was never speed; it was that transformation. LookPress
matches it and targets WordPress's six *structural* loads — not its feature list:

| WordPress's structural load | LookPress's structural answer |
|---|---|
| Every request renders (PHP + MySQL + cache + CDN, invalidation hell) | **Static-first** — publish generates HTML; dynamic islands stay live |
| Extensions run arbitrary in-process code (the source of most WP hacks) | Built-in app services + **declared, audited** extension manifests; hard enforcement is the roadmap flagship (honest label until proven) |
| Content is a mutable blob (partial revisions, no audit, painful migration) | **Immutable, versioned content core**; export is plain Markdown files |
| Content types need a plugin (ACF / CPT-UI, shortcode lock-in) | **Define fields → CRUD + a JSON API, auto-generated** (taxonomy is a relation field) |
| Updates are risky ("don't touch it, it works") | **Atomic publish + real rollback** (a pointer move over immutable revisions) |
| Multilingual = an expensive, fragile plugin (WPML/Polylang) | **Structural translation** — a translation group over the versioned core |

**The test that defines "platform":** a commerce extension can be built on top — catalog from the
type engine, cart/checkout as dynamic islands, payment via the `paytr`/`iyzico` packages, order mail
via `jobs::` — **without touching the core.** If that's buildable, it's a platform; if not, it's a
blog engine, however fast. See [PROJECT.md](PROJECT.md).

**Audience:** technical site owners and agencies — the editing surface is Markdown + structured
fields. (Not "non-developers"; that label is earned only once theme customization forms ship.)

## Why LOOK

- **One binary**, minimal external runtime dependencies. No PHP+MySQL+Redis+CDN stack to operate.
- **Measured, not promised** — content pages render at ~150 µs (render-on-save), the runtime uses
  megabytes of RAM, and a slow mail gateway can't take the site down (`jobs::` moves outgoing I/O
  off the request path).
- **Honest claims** — every number is measured; every security claim is either structurally enforced
  or labeled a target, never asserted without proof.

## Quick start

The whole platform runs in Docker on the published LOOK runtime — no build toolchain needed:

```bash
git clone https://github.com/codlook/lookpress && cd lookpress
docker compose up            # http://localhost:8080
```

That gives you a populated demo: a shop with products (tr + en), a blog, pages, and a working admin
at **/admin** (user `admin`, password from `ADMIN_PASSWORD` — the compose dev default is
`lookpress-dev`; **set your own** in a `.env` for anything real). `docker compose down` stops it and
keeps the data; `down -v` resets to the clean demo.

SQLite by default (no DB server for dev). Point `DB_DSN` at `mysql://…` / `postgres://…` for a real
database.

## Project layout

Application code, routes and views are separated — no monolith, and every view lives under one roof:

```
app.lk                 Entry point — composition only: loads modules in order.
config/                Configuration in one place
  config.lk              installed themes/skins, order statuses, upload types, branding
src/                   Application code (one responsibility per module)
  core.lk                framework: DB, cached settings, view rendering, SEO, auth gates
  types.lk               the type engine: field inputs, validation, versioned-core write
  render.lk              public presentation: pages, listings, home/blog, URL resolvers
  cart.lk                commerce helpers: cart + coupon maths
routes/                HTTP routes (thin controllers)
  public.lk              home, blog, media, search, sitemap/robots/feed, forms
  commerce.lk            cart + checkout
  admin.lk               /admin/* + JSON API + preview (auth-gated)
  dispatch.lk            dynamic per-type catch-alls — loaded LAST (first-match wins)
views/                 All presentation, one place
  admin/                 admin UI shell + pages (its own theme, not a site theme)
  themes/                site themes; the active one is chosen in admin settings
    default/               the built-in theme (every template + the layout)
    aurora/                an alternate theme (overrides only what it changes)
lib/                   reusable libraries (markdown, migrations)
setup.lk · setup_v2.lk   idempotent schema + seed (run by the container entrypoint)
test/smoke.sh          end-to-end checks, run in CI on every push
```

Routing is **first-match by registration order**, and `use "file"` runs a module's `route()` calls
inline where it's loaded — so the only ordering rule is that `dispatch.lk` loads last. A **theme** is
a directory of templates; a **skin** is a colour palette. The admin UI is deliberately separate from
site themes, so a theme ships only public views.

## What's built

On the versioned content core + type engine (define fields → CRUD + `/api/{type}` + admin, no
per-type code), the following work end to end:

- **Content** — pages, a paginated blog, generic type listings, render-on-save Markdown, a media
  library, **revision history + one-click rollback** (a pointer move over immutable revisions).
- **Commerce** — a product type, a catalog grid, product pages, a session cart, checkout with
  shipping details, persisted orders, and admin order + status management. (Payment is a Phase-6
  `paytr`/`iyzico` package — checkout is TEST-MODE.)
- **Multilingual** — URL-based (`/en/…`), the same slug per language over the versioned core; author
  each language from the admin. A TR/EN switcher in the header.
- **SEO** — per-page meta + Open Graph + Product JSON-LD, plus `sitemap.xml`, `robots.txt`, an RSS
  `/feed`, and site search.
- **Forms** — a contact form with a honeypot; submissions reviewed in the admin.
- **Users & roles (RBAC)** — real users (PBKDF2), an `admin` / `editor` split, admin-only sections.
- **Settings & theming** — configurable site title/tagline/currency; **themes** (a template set,
  per-template override + fallback to `default`) and **skins** (colour palettes) chosen in the admin.
  The **admin UI is its own thing**, independent of the site theme — a theme ships only public views.

## Admin, theming, testing

- **Admin** lives under `/admin` with its own shell (`views/admin/`), separate from site themes.
- **Themes** are directories under `views/themes/`. `view()` renders `views/themes/{active}/{tpl}` and
  falls back to `views/themes/default/{tpl}` per template, so a theme overrides only what it wants (see
  `views/themes/aurora` for a different homepage). Full per-theme chrome is limited by the template
  engine's literal `{#extends}`; per-template override is what's clean today.
- **Tests** — `bash test/smoke.sh` runs 33 end-to-end checks (public, multilingual, SEO, commerce,
  admin/RBAC) against a running instance; CI (`.github/workflows/smoke.yml`) runs it on every push.

## Status

**Working platform, built slice by slice** — each feature above is verified end to end and locked by
the smoke suite. Live reference deployment: **https://test.codlook.com** (Plesk). The design lives in
**[PROJECT.md](PROJECT.md)**, the forward plan in **[ROADMAP.md](ROADMAP.md)** (positioning +
phased engineering), the V2 architecture contract in
**[docs/platform-plan.md](docs/platform-plan.md)** (module/theme/domain/payment contracts +
LOOK constraints), and Plesk deployment in **[docs/plesk-deploy.md](docs/plesk-deploy.md)**.
Remaining before a real shop can take money: payment integration, transactional email, customer
accounts (see the roadmap's Phase A).

## Not building (v1)

Page builder · comments · multisite · WYSIWYG · a plugin marketplace (the LOOK **package registry**
is it) · Gutenberg-style blocks (structural content types replace them without a blob).

## License

Apache License 2.0 — see [LICENSE](LICENSE). Consistent with the rest of the LOOK ecosystem.
