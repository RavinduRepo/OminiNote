# Canvas & Pages — Requirements & Design Spec

Status: **IMPLEMENTED (v1) — 07/06/26.** Phases 1–8 of §18 are built (rename+models, app-owned viewport, PDF-backed pages, horizontal pages + over-scroll gesture, text/images/copy-paste, lasso select-all-elements, backgrounds/navigator/attachments/redo, vector Syncfusion export). Phase 9 (perf pass) is pending — see `KNOWN_ISSUES.md` for the v1 scope cuts. Decisions resolved at build time: Syncfusion approved (Community License); input map = stylus+mouse draw / touch pan / wheel scroll (Ctrl zoom, Shift horizontal) / touch double-tap fit; proposed defaults in §20 accepted as-is; also added beyond spec: mouse-wheel support (user request). Source of intent: `PAGE_BEHAVIOR_REQ.md`. Items marked **[CONFIRM]**/**[OPEN]** below record the original review questions and their proposed defaults, kept for history.

---

## 1. Goal

Replace today's two separate page modes ("blank drawing page" vs "PDF page") with **one uniform, Samsung-Notes-style scrollable canvas**. Inside a single Canvas the user can freely mix handwriting, typed text, images, and imported PDF pages; arrange sheets vertically (scroll) and horizontally (infinite-canvas feel); and export the whole thing to a real, high-fidelity PDF where annotations are baked in as **vector** content (the OneNote gap we want to beat).

---

## 2. Terminology (rename only; nav structure unchanged)

| New name | What it is | Current code symbol |
|---|---|---|
| **Notebook** | Top-level collection | `Notebook` (unchanged) |
| **Section** | The document you open from a notebook | `Page` → **rename to `Section`** |
| **Canvas** | The scrollable surface of a Section | `PageScreen` → **rename to `CanvasScreen`** |
| **Page** | A single sheet **inside** a Canvas (new concept) | *(new)* `CanvasPage` |
| **Row** | A horizontal band of one-or-more pages inside a Canvas | *(new)* `PageRow` |
| **Element** | A drawn/typed/placed item on a page (stroke, text, image) | *(new)* |

**[CONFIRM]** This is a pure rename of `Page`→`Section` / `PageScreen`→`CanvasScreen` plus the new in-canvas `Page` concept. The Notebook → Section list screens keep working as they do today; only the Canvas (screen 3) is rebuilt. No new navigation level is added.

---

## 3. Mental model

- A **Canvas** is an ordered, vertically-stacked list of **Rows**.
- Each **Row** is an ordered, left-to-right list of **Pages** (usually 1; more when the user extends horizontally).
- Each **Page** is a fixed-size sheet with a background (color + pattern) and a stack of **Elements** (strokes, text, images). A page's background may also be **one page of an imported PDF** ("PDF-backed page").
- The user pans/zooms freely over the whole laid-out canvas (app-owned viewport). Vertical scrolling moves between rows; horizontal scrolling reveals a row's extra pages.
- **Export rule:** each **Row** becomes **one PDF page**. A single-page row exports at page size; a multi-page (horizontally extended) row **merges into one wide landscape PDF page**. All content is emitted as vector.

```
Canvas
├─ Row 0 ─ [Page]                         → 1 portrait PDF page
├─ Row 1 ─ [PDF page 1]                    → 1 PDF page (original vector bg + vector ink)
├─ Row 2 ─ [PDF page 2]                    → 1 PDF page
├─ Row 3 ─ [Page][Page][Page]              → 1 wide landscape PDF page (3 merged)
└─ Row 4 ─ [Page]                          → 1 portrait PDF page
```

---

## 4. Data model

Designed so (a) autosave rewrites only what changed, (b) export is a straight walk of the structure, and (c) everything maps cleanly to PDF.

### 4.1 Units & coordinates
- **[CONFIRM]** All geometry stored in **PDF points** (1 pt = 1/72"). Default page = **A4 portrait, 595 × 842 pt**. This makes vector export a ~1:1 mapping.
- Each **Page** has its own local coordinate space `(0,0)`–`(w,h)`. Element positions/strokes are stored in page-local points.
- The **Canvas** computes a layout: rows stacked top→down with a gap; pages within a row placed left→right with a gap. Page canvas-space rects derive from sizes + gaps.
- The **viewport** is an app-owned `Matrix4` (pan + zoom) over canvas space — see §6.

### 4.2 Entities

```
Notebook        { id, name, createdAt, sectionIds[] }          # pageIds renamed → sectionIds
Section         { id, notebookId, name, createdAt,
                  defaultPageSize, defaultBackground,
                  rows: [Row], attachments: [Attachment] }
Row             { id, pageIds: [String] }                       # order = horizontal order
Page            { id, size:{w,h}, background:{color, pattern},
                  source: null | { assetId, pdfPageIndex },     # PDF-backed if set
                  elements: [Element] }                          # z-order = list order
Attachment      { id, name, assetId, mime, addedAt }            # PDF/file added "as attachment"
```

### 4.3 Elements (polymorphic, `type` discriminator, `z` = paint order)

```
StrokeElement   { type:"stroke", z, tool:"pen"|"highlighter",
                  color, size, points:[{x,y,p}] }               # page-local pts, p=pressure
TextElement     { type:"text", z, rect:{x,y,w,h}, rotation,
                  text, fontFamily, fontSize, color,
                  bold, italic, align }
ImageElement    { type:"image", z, rect:{x,y,w,h}, rotation, assetId }
```

### 4.4 On-disk layout (per-page files → cheap autosave)

```
<app docs>/
  notebooks.json                                    # notebook index (sectionIds)
  notebooks/<notebookId>/sections/<sectionId>/
    section.json                                    # Section minus page bodies: name, rows[], defaults, attachments
    pages/<pageId>.json                             # one Page (background, source ref, elements) per file
    assets/<sha>.<ext>                              # content-addressed imported PDFs & images (dedup by hash)
```

- Editing a page rewrites only `pages/<pageId>.json`. Adding/reordering/deleting pages rewrites `section.json`.
- Imported PDFs and pasted images are copied into `assets/` once (by content hash) and referenced by `assetId`; multiple PDF-backed pages share the one PDF file.
- **[CONFIRM]** Keep the existing "full read-modify-write JSON, no DB" approach (per the current architecture), just scoped per-page so writes stay small. A future move to SQLite is out of scope.

---

## 5. Page types & backgrounds

- **Page kinds:** *blank* (no `source`) or *PDF-backed* (`source` points at an imported PDF page). Both behave identically for drawing/typing/images on top.
- **Background color:** per page; picker with a small preset palette + custom. **[CONFIRM]** presets: white, cream/paper, light grey, black, and a dark charcoal.
- **Background pattern / design:** **[CONFIRM]** offer **Blank, Ruled (lines), Grid, Dotted**. (Optional later: Cornell, isometric, music staff.)
- Each Section has a **default page size + default background** applied to newly added blank pages; changeable per page afterwards.
- PDF-backed pages take their size from the source PDF page; pattern defaults to Blank (the PDF is the background) but color/pattern can still be layered if desired. **[OPEN]** allow patterns on PDF pages, or force Blank?

---

## 6. Canvas layout & viewport (the core architectural change)

Today pdfrx owns the pan/zoom camera and ink merely follows it (see `CLAUDE.md` → Drawing). That inverts for this feature:

- Introduce a single **app-owned viewport transform** (one `Matrix4` via a `TransformationController`, likely inside an `InteractiveViewer` or a custom gesture layer). Both the page backgrounds **and** the ink/element layers render *under* this shared transform, as equal citizens.
- **pdfrx is demoted** from interactive viewer to a **page renderer**: we render a single PDF page to an image/texture at a resolution appropriate to the current zoom, and use it as that page's background. pdfrx's own gestures are not used. **[OPEN — needs a spike]** confirm pdfrx's single-page render API (e.g. `PdfPage.render`) gives us what we need at good quality/perf; fallback is another renderer.
- **Input routing** (generalizes today's stylus-vs-touch split): stylus = draw/erase/select; one finger on empty space or two fingers = pan; pinch = zoom. Stylus events convert screen→canvas (inverse viewport) → hit-test the page under the point → convert to page-local coords.
- **Zoom limits** **[CONFIRM]** ~25%–800%, with double-tap-to-fit-width.
- **Performance:** one `RepaintBoundary` per page; cull pages outside the viewport; cache rendered PDF-page bitmaps and re-render on significant zoom change. (See §14.)

---

## 7. Tools & interactions

### 7.1 Drawing (exists, carried over)
- **Pen** (pressure-thinned), **Highlighter** (translucent, wide, untapered), **Eraser** (whole-stroke; hold S-Pen side button to erase anytime). **[CONFIRM]** keep whole-stroke erase for v1; partial/pixel erase is a later option.

### 7.2 Lasso select — **all elements** (new)
- Draw a freehand lasso; everything whose geometry intersects it (strokes, text, images) is selected.
- Selection shows a bounding box with handles: **move**, **resize** (corner, with **[CONFIRM]** shift/aspect-lock for images), **rotate**.
- Selection context actions: **delete, duplicate, copy, cut, bring to front / send to back**, and **change color / stroke size** for selected strokes; **font controls** for selected text.
- **[OPEN]** Selection is confined to a single page (can't select across page boundaries) for v1 — confirm acceptable.

### 7.3 Text (new)
- Text tool → tap to drop a text box, type via the on-screen/hardware keyboard. Tap existing text to edit; drag/resize/rotate like any element.
- Controls: font family (**[CONFIRM]** a small curated set), size, color, bold, italic, alignment.
- **[CONFIRM]** No handwriting-to-text recognition in v1.

### 7.4 Images (new)
- Insert from **gallery, camera, file, or clipboard paste**. Place, move, resize, rotate. Stored in `assets/` and referenced.
- **Layering:** newly inserted/pasted images land **beneath the ink layer** (above the page background/pattern, below strokes) so you can annotate on top of them; `CanvasController.addImageBelowInk` sets the image's `zIndex` just below the lowest stroke z. "Bring to front" / "Send to back" still override this per-selection.

### 7.5 Copy / paste (new)
- **Internal clipboard** for element selections (paste at viewport center, offset slightly).
- **System clipboard** interop (implemented, full fidelity): paste external **images**, **rich HTML text** (formatting preserved — see below), and plain text; copy out images (lossless single image / rendered PNG) and text (**HTML + plain together**, so rich targets keep formatting).
- **Rich text paste (implemented 07/08/26):** clipboard HTML from browsers/Word/OneNote → styled `TextRun`s via `lib/utils/html_text.dart`. Kept: bold/italic/color/size/family (tags + inline CSS), headings, line/paragraph breaks, ul/ol as plain-glyph list prefixes (numbered, nested-indented), collapsed whitespace. Degraded: tables → space-separated cells. Dropped: images inside the HTML, scripts/styles. PDF export draws text **per styled run**, so exports match.
- **Long pastes split across pages (implemented 07/08/26):** text (rich or plain) taller than the target page splits at line boundaries into **linked** continuation boxes, each on its own new page — appended to the right when pasting on a page in a horizontal row, else as new rows below; one undo. Lasso any part → "Cut all parts" (re-paste re-flows elsewhere = move) / "Delete all parts". Typing into a box can still outgrow the page — split applies at paste time only.

### 7.6 Removed
- **Delete the "Clear page" button** — redundant now (undo + eraser + selection-delete cover it).

---

## 8. Adding pages & PDFs (organized menus + gestures)

All of this lives behind a clean, well-structured **"Add / Insert" menu** on the Canvas (a single entry that opens a grouped sheet), plus gestures for the common cases.

### 8.1 Add a page (vertical)
- **Add blank page:** *above current*, *below current*, or *at end of section*.
- New blank page uses the Section's default size + background.

### 8.2 Extend horizontally (infinite-canvas feel)
- **Add horizontal page** to the current row (same size as the row's origin page).
- **Gesture:** like Samsung Notes — when scrolled to a row's right edge, an **aggressive over-scroll** reveals an "＋ add page" affordance; releasing adds a same-size page to that row. Also available from the menu.
- Horizontal pages stay **the same size** as their origin page and are what merge into a landscape page on export.

### 8.3 Insert a PDF
When importing a PDF, a chooser offers:
- **Insert with view** — each PDF page becomes a **PDF-backed page** (rows) that can be annotated. Placement submenu: **at top / above current / below current / at bottom**. Rule from the notes: a PDF never shares a partially-used blank page — **its pages always start on their own new page(s) below** the insertion point.
- **Add as attachment** — the file is stored in the Section's attachments (not rendered into the canvas); see §9.

**[CONFIRM]** Menu grouping:
```
Add ▾
 ├─ Blank page ▸ (Above · Below · End)
 ├─ Horizontal page (to this row)
 ├─ Insert PDF ▸ (With view ▸ Top·Above·Below·Bottom  |  As attachment)
 ├─ Text box
 ├─ Image ▸ (Gallery · Camera · File · Paste)
 └─ Page settings ▸ (Background color · Pattern · Size)
```

---

## 9. Attachments

- A Section-level list of files added "as attachment" (PDFs today; any file later).
- Shown in a dedicated **Attachments** panel/sheet on the Canvas; tapping opens a read-only viewer or the system handler.
- **[OPEN]** On export, are attachments (a) ignored, (b) appended as extra PDF pages, or (c) embedded as PDF file-attachments? Proposed default: **(a) ignored** for v1, listed in the UI only.

---

## 10. PDF export (vector background + vector ink)

Chosen fidelity: **keep imported PDF pages as their original vector content and lay annotations over them as real vector PDF content** (selectable text preserved, smallest files, annotations truly baked in).

### 10.1 Mapping rules
- **One Row → one PDF page.**
- Single-page row → PDF page at that page's size/orientation.
- Multi-page row → **merged landscape page**, width = sum of page widths (+ inter-page gap **[CONFIRM]** gap included or flush), height = max page height; each page's content drawn at its horizontal offset.
- **PDF-backed page:** the original PDF page is drawn as the background (as a vector template/imported page), then elements are drawn on top.
- **Blank page:** a fresh vector page; background pattern **[OPEN]** drawn into the export or omitted (proposed: omit patterns, keep only user content + solid bg color).

### 10.2 Element → PDF
- **Stroke:** `perfect_freehand` already produces a filled outline polygon per stroke → emit as a filled vector **path** (preserves pressure-varied width). Highlighter → same path with alpha.
- **Text:** emit as PDF text (selectable) with font/size/color; rotation via transform.
- **Image:** embed the asset, placed/rotated per its rect.

### 10.3 Library
- **[OPEN — key decision]** Vector import-page + draw-on-page + create-new-page is realistically served by **`syncfusion_flutter_pdf`** (load existing PDF, use pages as templates, draw paths/text/images, save). It’s capable but its **Community License** has eligibility terms and requires a registered key. Alternatives: the `pdf` (DavBfr) package creates vector PDFs well but is weak at *re-importing existing PDF pages as vector*; commercial SDKs (PSPDFKit, etc.) are paid.
  - **Recommendation:** prototype with Syncfusion behind a thin `PdfExporter` interface so the library can be swapped. Confirm licensing is acceptable **before** committing.
- **Export scope:** **[CONFIRM]** whole Section by default; also allow *selected rows/pages* and *current page*.
- **After export:** share-sheet / save-to-file (and later, upload to the planned Google Drive).

---

## 11. Undo / redo

- Proper **undo *and* redo** stack (redo is implied but doesn't exist today).
- Covers: add/erase strokes, element move/resize/rotate, text edits, image add/remove, page add/delete/reorder, background changes.
- **[CONFIRM]** Model as a command/operation history per Section; **[OPEN]** depth limit (e.g., 100 ops) and whether history persists across app restarts (proposed: in-memory only, cleared on close).

---

## 12. Navigation aids (implied, for many pages)

- **[CONFIRM]** A **page navigator** (thumbnail strip or grid) to jump between pages/rows, plus a page counter. Optional minimap for horizontally-extended rows.
- Reorder / delete / duplicate pages from the navigator.

---

## 13. UI & layout changes on the Canvas

- Keep the current flat top toolbar language (Slate & Amber colors, hairline shapes) and hideable-toolbar behavior.
- Toolbar gains: tool group (pen/highlighter/eraser/**lasso**/**text**), color+size, and an **Add/Insert** menu (§8) and **Export** action.
- App bar: keep **Undo** + add **Redo**; **remove Clear-page**; keep the tools-hide toggle; add **overflow menu** (Export, Page navigator, Attachments, Section settings).
- Everything grouped so the bar stays clean at phone width (overflow into menus rather than crowding).

---

## 14. Performance considerations

- Per-page `RepaintBoundary`; viewport culling (only build/paint pages intersecting the viewport + margin).
- Cache rendered PDF-page bitmaps keyed by (assetId, pageIndex, zoom bucket); re-render on big zoom changes only.
- Strokes: consider a per-page cached picture for committed strokes, repainting only the in-progress stroke live (today's painter repaints everything every frame — fine for one page, not for many).
- Autosave debounced and scoped to the changed page file.

---

## 15. Persistence & autosave

- Per-page JSON (see §4.4). Autosave on: stroke commit, element transform end, text-edit commit, page structural change — **debounced** and writing only the affected `pages/<id>.json` or `section.json`.
- **[OPEN]** crash-safety (write-to-temp-then-rename) — proposed yes, since desktop kills mid-write are a known risk (already in `KNOWN_ISSUES.md`).

---

## 16. Migration

- **Fresh start** (chosen): the new model supersedes the old `Notebook`/`Page` data. On first run of the new build, old data is not migrated. **[CONFIRM]** either ignore old files or clear them; proposed: clear the old `notebooks/` layout to avoid confusion.

---

## 17. Non-goals for v1 (proposed)

Handwriting→text recognition; shape-recognition/snapping; rulers/guides; real-time collaboration; cloud sync (planned separately); partial/pixel eraser; cross-page multi-select; audio/video elements; PDF form-field editing.

### 17.1 Backlog — rich / structured text paste

**Implemented 07/08/26** (see §7.5): HTML→`TextRun[]` converter (`lib/utils/html_text.dart`), HTML-first system paste, HTML+plain copy-out, and per-run PDF text export — all shipped together as planned here.

**Implemented 07/11/26 — Markdown paste (option (a)):** `lib/utils/markdown_text.dart` — `looksLikeMarkdown` (strict detector in the plain-text paste branch; strong signals convert alone, weak ones need two kinds, ordinary prose never matches) + `runsFromMarkdown` (headings via the HTML converter's scale map, bold/italic with pragmatic CommonMark flanking rules, inline+fenced code as mono, bullet/numbered/task lists as the app's glyph prefixes — `- [ ]` makes the same tappable ☐ — links as `TextRun.link`, `│ `-prefixed italic blockquotes, hr as a divider line). One-way conversion (Notion model): the result is ordinary rich text.

**Still future:**
- **Markdown live input rules** (option (b), planned next): Notion-style as-you-type conversion (`# `, `- `, `[ ] `, `**bold**`) in `RichTextController`, with undo + backspace-right-after reverts.
- Richer HTML block layout (real tables, images inside pasted HTML, indent/quote styling) — deliberately out of scope for the inline-styling pass.

---

## 18. Phased implementation plan

Each phase is independently shippable/testable.

1. **Rename + model scaffold.** `Page`→`Section`, `PageScreen`→`CanvasScreen`; introduce `Section/Row/Page/Element` models + per-page storage; fresh-start data reset. Canvas still shows a single page (parity with today).
2. **App-owned viewport.** Replace pdfrx-driven camera with a shared `TransformationController`; render blank pages under it; port pen/highlighter/eraser to page-local coordinates. Multi-page vertical scrolling of blank pages.
3. **PDF-backed pages.** pdfrx as page renderer; insert-PDF-with-view flow + placement rules; annotate on top.
4. **Horizontal pages.** Row model in the UI; add-horizontal via menu + over-scroll gesture.
5. **Text + images + copy/paste.** Element transforms (move/resize/rotate); insert/paste.
6. **Lasso select (all elements)** + selection actions.
7. **Backgrounds** (color + patterns), page navigator, attachments panel; remove clear-page; redo.
8. **PDF export** (vector) behind `PdfExporter`; row→page + horizontal-merge mapping; share/save.
9. **Performance pass** (culling, caches) + crash-safe writes.

---

## 19. Open decisions to resolve before/at review

Highest-impact first:
1. **[OPEN] PDF export library + licensing** — OK to build on Syncfusion (Community License terms + key), or must we stay fully open-source (which likely forces rasterized export instead of vector for imported pages)?
2. **[CONFIRM] Terminology rename** mapping in §2.
3. **[CONFIRM] Default page size** A4 (595×842 pt) and **points** as the unit.
4. **[CONFIRM] Background patterns** set (Blank/Ruled/Grid/Dotted) and **color presets**.
5. **[OPEN] Patterns allowed on PDF-backed pages?**
6. **[OPEN] Selection confined to one page** in v1?
7. **[OPEN] Attachments in export** (ignore vs append vs embed).
8. ~~[OPEN] System-clipboard scope~~ — resolved beyond the original ask: images + rich HTML text + plain text, both directions (§7.5).
9. **[CONFIRM] Export scope** options (whole section / selected / current).
10. **[OPEN] Undo history** depth + persistence.

---

## 20. Proposed defaults summary (veto any at review)

| Area | Proposed default |
|---|---|
| Unit / page size | PDF points; A4 595×842 pt |
| Backgrounds | Blank / Ruled / Grid / Dotted; white/cream/grey/charcoal/black |
| Eraser | Whole-stroke (partial later) |
| Selection | Single page; all element types |
| Fonts | Small curated set; no handwriting recognition |
| Export | Vector; whole-section default; Syncfusion (pending licensing) |
| Attachments on export | Ignored (listed in UI only) |
| Undo/redo | In-memory, ~100 ops |
| Zoom | 25%–800%, double-tap fit-width |
| Storage | Per-page JSON files + content-addressed assets |
| Migration | Fresh start (clear old data) |
