# LookPress — Engineering Roadmap

## What LookPress is

LookPress is a batteries-included web platform written in **pure LOOK** — a
language built for the web. One runtime gives you a CMS, a commerce layer, a JSON
API, and an admin, with **minimal external runtime dependencies** (the database
driver is built in; no package tree to install and audit). It runs from a single
front controller (`app.lk`) served by `lk-fcgi`.

The goal is to cover, in one coherent system, the ground that today needs a
**CMS + a framework + a pile of packages**:

| You'd normally reach for | LookPress gives you, in one runtime |
|---|---|
| **WordPress / WooCommerce** (content, shop, admin) | content types, versioned content + rollback, catalog, cart, orders, coupons, admin |
| **Laravel / Django** (framework, routing, ORM, migrations, auth) | routing, a type engine, versioned migrations, PBKDF2 auth + RBAC, templating |
| **A stack of services** (search, sitemap, feeds, i18n) | search, sitemap/robots/RSS, multi-language, SEO/JSON-LD — built in |

This is **positioning, not a takedown**. WordPress, Laravel and Django are
excellent and huge. LookPress bets on a different trade: *less code, fewer
dependencies, less resource use, less setup — because the language itself is
built for the web.* Every comparative claim below is something we **measure**, or
mark as not-yet-measured. We don't ship "zero dependency" or unbenchmarked
"N× faster" slogans.

## Where it stands today (verified)

Live reference deployment: **https://test.codlook.com** (Plesk, `lk-fcgi` behind
Apache/nginx, running as the site's system user, SQLite).

Working and locked by a 34-check smoke suite + CI:

- **CMS** — type engine (define a content type → auto CRUD + `/api/{type}` +
  admin), versioned content with revision history and one-click rollback.
- **Commerce** — products, catalog, cart, checkout (test-mode), orders, order
  status, coupons.
- **Platform** — routing (first-match), PBKDF2 auth + `admin`/`editor` RBAC,
  multi-language (`/en`), SEO (meta/OG/JSON-LD, sitemap, robots, RSS), search,
  forms, media library, themes + skins, a responsive admin.
- **Ops** — Docker image + `docker compose up`; idempotent migrations + seed;
  Plesk deployment (see [docs/plesk-deploy.md](docs/plesk-deploy.md)); clean
  modular code (`app.lk` · `config/` · `src/` · `routes/` · `views/` · `lib/`).

**Honest status:** great for a content site, blog, catalog, MVP, or internal
tool **today**. Not yet ready to take real money from real customers — that's
Phase A.

## Principles (the engineering guardrails)

1. **Never modify the LOOK core.** LookPress is 100% product layer. If something
   needs the language, it's a separate, deliberate core decision — not smuggled in.
2. **Minimal external runtime dependencies.** Adding one is a decision with a
   written reason, not a reflex.
3. **Measured claims only.** Performance and "parity" statements ship with a
   number and a method, or not at all.
4. **Every slice verified end to end** and added to the smoke suite before it's
   "done". Source and deployed artifact must match.
5. **Versioned, idempotent migrations.** Schema changes are tracked and re-runnable.
6. **Security by default** — fail-loud on missing secrets, secure cookies behind
   TLS, run as the least-privileged user.

---

## Phase A — Production-ready for a real shop

*Goal: a real business can launch a store and take orders.* Acceptance: a
customer registers, orders, pays in a provider's test mode end to end, and both
the customer and the shop get an email; the site runs on HTTPS with backups.

- **A1 Payment** — a payment module with a provider adapter (iyzico / PayTR to
  start), test-mode → live, order marked paid on callback, idempotent webhooks.
  *Acceptance: a test-mode payment completes and flips the order to `paid`.*
- **A2 Transactional email** — wire `mail::` (SMTP) for order confirmation and
  password reset; a queued sender so a slow SMTP never blocks a request.
  *Acceptance: order + reset emails delivered (verified against a real MTA).*
- **A3 Customer accounts** — storefront register / login / reset (separate from
  admin users), order history. *Acceptance: a customer sees their past orders.*
- **A4 Hardening** — `LOOK_SESSION_SECURE` + trusted-proxy on by default in the
  deploy templates, rate limiting configured, `HEAD` handled (today `HEAD /` →
  404), security headers (HSTS/CSP) in the proxy templates.
- **A5 Backups** — a documented, scheduled backup of the DB + `uploads/`
  (and a one-command restore), for both SQLite and MySQL/Postgres.

## Phase B — A real framework alternative (developer experience)

*Goal: a developer builds a site on LookPress without touching its internals.*
Acceptance: `lk lookpress new mysite` scaffolds a working project; a third-party
module installs and adds routes/admin with no core edits.

- **B1 CLI / scaffolding** — `new project`, `make:type`, `make:theme`,
  `make:module`; migrate up/status. *Acceptance: scaffold → running site, no manual wiring.*
- **B2 Module system with contracts** — a documented extension point (routes,
  admin pages, migrations, settings) with versioned contracts and a dependency
  graph, so modules compose without a core change. *Acceptance: two independent
  modules install together and each adds an admin section.*
- **B3 Theme format** — a documented theme package (templates + assets +
  manifest), installable/switchable, with the per-template override + fallback
  already in place.
- **B4 Docs site** — task-oriented documentation (build a blog, a shop, a module,
  a theme) published from the repo.

## Phase C — Content & commerce depth (where WP/Woo parity matters)

*Goal: close the gaps that make people reach back for WordPress/WooCommerce.*

- **C1 Media pipeline** — automatic image → WebP + `srcset` (needs the
  `process::exec cwebp` module — a Phase-2 prerequisite already scoped), a media
  picker in the field editor.
- **C2 Richer content** — more field types (repeater, relation multi-select,
  gallery), draft/scheduled publishing, an editor upgrade.
- **C3 Commerce depth** — product variants, inventory, tax & shipping rules,
  digital products. *Acceptance: a variable product with stock checks out.*
- **C4 Migration & search** — a WordPress **WXR importer** (a real market lever)
  and **FTS5** search to replace SQL `LIKE`.
- **C5 Admin maturity** — list pagination, bulk actions, filters.

## Phase D — Scale & assurance

*Goal: prove the resource/perf story and harden the product layer.*

- **D1 Benchmarks** — reproducible load tests of the **product layer** (not just
  the core), published with method and numbers, including a fair comparison
  against a comparable WP/Laravel setup. This is where the "less resource, less
  code" claim gets earned.
- **D2 Security audit** — an adversarial pass over the LookPress layer (authz,
  multi-tenant isolation, upload handling, payment/webhook), on top of the core's
  existing audits.
- **D3 Multi-DB hardening** — MySQL/Postgres validated at parity with SQLite
  under load; connection-pool tuning.
- **D4 Observability** — request metrics + an ops dashboard (counters are core,
  the dashboard is a module).

## Ongoing debt (not a phase — fix as we touch the code)

- **Presentation extraction** — a few handlers still build HTML as strings in
  `.lk` (`cards_html`, `render_fields_html`, admin table rows). Move them into
  `{#each}` template partials (the blog list already does this — make it uniform).
- **Rebrand pass** — ensure user-facing strings and defaults read "LookPress"
  consistently.

---

### Sequencing

**A → B → C → D**, but A5 (backups) and A4 (hardening) land immediately since the
platform is already deployed live. Phase A is what turns "you can start a real
project" into "you can run a real business." Everything is measured, verified,
and added to the smoke suite as it ships — no item is "done" until it is.
