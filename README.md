# LookPress
n**A Look-native web application & content platform.** Small core, static-first, API-first; measured, not promised.

A **static-first, version-controlled** **site platform** built on
[LOOK](https://github.com/codlook/look).

Not "WordPress but faster," and not a publishing engine — a **platform**: one install can become a
blog, a store, a membership site, or a multilingual corporate site by adding extensions, **without
touching the core.** WordPress's real power was never speed; it was that transformation. LOOK CMS
matches it and targets WordPress's six *structural* loads — not its feature list:

| WordPress's structural load | LOOK CMS's structural answer |
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

## Status

**In design → early build.** The architecture and the phased plan live in
**[PROJECT.md](PROJECT.md)** — read that first.

The code in this repo begins as the reference CMS promoted from
[look-examples/cms](https://github.com/codlook/look-examples/tree/main/cms) (pages, a blog with
pagination, a media library, render-on-save). Phase 1 evolves it into the versioned content core +
type engine described in PROJECT.md.

**Live reference:** **[cms.codlook.com](https://cms.codlook.com)** — this CMS runs its own blog, and
each phase ships there (dogfood = production).

## Not building (v1)

Page builder · comments · multisite · WYSIWYG · a plugin marketplace (the LOOK **package registry**
is it) · Gutenberg-style blocks (structural content types replace them without a blob).

## License

Apache License 2.0 — see [LICENSE](LICENSE). Consistent with the rest of the LOOK ecosystem.
