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
The macOS download button points to the latest GitHub release (always the macOS one); the Windows buttons point to the
`windows-v<Version>` release's Setup.exe, with `<Version>` read from `windows/src/PopGuy.App/PopGuy.App.csproj` at build
time (publish that release before the version reaches `main`).

## Deploy

GitHub Pages, custom domain `pg.dinhanhthi.com` (Cloudflare DNS, zone `dinhanhthi.com`: CNAME `pg`
→ `dinhanhthi.github.io`, DNS only). `.github/workflows/deploy-pages.yml` builds this site on every push to `main` that
touches `website/`, `appcast.xml` or the Windows App csproj (its version), and publishes it together with the Sparkle feed
`appcast.xml`: one Pages site serves both, so they always deploy in the same artifact.

Pages has no rewrites, so the workflow copies `index.html` to `actions.html`, `docs.html`,
`privacy.html` (one per route, served at `/actions`, `/docs`, `/privacy`) and `404.html`.
Add a new route there too, and in `public/sitemap.xml`.
