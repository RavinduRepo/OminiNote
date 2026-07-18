# OmniNote — Icon Pack

Generated 07/14/26. Every asset is rendered fresh at its target size (no upscaling).

## Brand tokens
- Amber field:  #DFA550  (RGB 223, 165, 80)
- Dark ink:     #15171C  (RGB 21, 23, 28)
- Corner style: 22.37% squircle (iOS-standard continuous curvature)

## Folder guide

### source/
Master 1024 and 2048 renders. Use these to derive any additional custom sizes.

### ios/AppIcon.appiconset/
Drop the entire `AppIcon.appiconset` folder into your Xcode Assets catalog. Icons are
**intentionally square** — iOS applies the corner mask itself. `Contents.json` is
included so Xcode picks up all sizes automatically.

### android/res/
Copy the `mipmap-*` folders straight into `app/src/main/res/`. Includes:
- `ic_launcher.png` — legacy square-ish launcher
- `ic_launcher_round.png` — legacy circular launcher
- `ic_launcher_foreground.png` + `ic_launcher_background.png` — Android 8.0+ adaptive icon
- `mipmap-anydpi-v26/ic_launcher.xml` — adaptive icon manifest
- `play-store-512.png` — Play Console listing
- `play-store-feature-1024x500.png` — Play Console feature graphic

### web/
- `favicon.ico` (multi-res 16/32/48) — the classic
- `favicon-16/32/48/96.png` — modern PNG favicons
- `apple-touch-icon.png` (180×180) — iOS home-screen icon
- `android-chrome-192/512.png` — Android home-screen
- `icon-maskable-512.png` — PWA maskable purpose
- `site.webmanifest` — drop in your web root
- `head-snippet.html` — copy-paste `<head>` markup
- `og-image-1200x630.png` — social share preview

### macos/AppIcon.iconset/
Convert to `.icns` with:
```
iconutil -c icns AppIcon.iconset
```
Icons include a 10% inner padding to sit correctly on the macOS icon grid.

### windows/
- `omninote.ico` — multi-res 16/24/32/48/64/128/256
- `Square44/71/150/310x*Logo.png` — MSIX/Store tile assets
- `Wide310x150Logo.png` — wide tile with wordmark

### splash-screens/
Portrait launch screens for iPhone (SE through 15 Pro Max), iPad (all sizes plus
landscape), Android (mdpi through qhd), and desktop (1440p/1080p/900p).
Icon centered on the dark #15171C background with the OmniNote wordmark beneath.

## Regenerating / customizing
See `renderer.py` and `generate_pack.py` in the source distribution. Change
`AMBER`, `DARK`, `O_WIDTH_RATIO`, etc. at the top of `renderer.py` to tune.
