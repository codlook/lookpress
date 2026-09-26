# LookPress CMS — Product Spec & Backlog (authoritative)

This is the single source of truth for what LookPress is and what is left to
build. Every slice is checked against this document; nothing ships outside it.

## What LookPress is

A **universal, module-driven content management system written in pure LOOK**.
One install serves any business: a hotel, a construction firm, a news/media
site, a corporate site, an online shop — because every one of those is the same
thing to LookPress: a set of **modules** managed from one admin. It competes
with the WordPress / Laravel / Django class of tools for people who build
websites; it is a product, not a framework SDK. The LOOK language core is never
modified — LookPress is 100% product layer, the way a PHP product sits on PHP.

## The spine: everything is a Module

A **Module** = a content type + its configuration. Defining one gives you, with
zero code: an admin section (list with columns/filters/search/pagination, a
form built from the field definitions, revisions + rollback, scheduling), a JSON
read API, and (optionally) public URLs rendered by the theme.

`content_types` row:

| column | meaning |
|---|---|
| `slug`, `label`, `url_pattern` | identity + public URL (`/{slug}` pattern; empty = no public page) |
| `fields_json` | ordered field definitions `[{name,type,required,…}]` |
| `config_json` | module config, see below |

`config_json` (all keys optional, sensible defaults):

```json
{
  "group":   "icerik",            // admin sidebar group key (see Admin IA)
  "icon":    "📰",
  "singular": "Haber", "plural": "Haberler",
  "list_columns": ["title","status","updated_at"],  // field names or title/status/updated_at/lang
  "filters": ["status","category"],                 // field names filterable in the list
  "order":   10,                                    // sort inside its group
  "public":  true                                   // has public pages/listing
}
```

**Field types** (the form builds itself from these): text, textarea, markdown,
**blocks** (visual block content), int, decimal, number(min/max), bool, date,
select, image, **gallery** (multi-image), relation (to another module),
category (commerce), url, email, tel, color, **repeater** (a list of sub-rows —
the basis of variants/attributes). Extensions can add types via `xp_field_input`.

**Route rule (hard).** Modules ride the *generic* routes
(`/admin/type/{type}`, `/{a}`, `/{a}/{b}`, `/{a}/{b}/{c}`, `/api/{type}`) — adding
100 modules adds **zero** routes. The LOOK VM has a ~70-route budget per app
(we are at 65); a bespoke route is a scarce resource that needs an explicit
decision. Prefer a `{action}` handler over N routes.

**Extension seam.** Anything beyond the core rides `xp_*` hooks (function
override, last definition wins) declared in `src/hooks.lk`; extensions never
edit a `src/` file. Commerce is the reference extension.

## Admin information architecture

The sidebar is generated from module config — groups are fixed keys, their
contents are whatever modules declare them:

| group key | Turkish label | contains |
|---|---|---|
| `kurumsal` | Kurumsal | Sayfalar, Slider, Sabit Alanlar |
| `icerik` | İçerik Yönetimleri | Haberler, Duyurular, Galeri, Videolar, Projeler, Etkinlikler, … (any module) |
| `iletisim` | İletişim | İletişim formu, İş Başvuruları, Destek Biletleri (forms + submissions) |
| `ecommerce` | E-Ticaret | Ürünler, Kategoriler, Markalar, Varyantlar/Özellikler (on product), Siparişler, Kuponlar |
| `ayarlar` | Ayarlar | Genel, Tema, Dil, SEO, **Modül Yönetimi** (define/edit modules) |
| `kullanici` | Kullanıcı Yönetimi | Adminler, Üyeler, Roller, Yetkiler |

The admin UI language is Turkish; runtime error strings, docs and commits are
English.

## Presentation: components, not "classic themes"

Pages are composed from **blocks/components** (heading, paragraph, image,
gallery, button, quote, list, divider, **slider**, **columns**, **cards/listing**
of a module, **form** embed, **hero**). A theme provides the component
renderers + layout + design tokens (skins). Themes are switchable; a theme can
add components. The markdown body remains available for simple posts.

## Security baseline (a real CMS ships with these)

- Auth: PBKDF2 passwords, RBAC roles/permissions, fail-loud on a missing admin
  password. ✅
- Output escaping by default; block/field values are always escaped. ✅
- **CSRF tokens on every state-changing POST** (admin + public forms). ⬜
- **Login rate limiting** (per IP/user, sliding window). ⬜
- **Security headers**: CSP, X-Frame-Options, X-Content-Type-Options, HSTS
  behind TLS, Referrer-Policy. ⬜
- Upload validation (type/size/name), secure cookies behind TLS (✅ toggle).
- Members (public accounts) are a separate table from admin users. ⬜

---

## Backlog — every gap between today and the spec

Legend: ✅ done · 🟡 partial · ⬜ missing. Grouped by wave; a wave ships together,
verified on a fresh volume (`/en` canary 200, route count ≤ 70, 0 VM fallback).

### Wave 1 — spine, admin IA, security, commerce depth, members ✅ (shipped 2026-09-26, 68/70 routes)
- ✅ **Module config** (`config_json`) + defaults; Modül Yönetimi create/edit (edit folded into the create POST — zero routes).
- ✅ **Dynamic list**: per-module columns + filters (`?f_<field>=`) from config; search/pagination kept.
- ✅ **Dynamic sidebar** grouped per the Admin IA table; extension nav merged into E-Ticaret.
- ✅ **Module templates seeded**: Sayfalar, Slider (public:false), Haberler, Duyurular, Galeri, Videolar, Projeler, Etkinlikler.
- ✅ **gallery** + **repeater** field types (admin UI + validation + public render).
- ✅ **CSRF** (admin auto-inject + public forms + extension forms), **login rate-limit** (5/10 min → 429), **security headers** (CSP/nosniff/X-Frame/Referrer, HSTS behind TLS).
- ✅ **Commerce depth**: Markalar (module + relation), Özellikler (attributes), Varyantlar (variants with price/stock, storefront select, cart/checkout stock handling).
- ✅ **Üyeler**: `/hesap/{action}` GET+POST + `/admin/uyeler` (3 routes). Deactivation toggle → Wave 2.
- Known debt: the `xp_*` seam is single-override (commerce holds xp_migrate/xp_admin_nav) — members uses lazy `CREATE TABLE IF NOT EXISTS` and a sidebar link from the spine; a multi-extension hook chain is a future core-of-LookPress decision. Route budget: **68/70** — Wave 2+ must be route-free.

### Wave 2 — communication, settings, components ✅ (shipped 2026-09-26, 69/70 routes)
- ✅ **İletişim modülü**: submission status workflow (açık/işlemde/kapalı) + timestamped notes + delete on one route (`POST /admin/form/{key}`), status filters/counts, CSV export (BOM, RFC4180, formula-injection guard); demo forms iletisim / is-basvuru.
- ✅ **Ayarlar**: sectioned (Genel / SEO / Tema / Dil / Sabit Alanlar) on the existing route; the theme prints them via `{$g.*}` (announcement bar, footer text/links/social/contact, og:image default, analytics head snippet) and `/robots.txt` appends `robots_extra`.
- ✅ **Components**: hero, slider (manual or module), columns (nested, depth ≤ 3), module listing, form embed, map (Google embed only), video (YouTube-nocookie/Vimeo), html (trusted admin) — editor cards + theme CSS + `docs/theme-components.md`.
- ✅ **Dashboard**: module counters per group, İletişim / E-Ticaret / Üyeler panels, system summary, quick actions.
- ✅ **Backups** (pulled from Wave 3): `scripts/backup.sh` / `restore.sh` (docker or Plesk; SQLite online backup via sidecar, MySQL/Postgres dumps), `docs/ops-backup.md`.

### ⚠️ Core blocker found in Wave 2 — the LOOK 1.0 bytecode VM miscompiles LookPress at this size
With one top-level compilation unit (~69 routes + the Wave 2 modules) the VM does not
drop routes anymore — it **miscompiles**: some handlers return an empty `200
application/json` body (`/{a}`, `/admin/forms`, `/admin/form/{key}`) and others throw
bogus `db: connection not found / invalid connection handle` and only survive via the
interpreter fallback. The same code is fully correct under the tree-walk interpreter.
**Workaround shipped:** `LOOK_BYTECODE=0` in docker-compose.yml (and required for the
Plesk service env) — correct but slower per request. **Permanent fix is a LOOK core
decision** (VM compiler: per-`use`-file compilation units / separate register scope for
route closures / lift the 256-register cap / fail loud on register exhaustion instead of
emitting wrong code). Reproduction: run the same image with `-e LOOK_BYTECODE=0` on a
second port and compare response byte counts. Until fixed, LookPress must ship with the
VM off, and the route budget stays at ≤ 69.

- Follow-up (small): `response::status(404, body)` ignores the body in the core, so
  404 pages are blank — render the not-found view with `response::html` + a status call.

### Wave 3 — polish & proof
- ⬜ Populated demo site per vertical (kurumsal / haber / e-ticaret) + first-run onboarding.
- 🟡 Email wired to flows (order/contact/reset) via core `mail::`.
- ⬜ Backups (DB + uploads) one-command; deploy to test.codlook.com.
- ⬜ WXR importer, FTS5 search, product-layer benchmarks, security audit pass.

### Already shipped (for the record)
Type engine + auto CRUD/API/admin · versioned content + rollback · scheduled
publishing · 15+ field types incl. blocks · nested categories · media library +
picker · markdown toolbar · forms + submissions · RBAC · multi-language · SEO
(meta/OG/JSON-LD/sitemap/RSS) · search · themes/skins (responsive) · commerce
core (cart/checkout/orders/coupons) · Docker · Plesk deploy · extension seams.

## Engineering conventions (for every contributor and agent)
- Never edit `cpp/` (the LOOK core). Product layer only.
- LOOK gotchas: undefined variables are a STRICT error; `?:` unreliable → if/else;
  `[]` is a LIST — string-keyed maps need `array::new_assoc()`; a missing map key
  returns **null, it does not throw** → null-check, not try/catch; template has
  `{#each}`/`{#if}` but **no `{#else}`**; `{!$x}` raw, `{$x}` escaped.
- No new `route()` without the orchestrator's approval (budget). Functions are free.
- Verify every slice on a fresh volume: `docker compose down -v && up --build`,
  `/en/{type}/{slug}` 200, `VM routes: N` ≤ 70, zero "VM BUG"/fallback lines.
- Commits: English, `Feat:/Fix:/Refactor:/Docs:` prefix, author Codlook only.
