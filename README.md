# LOOK CMS

A **static-first, version-controlled** content management system built on
[LOOK](https://github.com/codlook/look).

Not "WordPress but faster." LOOK CMS targets WordPress's five *structural* loads — not its feature
list:

| WordPress's structural load | LOOK CMS's structural answer |
|---|---|
| Every request renders (PHP + MySQL + cache + CDN, invalidation hell) | **Static-first** — publish generates HTML; a request serves a file |
| Plugins run arbitrary in-process code (the source of most WP hacks) | Extensions **declare capabilities**; **themes cannot run code — by design** |
| Content is a mutable blob (partial revisions, no audit, painful migration) | **Immutable, versioned content core**; export is plain Markdown files |
| Content types need a plugin (ACF / CPT-UI, shortcode lock-in) | **Define fields → CRUD + a JSON API, auto-generated** |
| Updates are risky ("don't touch it, it works") | **Atomic publish + real rollback** (a pointer move over immutable revisions) |

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
