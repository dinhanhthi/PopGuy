# PopGuy Website

The marketing and documentation site for PopGuy, built with React and Vite.

## Development

```sh
npm install
npm run dev
```

## Verification

```sh
npm test
npm run build
```

The site includes Home (`/`), Actions (`/actions`), Docs (`/docs`), and Privacy (`/privacy`) routes.
The download buttons point to the latest GitHub release, which macOS and Windows share (one `vX.Y.Z` release): the
macOS button to the release page, the Windows buttons to its `PopGuy-win-<arch>-Setup.exe` through
`/releases/latest/download/` (and the docs' portable links to `PopGuy-win-<arch>-Portable.zip`).

## Deploy

GitHub Pages, custom domain `pg.dinhanhthi.com` (Cloudflare DNS, zone `dinhanhthi.com`: CNAME `pg`
→ `dinhanhthi.github.io`, DNS only). `.github/workflows/deploy-pages.yml` builds this site on every push to `main` that
touches `website/` or `appcast.xml` (every release commits it), and publishes it together with the Sparkle feed
`appcast.xml`: one Pages site serves both, so they always deploy in the same artifact.

Pages has no rewrites, so the workflow copies `index.html` to `actions.html`, `docs.html`,
`privacy.html` (one per route, served at `/actions`, `/docs`, `/privacy`) and `404.html`.
Add a new route there too, and in `public/sitemap.xml`.
