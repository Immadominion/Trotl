# Throtl — landing page

A self-contained static landing page for **Throtl**, wearing the app's chunky
cartoon racing aesthetic (Lilita One + Baloo 2, the Arcade palette, candy
bevel buttons, cream cards, blue-sky gradient screens). The layout structure
follows the `Troof Redesign.html` handoff (hero + device mockup with soft glow
blobs and film grain → feature grid → how-it-works → garage → on-chain proof →
CTA → footer), re-skinned entirely in Throtl's own design system from
`app/app/lib/src/theme/tokens.dart` and `.design-ref/.../game-ui-kit.jsx`.

## Files

```
site/
├── index.html      # all markup
├── styles.css      # design tokens + every component (ported from the app `G` tokens)
├── app.js          # marquee, scroll reveals, parallax, cockpit micro-interactions, CTA wiring
└── assets/
    ├── fonts/      # LilitaOne-Regular.ttf, Baloo2-Variable.ttf (bundled offline)
    ├── cars/       # real Kenney car side sprites (from the app assets)
    ├── track/      # checkered flag + scenery
    └── favicon.png
```

## The CTA → web app game

Every "Play / Launch the game" button is the call-to-action to the **web app
game** (the Flutter web build). All of them are wired through a single constant
at the top of `app.js`:

```js
var GAME_URL = '/play/';   // <- change this one line to repoint every CTA
```

It defaults to `/play/`, i.e. serve this landing page at the site root and the
Flutter web build (`app/app/build/web`) under `/play/`. Point it at an absolute
URL (e.g. `https://throtl.fun/play`) if the game lives elsewhere.

## Run locally

It's plain static files — serve the folder with anything:

```bash
cd site
python3 -m http.server 8080
# open http://localhost:8080
```

To preview the full experience with the game behind the CTA, build the Flutter
web app and drop it at `site/play/`:

```bash
cd app/app && flutter build web
cp -r build/web ../../site/play
```

## Notes

- Fonts are self-hosted (no Google Fonts request) so it matches the app exactly
  and works offline.
- Respects `prefers-reduced-motion` — all animation and scroll reveals fall back
  to a static layout.
- No build step, no dependencies, no framework.
