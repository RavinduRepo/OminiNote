# OneNote → omininote importer

Recovers notes from OneNote `.onepkg` / `.one` files — ink strokes (with real
colors, widths, pen vs highlighter), images, embedded files (PDFs), and rich
text — and converts them into omininote's on-disk store.

## Pipeline

```
.onepkg ──expand──▶ .one files ──extractor (Rust)──▶ extract.json + assets/
                                       │
                                       ├──▶ preview.html   (visual check)
                                       └──convert.dart──▶ omininote store ──--install──▶ app data dir
```

## Requirements

- Windows (`expand.exe` ships with the OS) — only needed for `.onepkg` input
- Rust toolchain (`cargo`) — builds the extractor once
- Node/npm — only to fetch the parser source
- Dart (comes with Flutter) — runs the converter

## Usage

All commands from the repo root unless noted.

### 0. Fetch the parser source (once)

The extractor builds against [Joplin's OneNote parser](https://www.npmjs.com/package/@joplin/onenote-converter)
(Rust, MPL-2.0). Fetch its source into the gitignored `.cache/`:

```powershell
cd tools/onenote_importer/.cache
npm pack @joplin/onenote-converter --silent
tar -xzf joplin-onenote-converter-*.tgz     # creates .cache/package/
```

### 1. Unpack the .onepkg

`.onepkg` is a Windows cabinet. Section groups are subdirectories — keep them:

```powershell
mkdir tools\onenote_importer\input\mynotes
expand "path\to\My Notebook.onepkg" -F:* tools\onenote_importer\input\mynotes
```

### 2. Extract

```powershell
cd tools/onenote_importer/extractor
cargo build --release
cd ..
.\extractor\target\release\onenote_extractor.exe output\mynotes input\mynotes
```

Writes `output/mynotes/extract.json`, `extract.js`, and lossless `assets/`.

### 3. Preview (optional but recommended)

```powershell
copy preview\preview.html output\mynotes\
start output\mynotes\preview.html
```

Renders every page with real images at true positions/scales and ink strokes
with their actual colors/widths — verify before converting.

### 4. Convert (+ install)

```powershell
cd ..\..    # repo root
dart run tools/onenote_importer/convert.dart tools/onenote_importer/output/mynotes --name "My Notebook"
# then, with the app closed:
dart run tools/onenote_importer/convert.dart tools/onenote_importer/output/mynotes --name "My Notebook" --install
```

`--install` backs up `notebooks.json` (`.bak-<ts>`) and merges the imported
notebook into the local store (`%APPDATA%\io.github.ravinduRepo\omininote`).
The notebook imports as **local-only** (`syncTarget: null`); attach it to an
account from the app if you want it synced.

## Mapping

| OneNote                    | omininote                                            |
| -------------------------- | ---------------------------------------------------- |
| notebook (.onepkg)         | Notebook                                             |
| section group (folder)     | super-section `FolderNode` in the notebook tree      |
| section (.one)             | Section                                              |
| page                       | Canvas (named by page title)                         |
| sub-page (level 2/3)       | `FolderNode` in the section's canvas tree, parent canvas first |
| page content (infinite)    | tiled into pages: vertical bands → `PageRow`s, horizontal cuts inside wide bands → pages in a row. Cuts are placed only where **no element crosses** (gaps in the content), so nothing is ever split; bands tile the content region contiguously so spacing is preserved. Content that has no usable gap stays on one larger page. |
| ink stroke                 | `StrokeElement` — COLORREF → ARGB, HIMETRIC → pt, `pen_tip`/transparency → pen vs highlighter (highlighter size ÷ 2.6 to offset the painter's ×2.6) |
| image (incl. PDF printout) | `ImageElement`, z = −1 (below ink), lossless bytes, displayed size = `picture_*` capped by `layout_max_*` |
| embedded file (PDF, …)     | `AttachmentElement` chip at its true position + content-addressed asset |
| rich text                  | `TextElement` with styled runs (font size = half-points ÷ 2, families mapped to sans/serif/mono, hyperlinks kept) |

### Units (from MS-ONE / verified against Joplin's renderer)

- Layout offsets/sizes: **half-inch** increments → ×36 = PDF points
- Ink coordinates & stroke widths: **HIMETRIC** (1/2540 inch) → ×72/2540 = PDF points;
  stroke paths are delta-encoded (first point absolute) — the extractor decodes them
- Stroke color: Windows **COLORREF** `0x00BBGGRR`; null = default (black)
- Font sizes: **half-points**

## Tests

`test/onenote_import_test.dart` covers the tiling invariants (cuts only in
gaps, contiguous bands, every element fully inside its page), color/unit
conversion, sub-page tree building, and — when a converted store exists under
`output/` — round-trips the whole store through the app's real models.

## Notes / limitations

- Text box heights are estimated (the app re-measures on first edit).
- Ink embedded *inside* a text line (handwriting-as-text) is placed at its
  outline's offset — OneNote computes its exact inline position from text
  flow, which isn't reproduced.
- Stroke pressure isn't exposed by the parser; imported strokes use p=0.5.
- OneNote's per-page background color/rule lines aren't imported (pages get
  the app default).
