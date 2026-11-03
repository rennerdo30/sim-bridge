# Sim Bridge documentation

The project documentation uses the existing
[docs-template](https://github.com/rennerdo30/docs-template) structure with Astro,
Starlight, and Galaxy. Its template license is retained in `TEMPLATE_LICENSE`.
The visual palette follows the app's green and porcelain branding.

The scoped npm override uses `postcss-selector-parser` 7.1.6 under `postcss-nested`
6.2.0 to fix [GHSA-rj75-hqrm-r3gf](https://github.com/postcss/postcss-selector-parser/security/advisories/GHSA-rj75-hqrm-r3gf).
Keep it until the upstream dependency adopts a patched parser; recheck nesting
transforms and the full documentation build when changing it.

Use Node.js 22.12 or newer (the Node 22 LTS line is pinned in `.nvmrc`). From `docs/`:

```sh
npm ci
npm run dev
npm run build
npm run preview
```

Open the local server at `/docs/`, matching the configured base; the homepage in `website/` is served at the site root.
Content lives in `src/content/docs/`; screenshots live in `public/screenshots/`.
Keep every image's provenance and synthetic-data label accurate. No live messages,
phone numbers, invitation codes, or operator credentials belong in documentation.

The `Documentation` workflow validates pull requests and deploys `main` through
GitHub Pages after a successful build. Repository **Settings → Pages → Source** must
be **GitHub Actions**. The configured URL is
`https://sim-bridge.renner.dev/docs/`; a local build does not establish deployment.
