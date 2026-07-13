//! OneNote section extractor.
//!
//! Walks .one section files with Joplin's OneNote parser and dumps everything
//! needed to rebuild the notes elsewhere:
//!   - extract.json — sections → pages → items (images, embedded files, ink,
//!     text) with positions and styles
//!   - assets/      — lossless image + embedded-file bytes
//!
//! Units (documented in the JSON `units` block):
//!   - layout offsets/sizes (pages, images, outlines): half-inch increments
//!   - ink stroke coordinates + widths: HIMETRIC (1/2540 inch)
//!   - font sizes: half-points
//!   - stroke color: Windows COLORREF (0x00BBGGRR); null = default (black)
//!
//! Usage: onenote_extractor <out_dir> <input.one | dir>...

use parser::contents::{Content, EmbeddedFile, Image, Ink, InkStroke, Outline, OutlineItem};
use parser::page::{Page, PageContent};
use parser::property::common::ColorRef;
use parser::property::rich_text::ParagraphStyling;
use parser::Parser;
use serde_json::{json, Map, Value};
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::exit;

struct AssetStore {
    dir: PathBuf,
    count: usize,
    written: Vec<Value>,
}

impl AssetStore {
    fn new(dir: PathBuf) -> std::io::Result<Self> {
        fs::create_dir_all(&dir)?;
        Ok(AssetStore {
            dir,
            count: 0,
            written: vec![],
        })
    }

    fn put(&mut self, bytes: &[u8], ext: &str, origin: &str) -> std::io::Result<String> {
        let name = format!("asset_{:04}.{}", self.count, ext.trim_start_matches('.'));
        self.count += 1;
        fs::write(self.dir.join(&name), bytes)?;
        self.written.push(json!({
            "name": name,
            "bytes": bytes.len(),
            "origin": origin,
        }));
        Ok(format!("assets/{}", name))
    }
}

fn sniff_image_ext(bytes: &[u8]) -> Option<&'static str> {
    if bytes.starts_with(&[0x89, b'P', b'N', b'G']) {
        Some("png")
    } else if bytes.starts_with(&[0xFF, 0xD8, 0xFF]) {
        Some("jpg")
    } else if bytes.starts_with(b"GIF8") {
        Some("gif")
    } else if bytes.starts_with(b"BM") {
        Some("bmp")
    } else if bytes.len() > 12 && &bytes[8..12] == b"WEBP" {
        Some("webp")
    } else {
        None
    }
}

fn ext_of(filename: &str) -> Option<String> {
    Path::new(filename)
        .extension()
        .map(|e| e.to_string_lossy().to_lowercase())
}

fn color_ref_json(c: Option<ColorRef>) -> Value {
    match c {
        Some(ColorRef::Manual { r, g, b }) => json!([r, g, b]),
        _ => Value::Null,
    }
}

fn style_json(text: &str, style: Option<&ParagraphStyling>) -> Value {
    let mut m = Map::new();
    m.insert("text".into(), json!(text));
    if let Some(s) = style {
        if s.bold() {
            m.insert("bold".into(), json!(true));
        }
        if s.italic() {
            m.insert("italic".into(), json!(true));
        }
        if s.underline() {
            m.insert("underline".into(), json!(true));
        }
        if let Some(size) = s.font_size() {
            m.insert("fontSizeHalfPt".into(), json!(size));
        }
        if let Some(font) = s.font() {
            m.insert("font".into(), json!(font));
        }
        let color = color_ref_json(s.font_color());
        if !color.is_null() {
            m.insert("colorRgb".into(), color);
        }
        let highlight = color_ref_json(s.highlight());
        if !highlight.is_null() {
            m.insert("highlightRgb".into(), highlight);
        }
        if let Some(id) = s.style_id() {
            m.insert("styleId".into(), json!(id));
        }
    }
    Value::Object(m)
}

/// Delta-decode a stroke path (first point absolute, rest deltas) into
/// absolute HIMETRIC coordinates.
fn stroke_json(s: &InkStroke) -> Value {
    let mut pts: Vec<Value> = Vec::with_capacity(s.path().len());
    let (mut x, mut y) = (0f64, 0f64);
    for (i, p) in s.path().iter().enumerate() {
        if i == 0 {
            x = p.x() as f64;
            y = p.y() as f64;
        } else {
            x += p.x() as f64;
            y += p.y() as f64;
        }
        pts.push(json!([x, y]));
    }
    json!({
        "widthHm": s.width(),
        "heightHm": s.height(),
        "penTip": s.pen_tip(),
        "transparency": s.transparency(),
        "colorRef": s.color(),
        "points": pts,
    })
}

/// Flatten an ink tree into items. Mirrors Joplin's renderer: the offsets used
/// for placement are the ones on the node that actually holds strokes.
fn collect_ink(ink: &Ink, embedded: bool, items: &mut Vec<Value>) {
    for child in ink.child_groups() {
        collect_ink(child, embedded, items);
    }
    let strokes = ink.ink_strokes();
    if strokes.is_empty() {
        return;
    }
    items.push(json!({
        "kind": "ink",
        "offsetXHalfIn": ink.offset_horizontal().unwrap_or(0.0),
        "offsetYHalfIn": ink.offset_vertical().unwrap_or(0.0),
        "embedded": embedded,
        "strokes": strokes.iter().map(stroke_json).collect::<Vec<_>>(),
    }));
}

fn image_json(
    image: &Image,
    assets: &mut AssetStore,
    pos: (Option<f32>, Option<f32>),
    embedded_in_outline: bool,
) -> Value {
    let mut bytes = Vec::new();
    let asset = match image.read() {
        Ok(Some(mut reader)) => {
            if reader.read_to_end(&mut bytes).is_ok() && !bytes.is_empty() {
                let ext = sniff_image_ext(&bytes)
                    .map(str::to_string)
                    .or_else(|| image.image_filename().and_then(ext_of))
                    .or_else(|| image.extension().map(|e| e.trim_start_matches('.').to_string()))
                    .unwrap_or_else(|| "png".into());
                assets
                    .put(&bytes, &ext, image.image_filename().unwrap_or("image"))
                    .ok()
            } else {
                None
            }
        }
        _ => None,
    };

    // Displayed size = natural picture_* size scaled down (aspect preserved)
    // to fit inside the layout_max_* constraint when it exceeds it — e.g. PDF
    // printout slides have picture 30×16.875 but display at max 20×11.25.
    let (disp_w, disp_h) = match (image.picture_width(), image.picture_height()) {
        (Some(w), Some(h)) if w > 0.0 && h > 0.0 => {
            let mut scale = 1.0f32;
            if let Some(mw) = image.layout_max_width() {
                if w > mw && mw > 0.0 {
                    scale = scale.min(mw / w);
                }
            }
            if let Some(mh) = image.layout_max_height() {
                if h > mh && mh > 0.0 {
                    scale = scale.min(mh / h);
                }
            }
            (Some(w * scale), Some(h * scale))
        }
        (w, h) => (
            w.or(image.layout_max_width()),
            h.or(image.layout_max_height()),
        ),
    };

    json!({
        "kind": "image",
        "xHalfIn": pos.0,
        "yHalfIn": pos.1,
        "wHalfIn": disp_w,
        "hHalfIn": disp_h,
        "naturalWHalfIn": image.picture_width(),
        "naturalHHalfIn": image.picture_height(),
        "filename": image.image_filename(),
        "pageNumber": image.displayed_page_number(),
        "altText": image.alt_text(),
        "embeddedInOutline": embedded_in_outline,
        "asset": asset,
    })
}

fn file_json(file: &EmbeddedFile, assets: &mut AssetStore, pos: (Option<f32>, Option<f32>)) -> Value {
    let mut bytes = Vec::new();
    let asset = match file.read() {
        Ok(mut reader) => {
            if reader.read_to_end(&mut bytes).is_ok() && !bytes.is_empty() {
                let ext = ext_of(file.filename()).unwrap_or_else(|| "bin".into());
                assets.put(&bytes, &ext, file.filename()).ok()
            } else {
                None
            }
        }
        _ => None,
    };

    json!({
        "kind": "file",
        "filename": file.filename(),
        "xHalfIn": pos.0,
        "yHalfIn": pos.1,
        "asset": asset,
    })
}

/// Per-outline walk state: collects paragraphs and flushes them (interleaved
/// with images/files, in document order) as sequenced flow items, so a
/// consumer can stack the outline's contents vertically the way OneNote laid
/// them out. `outline_seq` orders items within one `outline_id`.
struct OutlineFlow {
    outline_id: u64,
    seq: u32,
    paragraphs: Vec<Value>,
    pos: (Option<f32>, Option<f32>),
    max_width: Option<f32>,
}

impl OutlineFlow {
    fn flush_text(&mut self, items: &mut Vec<Value>) {
        // Trailing blank paragraphs carry no content and no layout meaning.
        while matches!(
            self.paragraphs.last().and_then(|p| p["runs"].as_array()),
            Some(runs) if runs.is_empty()
        ) {
            self.paragraphs.pop();
        }
        if self.paragraphs.is_empty() {
            return;
        }
        items.push(json!({
            "kind": "text",
            "xHalfIn": self.pos.0,
            "yHalfIn": self.pos.1,
            "maxWidthHalfIn": self.max_width,
            "outlineId": self.outline_id,
            "outlineSeq": self.seq,
            "paragraphs": std::mem::take(&mut self.paragraphs),
        }));
        self.seq += 1;
    }

    fn push_flow_item(&mut self, mut item: Value, items: &mut Vec<Value>) {
        self.flush_text(items);
        item["outlineId"] = json!(self.outline_id);
        item["outlineSeq"] = json!(self.seq);
        self.seq += 1;
        items.push(item);
    }
}

/// Walk an outline in document order: rich text accumulates as paragraphs;
/// images/files interrupt the text (flushing it) and take the next slot in
/// the outline's vertical flow. Ink is positioned absolutely and bypasses
/// the flow.
fn walk_outline_items(
    outline_items: &[OutlineItem],
    indent: u32,
    flow: &mut OutlineFlow,
    items: &mut Vec<Value>,
    assets: &mut AssetStore,
) {
    for item in outline_items {
        match item {
            OutlineItem::Group(group) => {
                walk_outline_items(group.outlines(), indent, flow, items, assets);
            }
            OutlineItem::Element(el) => {
                for content in el.contents() {
                    match content {
                        Content::RichText(text) => {
                            // Embedded handwriting inside a text line.
                            for obj in text.embedded_objects() {
                                if let parser::contents::EmbeddedObject::Ink(container) = obj {
                                    let mut ink_items = vec![];
                                    collect_ink(container.ink(), true, &mut ink_items);
                                    for mut it in ink_items {
                                        it["offsetXHalfIn"] = json!(flow.pos.0.unwrap_or(0.0));
                                        it["offsetYHalfIn"] = json!(flow.pos.1.unwrap_or(0.0));
                                        items.push(it);
                                    }
                                }
                            }

                            let runs: Vec<Value> = text
                                .text_segments()
                                .iter()
                                .filter(|seg| !seg.text().is_empty())
                                .map(|seg| {
                                    let mut v = style_json(seg.text(), seg.style());
                                    if let Some(link) = seg.hyperlink() {
                                        v["hyperlink"] = json!(link.href);
                                    }
                                    v
                                })
                                .collect();
                            let runs = if runs.is_empty() && !text.text().is_empty() {
                                vec![style_json(text.text(), Some(text.paragraph_style()))]
                            } else {
                                runs
                            };
                            // Blank paragraphs (empty runs) still occupy a
                            // line of vertical space in the flow.
                            flow.paragraphs.push(json!({
                                "indent": indent,
                                "runs": runs,
                                "styleId": text.paragraph_style().style_id(),
                            }));
                        }
                        Content::Image(image) => {
                            let item = image_json(image, assets, flow.pos, true);
                            flow.push_flow_item(item, items);
                        }
                        Content::EmbeddedFile(file) => {
                            let item = file_json(file, assets, flow.pos);
                            flow.push_flow_item(item, items);
                        }
                        Content::Ink(ink) => {
                            let mut ink_items = vec![];
                            collect_ink(ink, false, &mut ink_items);
                            items.append(&mut ink_items);
                        }
                        Content::Table(table) => {
                            for row in table.contents() {
                                for cell in row.contents() {
                                    let cell_items: Vec<OutlineItem> = cell
                                        .contents()
                                        .iter()
                                        .cloned()
                                        .map(OutlineItem::Element)
                                        .collect();
                                    walk_outline_items(
                                        &cell_items,
                                        indent + 1,
                                        flow,
                                        items,
                                        assets,
                                    );
                                }
                            }
                        }
                        Content::Unknown => {}
                    }
                }
                walk_outline_items(el.children(), indent + 1, flow, items, assets);
            }
        }
    }
}

fn outline_items(
    outline: &Outline,
    outline_id: u64,
    items: &mut Vec<Value>,
    assets: &mut AssetStore,
) {
    let mut flow = OutlineFlow {
        outline_id,
        seq: 0,
        paragraphs: vec![],
        pos: (outline.offset_horizontal(), outline.offset_vertical()),
        max_width: outline.layout_max_width(),
    };
    walk_outline_items(outline.items(), 0, &mut flow, items, assets);
    flow.flush_text(items);
}

fn collect_one_files(
    dir: &Path,
    group_path: &mut Vec<String>,
    out: &mut Vec<(PathBuf, Vec<String>)>,
) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    let mut entries: Vec<PathBuf> = entries.filter_map(|e| e.ok()).map(|e| e.path()).collect();
    entries.sort();
    for p in entries {
        if p.is_dir() {
            let name = p
                .file_name()
                .map(|n| n.to_string_lossy().to_string())
                .unwrap_or_default();
            if name == "OneNote_RecycleBin" {
                continue;
            }
            group_path.push(name);
            collect_one_files(&p, group_path, out);
            group_path.pop();
        } else if p
            .extension()
            .map(|e| e.to_string_lossy().eq_ignore_ascii_case("one"))
            .unwrap_or(false)
        {
            out.push((p, group_path.clone()));
        }
    }
}

fn unix_ms(t: time::UtcDateTime) -> i64 {
    (t.unix_timestamp_nanos() / 1_000_000) as i64
}

fn page_json(page: &Page, assets: &mut AssetStore, outline_counter: &mut u64) -> Value {
    let mut items: Vec<Value> = vec![];

    for content in page.contents() {
        match content {
            PageContent::Outline(outline) => {
                *outline_counter += 1;
                outline_items(outline, *outline_counter, &mut items, assets)
            }
            PageContent::Image(image) => {
                let pos = (image.offset_horizontal(), image.offset_vertical());
                items.push(image_json(image, assets, pos, false));
            }
            PageContent::EmbeddedFile(file) => {
                let pos = (file.offset_horizontal(), file.offset_vertical());
                items.push(file_json(file, assets, pos));
            }
            PageContent::Ink(ink) => collect_ink(ink, false, &mut items),
            PageContent::Unknown => {}
        }
    }

    json!({
        "title": page.title_text(),
        "level": page.level(),
        "author": page.author(),
        "createdMs": unix_ms(page.created_time()),
        "updatedMs": unix_ms(page.updated_time()),
        "heightHalfIn": page.height(),
        "items": items,
    })
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.len() < 2 {
        eprintln!("Usage: onenote_extractor <out_dir> <input.one | dir>...");
        exit(1);
    }

    let out_dir = PathBuf::from(&args[0]);
    fs::create_dir_all(&out_dir).expect("cannot create output dir");

    // Each input is (path, groupPath): groupPath is the chain of section-group
    // folder names between the scan root and the .one file (OneNote packages
    // store section groups as subdirectories).
    let mut inputs: Vec<(PathBuf, Vec<String>)> = vec![];
    for arg in &args[1..] {
        let p = PathBuf::from(arg);
        if p.is_dir() {
            collect_one_files(&p, &mut vec![], &mut inputs);
        } else {
            inputs.push((p, vec![]));
        }
    }
    if inputs.is_empty() {
        eprintln!("No .one files found in the given inputs.");
        exit(1);
    }

    let mut assets = AssetStore::new(out_dir.join("assets")).expect("cannot create assets dir");
    let mut sections: Vec<Value> = vec![];
    let mut had_errors = false;
    let mut outline_counter: u64 = 0;

    for (input, group_path) in &inputs {
        let input_str = input.to_string_lossy().to_string();
        eprintln!("Parsing {}", input_str);
        let mut parser = Parser::new();
        match parser.parse_section(&input_str) {
            Ok(section) => {
                let mut pages: Vec<Value> = vec![];
                for series in section.page_series() {
                    for page in series.pages() {
                        pages.push(page_json(page, &mut assets, &mut outline_counter));
                    }
                    if series.has_errors() {
                        for err in series.errors() {
                            eprintln!("  warning: {}", err);
                        }
                    }
                }
                sections.push(json!({
                    "name": section.display_name(),
                    "sourceFile": input.file_name().map(|n| n.to_string_lossy().to_string()),
                    "groupPath": group_path,
                    "pages": pages,
                }));
            }
            Err(err) => {
                had_errors = true;
                eprintln!("  ERROR parsing {}: {}", input_str, err);
                sections.push(json!({
                    "name": input.file_stem().map(|n| n.to_string_lossy().to_string()),
                    "sourceFile": input.file_name().map(|n| n.to_string_lossy().to_string()),
                    "groupPath": group_path,
                    "error": err.to_string(),
                    "pages": [],
                }));
            }
        }
    }

    let doc = json!({
        "generator": "onenote_extractor 0.1.0",
        "units": {
            "layout": "half-inch increments (× 36 = PDF points)",
            "ink": "HIMETRIC, 1/2540 inch (× 72/2540 = PDF points); points are absolute after delta-decode",
            "fontSize": "half-points",
            "colorRef": "Windows COLORREF 0x00BBGGRR (r = v & 0xFF); null = default ink color",
            "penTip": "0/null = round (pen), 1 = rectangle (highlighter)",
            "transparency": "0 = opaque … 255 = invisible; opacity = (255 - t) / 255"
        },
        "sections": sections,
        "assets": assets.written,
    });

    let json_path = out_dir.join("extract.json");
    fs::write(&json_path, serde_json::to_vec_pretty(&doc).unwrap()).expect("cannot write extract.json");

    // Same data as a JS global, so preview.html works over file:// (fetch of
    // local JSON is blocked by browsers).
    let mut js = b"window.EXTRACT = ".to_vec();
    js.extend_from_slice(&serde_json::to_vec(&doc).unwrap());
    js.extend_from_slice(b";\n");
    fs::write(out_dir.join("extract.js"), js).expect("cannot write extract.js");
    eprintln!(
        "Wrote {} ({} sections, {} assets)",
        json_path.display(),
        sections.len(),
        assets.count
    );
    if had_errors {
        exit(2);
    }
}
