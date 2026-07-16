# Shape Tools — Implementation Plan

Status (07/16/26): **ALL phases landed** on `feature-shape-tools` — hold-to-snap +
adjust-while-holding (P1), the drag-to-draw Shapes tool (P2), the custom shape library (P3), and
non-uniform stretch/squash resize via side handles (P4). Summary now lives in `CLAUDE.md`'s
Shape-tools bullet. Not yet device-tuned — `ShapeTuning` in `shape_recognizer.dart` is the single knob block.
Original scope: hold-to-snap recognition, curve smoothing, predefined-shapes tool, custom shape
library, non-uniform resize. On shipping Phase 4, fold into `CLAUDE.md` + `CANVAS_SPEC.md` and log
limitations in `KNOWN_ISSUES.md`.

---

## 0. Foundational decision — shapes are ordinary `StrokeElement`s

A recognized/placed shape is committed as a normal `StrokeElement` whose `points` happen to be
mathematically perfect. **No new `CanvasElement` subtype, no schema change, no MergeEngine
change.** This is the load-bearing choice that keeps sync/export/eraser intact:

| Concern | Why it's free with points-based shapes |
|---|---|
| Sync merge | `MergeEngine.mergePage` unions strokes by id **rev-aware** (`merge_engine.dart` ~330: same-id stroke resolved by `wins(rev, updatedAt, deviceId)`) — verified, not assumed. A shape stroke merges like any ink. |
| Delete/undo across devices | Existing rev-based tombstones (`_tombstoneFor` / `_bumpAliveOn`, `canvas_controller.dart:1936/1951`) apply unchanged. |
| PDF export | Strokes already export as vector `perfect_freehand` fill paths (incl. isolate path + `placedText` plumbing). Nothing to add. |
| Eraser (whole + partial) | Partial eraser splits point runs — works on shape strokes with zero changes. |
| Lasso / move / rotate / uniform scale / cross-page reparent | All operate on `points` via `translate/scaleBy/rotateBy` — unchanged. |
| Picture cache | Committed shapes ride `_markDirty` invalidation like any op. |
| Persistence | `toJson`/`fromJson` untouched; a page written by a build **without** this feature reads a shape stroke as plain ink (perfect forward/backward compat — old devices just see ink). |

**Deliberately given up:** post-hoc *semantic* editing (dragging one rectangle corner later and
keeping right angles). That would need a parametric `ShapeElement` — a sealed-subtype addition
touching painter, `_lassoHits`, `applyColorToSelection`, `pdf_exporter`, the objects-LWW merge
bucket, and eraser exclusions. Rejected: cost/benefit is wrong for a note app (Samsung Notes
shapes aren't re-editable either). If ever revisited, it is a separate plan.

**Consequence for shape identity:** nothing on disk marks a stroke as "a shape". That is fine —
no feature below requires it. (If Phase 4's side handles ever want to show only for "shapey"
selections, detect via geometry heuristics at selection time, not via schema.)

---

## 1. Phase 1 — Hold-to-snap (recognize while pen is held down)

### 1.1 UX contract

1. User draws with pen; pauses **without lifting** for ~450 ms within a small slop.
2. Recognizer runs on the in-progress points. **Confident match** → the live stroke's points are
   replaced with the perfect shape (preview), haptic tick on Android. **No confident match →
   nothing happens** (pausing mid-thought is safe; no visual flicker, recognizer may re-arm).
3. While still down, **moving the pen adjusts the shape**: the nearest anchor follows the pen —
   line: nearest endpoint; rect/polygon: nearest corner (opposite corner pinned → natural
   stretch/squash at creation); circle: radius; ellipse: nearest axis extremum; smoothed curve:
   nearest endpoint.
4. Lift commits. **Undo #1 restores the original freehand ink; undo #2 removes the stroke**
   (Apple Notes semantics).
5. Feature is behind a device-local toggle **"Snap drawn shapes"** (default ON), in the canvas
   overflow menu next to "Draw with finger". Pen tool only in v1 (not highlighter — highlighter
   shapes can be a later flag).

Shapes recognized in v1: **straight line** (with 0/45/90° angle snap), **rectangle**
(axis-aligned snap, else oriented quad with straightened edges), **triangle**, **N-gon (N ≤ 8,
regular-snap when near-regular)**, **circle**, **ellipse** (axis-aligned + rotated via
covariance), **smooth open curve** (Catmull-Rom refit). **Arrow** is a stretch goal (open
polyline, V-head at the end) — keep the classifier slot but ship without it if tuning drags.

### 1.2 New module: `lib/canvas/shape_recognizer.dart` (pure Dart, fully unit-testable)

No controller/painter imports; operates on page-local geometry. API sketch:

```dart
enum ShapeKind { line, arrow, triangle, rectangle, polygon, circle, ellipse, curve }

class ShapeFit {
  final ShapeKind kind;
  final double confidence;            // 0..1, already thresholded by recognize()
  final List<Offset> vertices;        // line/arrow/triangle/rect/polygon (closed implied by kind)
  final Offset center; final double rx, ry, rotation;   // circle/ellipse
  final List<Offset> controlPoints;   // curve (Catmull-Rom through decimated points)
}

/// null = not confident / too complex ("intent is random") / too short.
ShapeFit? recognizeShape(List<StrokePoint> raw);

/// Emits render-ready points: ~2–3 pt spacing on edges/arcs, constant pressure
/// (see 1.5), corners emitted as a tight cluster (see corner-fidelity risk, §6).
List<StrokePoint> pointsForShape(ShapeFit fit);

/// Anchor model for hold-drag adjust (pure, so it's testable):
int nearestAnchorIndex(ShapeFit fit, Offset p);
ShapeFit moveAnchor(ShapeFit fit, int anchor, Offset to);
```

Pipeline inside `recognizeShape`:

1. **Gate**: path length < ~24 pt or < 8 raw points → null.
2. **Resample** to N ≈ 96 equidistant samples.
3. **Closed test**: endpoint gap < max(0.12 × pathLen, 12 pt).
4. **Corner detection**: ShortStraw/IStraw-style curvature scan → corner list.
5. **Classify + fit** (each fitter returns a residual-based confidence; take best above
   threshold):
   - open, 0–1 corners, low chord deviation → **line** (snap angle to 0/45/90 within ~6°).
   - closed, 3/4/N corners → **triangle/rect/polygon**: straighten edges by least-squares;
     rect snaps axis-aligned when all edges within ~8° of axes; near-regular N-gons snap
     regular.
   - closed, ~0 corners → **circle** (low radial variance about centroid) else **ellipse**
     (second-moment covariance eigenvectors give axes + rotation).
   - open, ≤ 2 corners, **complexity bail-outs pass** → **curve**: Ramer-Douglas-Peucker
     decimation (generous ε) → Catmull-Rom through kept points.
6. **Complexity bail-outs** (the "user intent is random" guard — return null): self-intersection
   count > 0 for open curves, direction reversals above threshold, > 8 corners, or all
   confidences below threshold.

All tolerances live in one `const ShapeTuning` block — the tuning tail (§6) edits one place.

### 1.3 `CanvasController` changes (`lib/canvas/canvas_controller.dart`)

New state (near `activeStroke`, ~line 749):

```dart
Timer? _holdTimer;
Offset? _holdAnchor;                 // page-local position the slop is measured from
List<StrokePoint>? _preSnapPoints;   // freehand backup for the undo-to-freehand op
ShapeFit? _snappedFit;               // non-null = snapped, adjust mode active
int? _adjustAnchor;                  // grabbed anchor after first post-snap move
```

Hook points (all inside the existing pen case — **no switch shape changes**):

- `startToolGesture` (~831, pen/highlighter case): if tool == pen && `SettingsService().shapeSnap`,
  arm `_holdTimer` (450 ms) and set `_holdAnchor`.
- `updateToolGesture` (~873, pen case):
  - **not snapped**: append point as today; if the new point is farther than the slop from
    `_holdAnchor` (slop = `kHoldSlopPx / zoom`, doubled when the gesture came from a finger —
    plumb a `fromTouch` flag from the screen's pointer-down, same place `fingerDraw` routing
    already lives), reset the timer + re-anchor. Stylus micro-jitter stays under slop, so the
    timer survives it.
  - **snapped** (`_snappedFit != null`): do **not** append; first move ≥ small threshold sets
    `_adjustAnchor = nearestAnchorIndex(...)`, then each move does
    `_snappedFit = moveAnchor(...)`, regenerates `activeStroke.points = pointsForShape(...)`,
    `invalidateCache()`, `notifyListeners()`. (Active stroke is painted directly per frame —
    `canvas_painter.dart:149` — so preview costs nothing new.)
- **Timer fire** `_onHoldFired()`: guard `_activeGestureTool == pen && activeStroke != null &&
  _snappedFit == null`; run `recognizeShape(activeStroke.points)`; on success store
  `_preSnapPoints = List.of(points)`, swap in generated points, invalidate, haptic
  (`HapticFeedback.mediumImpact()` — controller already imports services via clipboard paths),
  `notifyListeners()`. On failure: **re-arm once** (a second, longer pause can retry after more
  ink), then stop retrying for the gesture. Timer fires between frames → notifying is safe
  (never during build; `setScreenSize` rule doesn't apply here).
- `endToolGesture` (~910, pen case): cancel timer. If **not** snapped → exactly today's
  single `_addElementsOp('Draw', …)`. If snapped → the **two-op commit** (1.4).
- `cancelToolGesture` (~932): cancel timer, clear all five fields (a second finger cancelling a
  finger-draw stroke into a pan must also kill a pending/active snap).
- `dispose`: cancel timer.

### 1.4 Commit + undo-to-freehand (two ops, sync-safe)

At pen-up when snapped (shape points are currently live in the stroke instance):

```dart
final shapePoints = stroke.points;
stroke.points = _preSnapPoints!;           // op1 must conceptually add the FREEHAND stroke
stroke.invalidateCache();
_doOp(_addElementsOp('Draw', pageId, [stroke]));      // op1: add (revive/tombstone by id)
_doOp(_swapPointsOp('Shape', pageId, stroke, before: _preSnapPoints!, after: shapePoints));
```

`_swapPointsOp` follows the existing replace-op pattern (`applyColorToSelection` /
`adjustInkForContrast` shape): apply = write `after` points into the live element + `_stamp`
(canvas_controller.dart:1415) + `pictureCache` rides `_markDirty`; revert = write `before` +
`_stamp`. Both ops run in one synchronous frame, so the intermediate freehand state never
paints, and the 500 ms debounced save only ever flushes the final state.

**Why this is sync-correct** (the invariants from CLAUDE.md, checked one by one):

- *"every element-mutating op commit must `_stamp`"* — `_swapPointsOp` stamps on apply **and**
  revert, so rev climbs monotonically across undo↔redo; a same-id stroke with different points
  resolves by rev in `mergePage`'s union (verified rev-aware). Undo **after** a flush uploads a
  higher-rev freehand copy that beats the shape copy everywhere. ✔
- *"every removal writes a tombstone in the same op"* — op1's revert is `_tombstoneSlots`
  (tombstone + physical remove), op1's re-apply is `_reviveSlots` (`_bumpAliveOn` out-revs the
  tombstone). Both are the existing helpers; nothing new. ✔
- Ops snapshot **copies** of the point lists (`List<StrokePoint>` deep-copied point-wise),
  never live refs — the op-correctness rule. ✔
- No new file kinds, no envelope change, no `MergeEngine` change, no `savePage` path change
  (commit rides `_afterMutation` → `_markDirty` → debounced save → journal → upload). ✔
- Live remote merge (`applyRemotePage`) can race an open gesture exactly as it can race normal
  drawing today — the active stroke isn't in `page.strokes` until commit, so no new hazard. ✔

Two undo entries for one user action is deliberate (undo #1 = un-snap) — document it in
`CANVAS_SPEC.md` when shipping.

### 1.5 Generated-point quality (rendering through `perfect_freehand`)

- Constant pressure `p = 0.5` on all generated points → `thinning: 0.6` yields uniform width.
- Edge/arc spacing ~2–3 pt (page points, not screen px) — dense enough that
  `streamline: 0.6` input smoothing doesn't visibly bow long straight edges.
- **Corners**: emit a tight cluster (the corner point repeated ~3× plus near-neighbors at
  ~0.5 pt) so both the input streamlining *and* the outline smoothing
  (`CanvasPainter._smoothOutlinePath`, painter ~324; mirrored by the exporter's
  `_smoothStrokeOutline`) pin the outline at the vertex. Slight residual rounding is
  **accepted** — it reads as "hand-drawn perfect", matching Samsung Notes. See §6 for the
  fidelity spike that de-risks this first.

### 1.6 Settings + UI

- `SettingsService`: `bool shapeSnap = true` + `setShapeSnap(bool)` — copy the `fingerDraw`
  pattern exactly (field, guard, persist key, `_load` read with `!= false` default-true).
- Canvas overflow menu (both `embedded` and mobile sheet variants): "Snap drawn shapes"
  check row beside "Draw with finger".
- Haptic on snap (Android; harmless no-op on desktop).

### 1.7 Tests (`test/shape_recognizer_test.dart`, `test/shape_snap_test.dart`)

- Recognizer: synthetic noisy inputs (jittered rects/circles/lines/triangles at several sizes
  + rotations) → correct kind + fitted params within tolerance; prose-like scribbles,
  self-crossing doodles, spirals → **null** (the "random intent" bail); angle-snap behavior;
  closed-vs-open edge cases; `moveAnchor`/`nearestAnchorIndex` semantics per kind.
- Controller (in-memory, mind the 500 ms autosave rule — never await past the debounce):
  simulate start/update/hold-fire/end; assert two-op stack; undo #1 → freehand points,
  undo #2 → stroke tombstoned; redo chain; rev strictly climbs across the whole
  undo↔redo cycle; `cancelToolGesture` mid-snap leaves no timer/state.
- Merge: one `merge_engine_test.dart` addition — same-id stroke, device A has shape points at
  rev r+1, device B has freehand at rev r → shape wins both directions (locks the rev-aware
  union this feature depends on).

**Effort: ~2–4 focused days + on-device tuning tail.**

---

## 2. Phase 2 — Predefined shapes tool

### 2.1 UX

A 6th tool in the toolbar (icon: shapes/square-circle glyph). Options row (via the existing
re-tap → `toolOptionsOpen` gating, `setTool` at canvas_controller.dart:487) shows a shape-kind
chip row: line / arrow / rect / ellipse / triangle / star / N-gon — plus Phase 3's custom
templates. Pointer-down anchors a corner, drag pulls the opposite corner (vector-editor style,
inherently non-uniform), live preview via `activeStroke`, lift commits. Uses the pen's current
color/size. Desktop: holding **Shift** constrains to square/circle
(`HardwareKeyboard.instance.logicalKeysPressed` at gesture time). Last-used kind persists
device-local (`SettingsService.shapeToolKind`).

### 2.2 Touch points (adding `CanvasTool.shape` — the compiler flags every site)

- `canvas_controller.dart:23` enum + the three gesture switches (`startToolGesture` /
  `updateToolGesture` / `endToolGesture`): new case — store drag origin, regenerate
  `activeStroke.points = pointsForShape(...)` per move (clamped to the page via the existing
  `_clampToPage`), commit as **one** `_addElementsOp('Shape', …)` (no two-op — there's no
  freehand to restore). Reuses Phase 1's `pointsForShape` generators wholesale.
- `kCanvasToolOrder` (screen) + `_ToolIconButton` icon mapping + `_buildToolContextRow`
  (canvas_screen.dart:2477): new options row. Keep it inside the `TextFieldTapRegion`-free
  zone rules; the row is plain buttons, no text editing interplay.
- Device gating: same as pen (`_isDrawingDevice`, finger allowed only with `fingerDraw`).
- Full-screen picker (canvas_screen.dart:2319) iterates `kCanvasToolOrder` — free.
- `setTool` toggle/close behavior — free (no change).

### 2.3 Sync

Commit is a plain add of fresh strokes → set-union, tombstone-on-undo via `_addElementsOp`.
**Zero new sync surface.** Tests: a small controller test (drag → commit → undo/redo) +
generator coverage already in Phase 1's recognizer tests.

**Effort: ~1–2 days.**

---

## 3. Phase 3 — Custom shape library

### 3.1 Model + storage

```dart
class ShapeTemplate { String id; String name; List<List<Offset>> polylines; DateTime createdAt; }
```

Polylines normalized to a unit box (preserving aspect). **Device-local v1**: persisted in
`settings.json` via `SettingsService` (capped ~50, like the viewport map's 300-cap pattern).
**Deliberately not synced** — a synced library means a new top-level store file with its own
merge rule (whole-file LWW would be easy, but it is *new sync surface*); ship device-local
first, promote later only if wanted. Note this in Settings UI copy ("saved on this device").

### 3.2 Capture + insert

- **Capture**: lasso action row gains "Save as shape" when the selection is strokes-only —
  normalizes each selected stroke's `points` into the unit box (multi-stroke templates are
  fine; they stamp as multiple `StrokeElement`s in one op). Name prompt via the standard
  dialog; mobile action-sheet variant included.
- **Insert**: template chips inside the shape tool's options row (Phase 2). Drag-to-place
  scales the template to the drag rect; Shift locks the template's own aspect. Commit = one
  `_addElementsOp` over all stamped strokes (they share the op → one undo).
- Stamped strokes take the **current pen color/size**, not the template's original style
  (templates store geometry only — keeps the model tiny and the behavior predictable).

### 3.3 Sync

Stamped output is ordinary strokes (union). The library itself never syncs in v1. **Zero new
sync surface.** Tests: normalize/stamp round-trip (aspect, multi-polyline), cap eviction.

**Effort: ~1–2 days.**

---

## 4. Phase 4 — Non-uniform resize (stretch/squash) for selections

### 4.1 UX

Side handles (L/R/T/B midpoints) on the selection box, in addition to today's corner
(uniform) handles. Dragging a side handle stretches along that axis only, opposite edge
pinned. Suppress side handles when the selection's screen rect is small (< ~48 px on that
axis) so they don't overlap the corners. This is a general selection power feature (any
strokes), not shape-gated — but it's *motivated* by shapes.

### 4.2 Touch points

- `SelectionHit` (canvas_controller.dart:26) gains `resizeL/resizeR/resizeT/resizeB` — the
  compiler flags every exhaustive switch: `hitTestSelection` (~1262), `_updateSelectionDrag`
  (~1332), and the painter's handle drawing.
- New `CanvasElement.scaleXY(double sx, double sy, Offset anchor)`:
  - `StrokeElement`: per-axis point scale; `size *= sqrt(sx*sy)` (geometric mean — degrades
    to today's behavior when sx == sy); `invalidateCache()`.
  - `TextElement`: **route L/R to the existing wrap-width path** (`manualWidth` +
    `autoTextRect`, exactly what corner handles do for text today, ~1344); T/B no-op —
    matching the "text never scales font by drag" rule.
  - `ImageElement`: stretch `rect`.
  - `AttachmentElement`: no-op (chips keep their aspect; move/uniform only).
  - Known accepted limitation: rotated elements stretch along **page** axes (no skew support)
    — same simplification every note app makes; document in KNOWN_ISSUES on ship.
- `_updateSelectionDrag`: new cases compute `sx`/`sy` from pointer travel relative to the
  pinned opposite edge (mirror of the corner-anchor math at ~1371), with the same
  min-size guard.

### 4.3 Sync

Rides the **existing** selection-drag commit path: `_beginSelectionDrag` deep-copies before
(~1323), `_endSelectionDrag` builds the before/after op and `_stamp`s (the comment block at
1411 documents exactly why). A new drag *mode* feeding the same commit changes nothing about
what reaches disk/Drive — mutated strokes upload as higher-rev same-id copies (rev-aware
union), objects as LWW. **Zero new sync surface.** One check while implementing: confirm the
drag-commit op stamps for *all* drag modes (it must, per the CLAUDE.md invariant) — extend
`canvas_controller_test.dart` with a stretch → undo → redo rev-monotonicity test.

**Effort: ~1–2 days (mostly handle UI + hit-test polish).**

---

## 5. Explicit sync-safety summary (the "nothing can break" ledger)

| Invariant (CLAUDE.md) | P1 | P2 | P3 | P4 |
|---|---|---|---|---|
| Mutating op commits `_stamp` affected elements | swap-op stamps apply+revert | fresh adds (stamp N/A) | fresh adds | existing drag-op stamps |
| Removal ⇒ tombstone in same op | `_addElementsOp` revert path | same | same | n/a (no removal) |
| Ops snapshot deep copies, never live refs | point lists copied | n/a | n/a | `_dragBefore` deepCopy (existing) |
| No `savePage`/`saveNotebook` from sync-write paths | untouched | untouched | untouched | untouched |
| No new file kinds / relPaths / envelope fields | ✔ | ✔ | ✔ (settings.json only) | ✔ |
| MergeEngine unchanged | ✔ (verified rev-aware stroke union) | ✔ | ✔ | ✔ |
| Old app versions read new data | shape strokes = plain ink | same | same | same |
| Purge/GC/bin flows | untouched | untouched | untouched | untouched |
| Open-canvas live merge (`applyRemotePage`) | no new hazard (active stroke uncommitted until pen-up) | same | same | same |

Also unchanged: page-JSON isolate offload thresholds (shape strokes are ordinary dense-ish
strokes), search indexing, bookmarks, export isolate boundary (`toJson` payloads only).

---

## 6. Risks + de-risking order

1. **Corner fidelity through `perfect_freehand` (top visual risk).** Before building the
   recognizer, run a ~half-day spike: hand-construct rect/triangle point sets with the §1.5
   corner-cluster strategy, render on a real device (and PDF-export once), and eyeball
   corner sharpness at several stroke widths. If unacceptable, tune cluster density/spacing —
   the outline must look right **from points alone** (`cachedOutline` is transient; there is
   no place to persist a bespoke path).
2. **Hold detection vs stylus jitter / slow deliberate drawing.** Slop + timer constants need
   real S-Pen tuning; keep them in `ShapeTuning`. False-positive snaps are the UX killer —
   bias thresholds conservative (miss > wrong-snap), and the toggle is the escape hatch.
3. **Recognition quality tail.** The classifiers are days of code but the tolerances take
   iteration with real sloppy input. Unit fixtures should be recorded from actual device
   strokes (add a debug dump of `activeStroke.points` behind a `kDebugMode` long-press or
   similar throwaway) rather than only synthetic noise.
4. **Timer lifecycle leaks.** Every exit path (end/cancel/dispose, second-finger cancel, tool
   switch mid-gesture) must kill `_holdTimer` and clear snap state — covered by controller
   tests.

## 7. Per-phase verification (pre-commit, per user's workflow)

Each phase, before commit: `flutter analyze` + `flutter test`; then on-device
(`flutter run -d <id> --dart-define-from-file=.dart_defines.json` — OAuth ids required or sync
dies and the sync checks below are meaningless):

- **P1**: draw-pause-snap each kind; adjust-while-holding; undo×2/redo×2; toggle off → no
  snapping; finger-draw + second-finger cancel; **two-device sync**: snap on A → appears on B;
  undo on A after B pulled → freehand propagates to B; eraser (both modes) on a shape stroke;
  PDF export of a page with shapes.
- **P2**: each predefined kind incl. Shift-constrain (desktop); undo/redo; sync to second
  device; export.
- **P3**: save from lasso (single + multi-stroke), stamp, restart app (persistence), cap.
- **P4**: stretch strokes/images; text L/R rewrap unchanged vs corner behavior; rotated-element
  caveat noted; undo/redo; two-device convergence after stretch; export reflects stretch.

## 8. Rollout order

P1 spike (corner fidelity) → P1 → P2 → P3 → P4. Each phase is independently shippable; P2–P4
reuse P1's generator module. On each ship: update `CLAUDE.md` (Canvas section), `CANVAS_SPEC.md`
(new tool + hold-to-snap semantics), `KNOWN_ISSUES.md` (rotated-stretch limitation, any tuning
caveats), and delete the corresponding section here or mark it landed.
