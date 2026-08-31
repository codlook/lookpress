# Phase 1 friction log — versioned core + type engine

Building the platform's content subsystem on LOOK. Severity: 🟢 minor · 🟡 real · 🔴 blocker.

| # | Where | What happened | Sev | Fix / note |
|---|-------|---------------|-----|------------|
| 1 | migrate | `UNIQUE(lang, slug)` (from the design) was too narrow — a page and a post may share a slug (different URL namespaces). | 🟡 | Design-first surfaced it before code: use **`UNIQUE(lang, type, slug)`** + a per-type `url_pattern`. Recorded; URL-uniqueness moves to build time (PROJECT.md ③, output-path-collision aborts loudly). |
| 2 | arrays | `$arr[] = x` (append) and `$assoc[$k] = v` (write) are **not** LOOK syntax — the parser rejects `[]`. | 🟢 | Use `array::push($arr, x)` (returns a new array) and `array::set($assoc, $k, v)`. Assoc **read** by key (`$a[$k]`) works; only writes need `array::set`. |
| 3a | routing / setup | Dynamic per-type routing (a `foreach` over `content_types` registering each `url_pattern`) 404'd. Chased through **three refinements** (a good record of "isolate before you blame"): first "`route()` in a loop" (**phantom** — a minimal test registers/matches fine); then "web closure-capture wraps an assoc-indexed value"; the matrix (`debug/min_route3.lk`) narrowed it to a real VM bug (below). But the *actual blocker* for **DB-driven** routing is separate: **`db::query` at the setup / route-collection pass returns 0 rows** (the DB is not queryable while routes are being registered), so route patterns cannot be read from `content_types` at startup. | 🟡 | Route registration must be **config-driven** (a `types.json` read at setup) or use a **request-time dispatcher** — not a startup DB query. A design step, not a code tweak. For now, built-in type patterns are registered directly. |
| 3b | VM capture | Isolated in passing (a real core bug): in the **VM**, a **loop-local variable captured via `use()`** comes back **wrapped in a single-element array** at call time — `json::encode(captured)` is `["x"]`, not `"x"`. The 4-cell matrix pins it: `use()`+loop-local fails; **auto-capture (no `use()`) is clean**; a plain-string loop-local also wraps (assoc is irrelevant); the interpreter is clean. | 🟡 | **Core candidate** — VM `use()` upvalue not unboxed on the read path (a tree-walk↔VM divergence the differential guard should own). Repro: `debug/min_route3.lk` (+ the matrix). Workaround: **use auto-capture instead of `use()`** for loop-scoped closures. |
| 4 | test env | `cp backup.db test.db` over a Windows bind mount left a stale `test.db-wal` → "database disk image is malformed". | 🟢 | Put the working DB on a container-local path (`/tmp`), not the bind mount. (Same bind-mount confound class as the earlier per-request stat finding.) |

## What worked (the type engine, proven end-to-end on migrated live data)

Defining a third type (`product`: title, body, price:decimal, sku, featured:bool, category:relation)
in `content_types` gave it, with **no type-specific code**: a generated admin form (number/checkbox/
select inputs from the field defs), **server-side validation** (required, decimal, select-choice,
relation-target), a generic CRUD, an auto `GET /api/product` (published only), and public rendering.
The **read-surface invariant** held (a draft product appears in neither `/api` nor the public URL;
`/preview/{id}` is admin-gated), and the migrated `page`/`post` content still serves. 0 VM fallback.
This is the platform's first working promise — *define a type, the system generates the rest* — and
the dress rehearsal for the Phase-6 commerce catalog.
