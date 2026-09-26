# LookPress V2 — Architecture Contract

The one rule: **we raise developer experience using LOOK's real mechanisms — we do
not add a new language, DSL, ORM, or runtime magic.** Everything below is chosen to
be buildable on LOOK as it exists today (no core changes), and to keep the product's
philosophy: *nothing hidden, the shortest path from request to response.*

This document is the contract that later work (CLI, modules, themes, commerce) must
follow. It is locked before any generator or feature is written, so a generator never
emits files against a structure we then have to change. Roadmap phasing lives at the
bottom; the day-to-day CMS feature list stays in [ROADMAP.md](../ROADMAP.md).

---

## 1. Hard constraints (measured, not opinions)

These come from what LOOK actually does. They are the boundary every design honors.

- **No chained query-builder / ORM.** `Model::where(...)->orderBy(...)->paginate()`
  hides SQL — against the philosophy, and a deliberate RED. Allowed: thin record
  helpers (`find/all/create/update/delete`) that run one obvious query. Not allowed:
  a fluent query language.
- **No new declarative syntax.** `resource Product { name: string }` and
  `module Blog { type Post {...} }` are *not* LOOK syntax; adding them means changing
  the LOOK core, which is forbidden. Such declarations exist only as **CLI codegen
  input** that produces ordinary `.lk`, or as a **function call** taking data
  (`resource("product", [fields])`), never as language blocks.
- **No dynamic dispatch of stored closures.** Measured: a closure placed in the
  `app::` registry and invoked at request time fails in the serving VM
  (`no active VM` / `not callable`). Extension points therefore use **function
  override** (core defines an empty default; a later-loaded file redefines it —
  LOOK is last-definition-wins), never a runtime listener registry.
- **No dynamic module loading.** `use "path"` takes a literal path resolved at
  load/compile time. Modules are composed by an **explicit `use` list**, edited by
  the CLI or by hand (the Django `INSTALLED_APPS` pattern) — not discovered and
  loaded at runtime.
- **No runtime capability sandbox.** Enforcing per-module permissions like
  `db.read` / `file.read` at runtime needs the LOOK core to jail used code — a core
  change, forbidden. A module manifest may *declare* capabilities as documentation
  and review signal, but this is a **trust boundary, not runtime-enforced**. Say so
  honestly; do not imply isolation we don't provide.

Anti-patterns, explicitly out of scope for the product layer: chained ORM, a new
LOOK DSL, runtime dynamic dispatch, dynamic module loading, runtime capability
sandboxing. Anyone proposing these is proposing LOOK-core work, which is a separate,
deliberate decision — not part of LookPress.

## 2. Core ↔ LookPress boundary

Before adding anything, ask: *is this LOOK's job or LookPress's?*

- **LOOK (the runtime, never modified here):** HTTP, DB drivers, filesystem,
  templating, cache, queue/jobs, timer, crypto, sessions, concurrency.
- **LookPress (this product):** CMS, content types, commerce, SEO, themes, forms,
  payments, admin, modules, CLI. Built *on* LOOK, touching no core file.

LookPress grows without ever asking the LOOK core for a new feature.

## 3. Architecture

```
                         LOOKPRESS
                             │
                 ┌───────────┴───────────┐
                 │                       │
               CORE                    MODULES            THEMES
        (framework seams)        (features, composed      (presentation only)
                 │                by explicit use list)
        router · auth · rbac            │
        db conn · settings       cms · media · forms
        view/ext_view · seo      commerce · payments …
        extension points (xp_*)
                 │
        STATIC COMPOSITION  →  explicit `use`  →  function override  →  module contract
```

Current tree stays; it evolves toward:

```
lookpress/
├── app.lk                 # composition root: use core, use modules (order matters)
├── config/                # config.lk (constants, permission catalog), modules list
├── src/                   # framework: core.lk hooks.lk rbac.lk types.lk render.lk
├── modules/               # features (commerce, and future: forms, media, seo …)
│   └── <name>/            # module contract (§4)
├── themes/                # presentation only (§6)   [today: views/themes/]
├── views/admin/           # admin theme (shared shell)
├── lib/                   # markdown, migrate
├── database/              # setup.lk, setup_v2.lk (entry-anchored migrations)
└── test/                  # smoke + future suites
```

> Migration note: today the one module lives in `extensions/commerce/`. "extensions"
> → "modules" is a rename to do when a second module lands, not before — it buys
> nothing on its own and the contract below already applies to `extensions/commerce`.

## 4. Module contract

A module is a directory under `modules/` (today `extensions/`). Only `module.lk` is
required; the rest exist when the module needs them.

```
modules/<name>/
├── module.json      # manifest (name, version, requires, permissions, capabilities*)
├── module.lk        # entry: routes + extension-point overrides + wiring
├── schema.lk        # xp_migrate / xp_seed overrides (routes-free, loaded by setup)
├── service.lk       # business logic (functions; called from routes)
├── admin.lk         # admin routes (optional; may live in module.lk)
├── api.lk           # JSON API routes (optional)
├── permissions.lk   # permission keys via xp_permissions (optional)
└── views/           # module-owned templates, rendered via ext_view/ext_admin_view
```
`*capabilities` is declarative only (§1, trust boundary).

**How a module plugs in — three mechanisms, all static:**

1. **Composition:** the root lists it once — `use "modules/<name>/module.lk"` in
   `app.lk` (runtime) and `use "modules/<name>/schema.lk"` in `setup_v2.lk`
   (migrations). Load order: core seams first, modules after, the dynamic
   catch-all router LAST (routing is first-match by registration order).
2. **Routes:** the module calls `route(...)` at load — registers in order.
3. **Seams:** the module overrides the core's `xp_*` extension-point functions
   (§5) to inject UI, stats, nav, migrations, seed, permissions. No listener
   registry; plain function override.

Manifest example:

```json
{
  "name": "commerce",
  "version": "1.0.0",
  "requires": ">=1.0",
  "permissions": ["orders", "coupons"],
  "capabilities": ["db.read", "db.write", "mail.send"]
}
```

Reference implementation: `extensions/commerce/` already follows this
(module.lk = commerce.lk, schema.lk, views/, manifest = extension.json).

## 5. Extension points (the `xp_*` seams)

The core defines each as an empty default in `src/hooks.lk` and calls it by name
(static call); a module redefines the ones it needs. Current seams:

| Seam | Fires | Returns |
|---|---|---|
| `xp_content_after_body($ctx)` | below a content page body | HTML |
| `xp_content_head($ctx)` | in a content page `<head>` | HTML |
| `xp_home_sections($ctx)` | homepage showcase | HTML |
| `xp_admin_nav($ctx)` | admin sidebar (own group) | HTML |
| `xp_dashboard_stats($x)` | admin dashboard tiles | HTML |
| `xp_dashboard_panels($x)` | admin dashboard panels | HTML |
| `xp_hidden_types()` | content types a module owns | slug list |
| `xp_permissions()` | RBAC catalog additions | `[{key,label}]` |
| `xp_migrate($c)` | create module tables (setup) | — |
| `xp_seed($c)` | seed module demo data (setup) | — |

Planned additions (as needed, same mechanism): `xp_routes_api`, `xp_settings_panel`,
`xp_content_types` (register a type from a module), `xp_menu_locations`.
**v1 limit:** one provider per seam (last loaded wins). Multi-listener aggregation
is a later change to `src/hooks.lk` only, not to callers.

## 6. Content Engine vs Domain Models

Two data layers, chosen by shape — this is the key structural decision.

**Content Engine** — the existing type engine. For editorial content whose shape is
a bag of fields: `page, post, news, announcement, team, faq, event, portfolio,
service, product (catalog side)`. Define a type → automatic CRUD + `/api/{type}` +
admin + validation + revision + public URL + sidebar entry. Storage:
`content` + `revisions` + `fields_json`. **Do not reinvent this** — it is already
the "resource" system for content.

**Domain Models** — real relational tables for transactional / relational data that
does not fit a field bag: `orders, order_items, product_variants, inventory,
customers, payments, refunds, coupons, bookings, subscriptions, invoices`. Access
via **thin per-model helpers**, no query-builder:

```
<model>_find($c, $id)          -> row or null
<model>_all($c, $filters)      -> rows (fixed, named filters — not a query language)
<model>_create($c, $data)      -> id
<model>_update($c, $id, $data) -> bool
<model>_delete($c, $id)        -> bool
```

Helpers wrap one clear `db::query` / `db::exec`. Anything more complex is written as
explicit SQL in a `service.lk` function. Migrations for domain tables ship in the
module's `xp_migrate`.

Rule of thumb: **editorial → Content Engine; transactional/relational → Domain
Model.** Commerce uses both (product = content type; orders/variants = domain).

## 7. Theme contract

A theme is presentation only — HTML, CSS, assets, template data. It never contains
business logic, routes, DB, or admin. Switching a theme changes presentation;
content, products, users, orders and SEO are untouched.

```
themes/<name>/
├── theme.json       # manifest: name, version, requires, templates[], screenshot
├── layout.html      # base layout (skins/palettes)
├── home.html · page.html · post.html · list.html · search.html · … (overridable)
├── assets/          # css, images
└── translations/    # optional per-language strings
```

Resolution stays as today: `view()` renders `themes/<active>/<tpl>` and falls back
per-template to `themes/default/<tpl>`, so a theme overrides only what it changes.
Admin (Themes screen) lists installed themes with Preview / Activate; activation is
a settings write (the active theme is a setting). Modules ship no theme; themes ship
no module — the split is load-bearing.

## 8. Payment adapter contract

Payment is a domain concern with a provider adapter, selected by config — no runtime
provider discovery.

```
config:  payment.provider = "paytr" | "iyzico" | "stripe" | "bank_transfer"
API:     payment_charge($order)          -> {ok, redirect?|status}
         payment_verify_webhook($req)    -> {ok, order_id, status}
         payment_refund($payment)        -> {ok}
```

Each provider is a file statically included in the composition; the active one is
chosen by config. Callers use the thin API and never name a provider. Test mode is a
provider mode, not a separate code path.

## 9. Definition of Done ("LOOKPRESS READY")

A slice is done only when: it is verified end to end, added to the smoke suite,
compiles clean on the VM (0 fallback), and — for anything with a schema — its
migration is idempotent and re-runnable. Claims (perf, parity) ship with a number
and a method or not at all. Source and deployed artifact must match.

## 10. Phased plan (V2)

Contract first (this document). Then, in order — each phase builds only on
mechanisms this contract allows:

| Phase | Scope | Notes |
|---|---|---|
| **V2.0** | **This contract, locked** | file/module/theme/domain/payment contracts |
| V2.1 | CLI / codegen | `lkpress new / make:type / make:module / make:theme`; emits real `.lk` per §4/§6/§7 |
| V2.2 | Module composition | `config/modules.lk` list; `extensions/` → `modules/` rename |
| V2.3 | Domain-model pattern | thin helpers; commerce orders/variants as reference |
| V2.4 | Theme manifest + Themes admin | install / preview / activate |
| V2.5 | Payment adapter | one real provider (test mode → live) |
| V2.6 | Rich content fields | richtext, repeater, gallery, file, datetime, multi-select |
| V2.7 | Media / image pipeline | folders, alt text, WebP/srcset (needs an exec-capable module) |
| V2.8 | Form engine | field builder, validation, spam, notify, export |
| V2.9 | API v1 | filter/sort/paginate/include; OpenAPI |
| V2.10 | Search | FTS5 over content |
| V2.11 | Backup / restore | DB + uploads + config snapshot |
| V2.12 | Production security / health | headers, rate limit, health dashboard |
| V2.13 | WordPress importer | WXR → content types |

The CMS-side detail (taxonomy, relations, per-item SEO, translation UI, list UX) is
tracked in [ROADMAP.md](../ROADMAP.md) and slots into V2.6–V2.10 as those land.

---

**In one line:** keep the current architecture; from here, add *developer
abstraction* — CLI codegen, a static module contract, a domain-model pattern, a theme
contract, a payment adapter — using only what LOOK supports, and never a query
language, a new syntax, dynamic dispatch, dynamic loading, or a runtime sandbox.
