"""Generate the full OmniNote icon pack."""
import os
import json
import shutil
from pathlib import Path
from PIL import Image
from renderer import (
    render_icon, render_o_only, render_solid_bg, render_circular,
    render_maskable, render_splash, AMBER, DARK,
)

ROOT = Path("/home/claude/OmniNote-IconPack")
if ROOT.exists():
    shutil.rmtree(ROOT)
ROOT.mkdir(parents=True)

def save(img: Image.Image, path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    img.save(path, optimize=True)

# --------------------------------------------------------------------
# 1. SOURCE MASTERS
# --------------------------------------------------------------------
src = ROOT / "source"
save(render_icon(1024, rounded=True),  src / "omninote-1024-rounded.png")
save(render_icon(1024, rounded=False), src / "omninote-1024-square.png")
save(render_icon(2048, rounded=True),  src / "omninote-2048-rounded.png")

# --------------------------------------------------------------------
# 2. iOS — AppIcon.appiconset (square, no pre-rounded corners)
# --------------------------------------------------------------------
ios = ROOT / "ios" / "AppIcon.appiconset"
ios_specs = [
    # (filename, size_px, scale_label, idiom, size_pt)
    ("Icon-20@2x.png",       40,  "2x", "iphone",         "20x20"),
    ("Icon-20@3x.png",       60,  "3x", "iphone",         "20x20"),
    ("Icon-29@2x.png",       58,  "2x", "iphone",         "29x29"),
    ("Icon-29@3x.png",       87,  "3x", "iphone",         "29x29"),
    ("Icon-40@2x.png",       80,  "2x", "iphone",         "40x40"),
    ("Icon-40@3x.png",       120, "3x", "iphone",         "40x40"),
    ("Icon-60@2x.png",       120, "2x", "iphone",         "60x60"),
    ("Icon-60@3x.png",       180, "3x", "iphone",         "60x60"),
    ("Icon-ipad-20@1x.png",  20,  "1x", "ipad",           "20x20"),
    ("Icon-ipad-20@2x.png",  40,  "2x", "ipad",           "20x20"),
    ("Icon-ipad-29@1x.png",  29,  "1x", "ipad",           "29x29"),
    ("Icon-ipad-29@2x.png",  58,  "2x", "ipad",           "29x29"),
    ("Icon-ipad-40@1x.png",  40,  "1x", "ipad",           "40x40"),
    ("Icon-ipad-40@2x.png",  80,  "2x", "ipad",           "40x40"),
    ("Icon-76@2x.png",       152, "2x", "ipad",           "76x76"),
    ("Icon-83.5@2x.png",     167, "2x", "ipad",           "83.5x83.5"),
    ("Icon-marketing.png",   1024,"1x", "ios-marketing",  "1024x1024"),
]
images_json = []
for fname, sz, scale, idiom, sizept in ios_specs:
    # iOS wants SQUARE — Apple applies the mask itself
    save(render_icon(sz, rounded=False), ios / fname)
    images_json.append({
        "size": sizept, "idiom": idiom, "filename": fname, "scale": scale,
    })
contents = {"images": images_json, "info": {"version": 1, "author": "xcode"}}
(ios / "Contents.json").write_text(json.dumps(contents, indent=2))

# --------------------------------------------------------------------
# 3. ANDROID
# --------------------------------------------------------------------
android = ROOT / "android"
# Legacy launcher (mipmap) — pre-rounded square and round variants
mipmap_sizes = {
    "mdpi":    48,
    "hdpi":    72,
    "xhdpi":   96,
    "xxhdpi":  144,
    "xxxhdpi": 192,
}
# Adaptive icon foreground/background is 108dp — foreground raster sizes:
adaptive_sizes = {
    "mdpi":    108,
    "hdpi":    162,
    "xhdpi":   216,
    "xxhdpi":  324,
    "xxxhdpi": 432,
}
for density, sz in mipmap_sizes.items():
    dpath = android / "res" / f"mipmap-{density}"
    save(render_icon(sz, rounded=True), dpath / "ic_launcher.png")
    save(render_circular(sz),           dpath / "ic_launcher_round.png")

for density, sz in adaptive_sizes.items():
    dpath = android / "res" / f"mipmap-{density}"
    save(render_o_only(sz, safe_zone=0.66), dpath / "ic_launcher_foreground.png")
    save(render_solid_bg(sz),               dpath / "ic_launcher_background.png")

# Adaptive icon XML (values-v26)
adaptive_xml = '''<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@mipmap/ic_launcher_background"/>
    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
</adaptive-icon>
'''
(android / "res" / "mipmap-anydpi-v26").mkdir(parents=True, exist_ok=True)
(android / "res" / "mipmap-anydpi-v26" / "ic_launcher.xml").write_text(adaptive_xml)
(android / "res" / "mipmap-anydpi-v26" / "ic_launcher_round.xml").write_text(adaptive_xml)

# Play Store icon
save(render_icon(512, rounded=False), android / "play-store-512.png")
# Feature graphic for Play Store (1024x500)
from PIL import Image as PILImage, ImageDraw, ImageFont
fg = PILImage.new("RGBA", (1024, 500), DARK)
icon = render_icon(280, rounded=True)
fg.paste(icon, (140, 110), icon)
try:
    font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 88)
    fsub = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 32)
except Exception:
    font = ImageFont.load_default(); fsub = ImageFont.load_default()
d = ImageDraw.Draw(fg)
d.text((480, 175), "OmniNote", font=font, fill=(240, 240, 240, 255))
d.text((483, 285), "Notes that go everywhere.", font=fsub, fill=AMBER)
fg.save(android / "play-store-feature-1024x500.png", optimize=True)

# --------------------------------------------------------------------
# 4. WEB / PWA / FAVICONS
# --------------------------------------------------------------------
web = ROOT / "web"
save(render_icon(16,  rounded=True), web / "favicon-16.png")
save(render_icon(32,  rounded=True), web / "favicon-32.png")
save(render_icon(48,  rounded=True), web / "favicon-48.png")
save(render_icon(96,  rounded=True), web / "favicon-96.png")
save(render_icon(180, rounded=False), web / "apple-touch-icon.png")
save(render_icon(192, rounded=True), web / "android-chrome-192.png")
save(render_icon(512, rounded=True), web / "android-chrome-512.png")
save(render_maskable(512), web / "icon-maskable-512.png")

# favicon.ico multi-res
ico_frames = [render_icon(s, rounded=True) for s in (16, 32, 48)]
ico_frames[0].save(web / "favicon.ico",
                   format="ICO",
                   sizes=[(16,16),(32,32),(48,48)],
                   append_images=ico_frames[1:])

# Social share / OG image 1200x630
og = PILImage.new("RGBA", (1200, 630), DARK)
icon = render_icon(320, rounded=True)
og.paste(icon, (160, 155), icon)
try:
    font  = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 96)
    fsub  = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 34)
except Exception:
    font = ImageFont.load_default(); fsub = ImageFont.load_default()
d = ImageDraw.Draw(og)
d.text((540, 220), "OmniNote", font=font, fill=(240, 240, 240, 255))
d.text((545, 340), "Notes that go everywhere.", font=fsub, fill=AMBER)
og.save(web / "og-image-1200x630.png", optimize=True)

# Web manifest
manifest = {
    "name": "OmniNote",
    "short_name": "OmniNote",
    "description": "Notes that go everywhere.",
    "start_url": "/",
    "display": "standalone",
    "background_color": "#15171C",
    "theme_color": "#DFA550",
    "icons": [
        {"src": "/android-chrome-192.png", "sizes": "192x192", "type": "image/png"},
        {"src": "/android-chrome-512.png", "sizes": "512x512", "type": "image/png"},
        {"src": "/icon-maskable-512.png",  "sizes": "512x512", "type": "image/png", "purpose": "maskable"},
    ],
}
(web / "site.webmanifest").write_text(json.dumps(manifest, indent=2))

# HTML snippet showing how to wire it up
head_html = '''<!-- OmniNote favicons and app icons -->
<link rel="icon" type="image/x-icon" href="/favicon.ico">
<link rel="icon" type="image/png" sizes="16x16" href="/favicon-16.png">
<link rel="icon" type="image/png" sizes="32x32" href="/favicon-32.png">
<link rel="apple-touch-icon" sizes="180x180" href="/apple-touch-icon.png">
<link rel="manifest" href="/site.webmanifest">
<meta name="theme-color" content="#DFA550">

<!-- Social share -->
<meta property="og:image" content="/og-image-1200x630.png">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:image" content="/og-image-1200x630.png">
'''
(web / "head-snippet.html").write_text(head_html)

# --------------------------------------------------------------------
# 5. macOS — AppIcon.iconset (square, macOS applies its own mask)
# --------------------------------------------------------------------
mac = ROOT / "macos" / "AppIcon.iconset"
mac_specs = [
    ("icon_16x16.png",       16),
    ("icon_16x16@2x.png",    32),
    ("icon_32x32.png",       32),
    ("icon_32x32@2x.png",    64),
    ("icon_128x128.png",     128),
    ("icon_128x128@2x.png",  256),
    ("icon_256x256.png",     256),
    ("icon_256x256@2x.png",  512),
    ("icon_512x512.png",     512),
    ("icon_512x512@2x.png",  1024),
]
for fname, sz in mac_specs:
    # macOS icons are traditionally drawn with padding inside a square canvas because
    # macOS does NOT apply its own mask. So we use rounded + a small padding to leave
    # room for shadow/perspective typical of macOS icon grids.
    save(render_icon(sz, rounded=True, padding=0.10), mac / fname)

# --------------------------------------------------------------------
# 6. WINDOWS
# --------------------------------------------------------------------
win = ROOT / "windows"
win.mkdir(parents=True, exist_ok=True)
# Multi-res ICO
ico_sizes = [16, 24, 32, 48, 64, 128, 256]
frames = [render_icon(s, rounded=True) for s in ico_sizes]
frames[0].save(win / "omninote.ico",
               format="ICO",
               sizes=[(s,s) for s in ico_sizes],
               append_images=frames[1:])
# Windows Store / MSIX tile assets
save(render_icon(44,  rounded=True, padding=0.10), win / "Square44x44Logo.png")
save(render_icon(71,  rounded=True, padding=0.10), win / "Square71x71Logo.png")
save(render_icon(150, rounded=True, padding=0.15), win / "Square150x150Logo.png")
save(render_icon(310, rounded=True, padding=0.15), win / "Square310x310Logo.png")
# Wide tile — icon on the left, wordmark on the right
wide = PILImage.new("RGBA", (310, 150), DARK)
icon = render_icon(100, rounded=True)
wide.paste(icon, (16, 25), icon)
try:
    font_w = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 26)
except Exception:
    font_w = ImageFont.load_default()
dw = ImageDraw.Draw(wide)
# Center the wordmark vertically in the remaining space
wm_text = "OmniNote"
wm_bbox = dw.textbbox((0, 0), wm_text, font=font_w)
wm_w = wm_bbox[2] - wm_bbox[0]
wm_h = wm_bbox[3] - wm_bbox[1]
wm_x = 130
wm_y = (150 - wm_h) // 2 - 4
dw.text((wm_x, wm_y), wm_text, font=font_w, fill=(240, 240, 240, 255))
wide.save(win / "Wide310x150Logo.png", optimize=True)

# --------------------------------------------------------------------
# 7. SPLASH SCREENS
# --------------------------------------------------------------------
splash = ROOT / "splash-screens"

# iOS splash — modern devices, portrait
ios_splash_sizes = [
    ("iphone-se-750x1334.png",           750, 1334),  # iPhone SE
    ("iphone-8plus-1242x2208.png",       1242, 2208), # iPhone 8 Plus
    ("iphone-x-1125x2436.png",           1125, 2436), # iPhone X/XS
    ("iphone-xr-828x1792.png",           828, 1792),  # iPhone XR/11
    ("iphone-xsmax-1242x2688.png",       1242, 2688), # iPhone XS Max/11 Pro Max
    ("iphone-12-13-1170x2532.png",       1170, 2532), # iPhone 12/13/14
    ("iphone-12pro-max-1284x2778.png",   1284, 2778), # iPhone 12/13/14 Pro Max
    ("iphone-14pro-1179x2556.png",       1179, 2556), # iPhone 14/15 Pro
    ("iphone-14pro-max-1290x2796.png",   1290, 2796), # iPhone 14/15 Pro Max
    ("ipad-1536x2048.png",               1536, 2048), # iPad 9.7"
    ("ipad-pro-11-1668x2388.png",        1668, 2388), # iPad Pro 11"
    ("ipad-pro-12.9-2048x2732.png",      2048, 2732), # iPad Pro 12.9"
]
for fname, w, h in ios_splash_sizes:
    save(render_splash(w, h), splash / "ios" / fname)
    # Also landscape variant for iPad
    if "ipad" in fname:
        save(render_splash(h, w), splash / "ios" / fname.replace(".png", "-landscape.png"))

# Android splash — common portrait
android_splash_sizes = [
    ("android-mdpi-320x480.png",      320,  480),
    ("android-hdpi-480x800.png",      480,  800),
    ("android-xhdpi-720x1280.png",    720,  1280),
    ("android-xxhdpi-960x1600.png",   960,  1600),
    ("android-xxxhdpi-1280x1920.png", 1280, 1920),
    ("android-fhd-1080x1920.png",     1080, 1920),
    ("android-qhd-1440x2560.png",     1440, 2560),
]
for fname, w, h in android_splash_sizes:
    save(render_splash(w, h), splash / "android" / fname)

# Desktop splash (Windows/macOS launch window)
desktop_splash_sizes = [
    ("desktop-1920x1080.png", 1920, 1080),
    ("desktop-2560x1440.png", 2560, 1440),
    ("desktop-1440x900.png",  1440, 900),
]
for fname, w, h in desktop_splash_sizes:
    save(render_splash(w, h), splash / "desktop" / fname)

# --------------------------------------------------------------------
# 8. README
# --------------------------------------------------------------------
readme = """# OmniNote — Icon Pack

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
"""
(ROOT / "README.md").write_text(readme)

# Include the generator scripts in the pack so it's reproducible
shutil.copy("/home/claude/renderer.py", ROOT / "renderer.py")
shutil.copy("/home/claude/generate_pack.py", ROOT / "generate_pack.py")

print(f"Generated pack at {ROOT}")
# Count files
total = sum(1 for _ in ROOT.rglob("*") if _.is_file())
print(f"Total files: {total}")
