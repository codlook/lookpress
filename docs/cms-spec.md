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

### Wave 1 — spine, admin IA, security, commerce depth, members
- ⬜ **Module config** (`config_json`) + defaults; `/admin/types` create/edit takes group/icon/labels/columns/filters/order/public. (spine)
- ⬜ **Dynamic list**: per-module columns + filters from config; search/pagination kept. (spine)
- ⬜ **Dynamic sidebar** grouped per the Admin IA table from module config; extensions still inject. (spine)
- ⬜ **Module templates seeded**: Haberler, Duyurular, Galeri, Videolar, Projeler, Etkinlikler, Slider, Sayfalar (with the right fields). (spine)
- ⬜ **gallery** + **repeater** field types (server render + admin UI). (spine)
- ⬜ **CSRF** on admin + public POST; **login rate-limit**; **security headers**. (security)
- ⬜ **Commerce depth**: Markalar (brand module + relation on product), **Özellikler** (attributes repeater), **Varyantlar** (variants repeater: name/sku/price/stock) incl. cart selecting a variant. (commerce, route-free)
- ⬜ **Üyeler**: members table, register/login/logout/profile/orders via `/hesap/{action}` (2 routes). (members)

### Wave 2 — communication, settings, components
- 🟡 **İletişim modülü**: forms exist; add submission status workflow (Destek Biletleri: açık/işlemde/kapalı), İş Başvuruları view, notes, CSV export.
- 🟡 **Ayarlar**: sectioned settings (Genel / Tema / Dil / SEO / İletişim); Sabit Alanlar as global fields.
- ⬜ **Components**: slider, columns, hero, module-listing, form-embed blocks; theme component contract.
- ⬜ **Dashboard**: real at-a-glance panel (counts, recent submissions/orders, quick actions).

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
