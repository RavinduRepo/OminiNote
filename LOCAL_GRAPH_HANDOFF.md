# Local-graph redesign — handoff / next steps

Pick-up notes for continuing the **Connections graph** work (Obsidian-style
graph + the floating Connections panel). Written 2026-07-23 so a fresh session
can continue without re-deriving context. Read `GRAPH_VIEW.md` for the original
graph reference; this file covers everything added since.

---

## 1. Where things are (branches)

- Work was done on branch **`feature/local-graph-redesign`** (7 commits).
- It has been merged (`--no-ff`) into **`feature/connections-graph-view`** — the
  branch it was cut from. **NOT merged to `main`.**
- `feature/connections-graph-view` also carries the earlier Connections work
  (links, tags, projects, in-text linking, marker coupling, page-move link
  correction) — see the memory notes + `GRAPH_VIEW.md`.
- **Nothing is device-verified.** Everything is analyze-clean only. A full
  on-device pass of the panel + linking is the top priority before merging up.

### The 7 commits (newest first)
```
b12bc91 fix(graph): one node per item (merge marker-grown endpoints), markers both sides, list-nav refresh
b26258d fix(graph): node nav keeps the list/copy/add in sync with the graph center
8a012fe fix(graph): endpoint identity (one node + symmetric lists), aggregate, live-follow coalescing, re-glow
ba1aa43 fix(graph): panel follows selection for copy/add; back-forward echo; highlight existing node
81a587f feat(graph): selected-element-as-current-node + local graph settings gear
032b614 feat(graph): floating Connections panel (list<->graph), action-line, live-nav; fix toggles + local drag
1f91440 feat(graph): unify local graph with global engine (depth + center ring), drag-to-pin
```

---

## 2. What was built (summary)

**The local graph is no longer a separate thing — it's the global graph engine
scoped to a center + depth.** Key pieces (all in `lib/screens/graph_screen.dart`
unless noted):

- **Shared engine + depth/center** — `GraphController.centerKey`/`depthLimit` +
  `setCenter()`; `_rebuildActive` applies a depth-BFS scope + same-canvas
  cluster when a center is set (null center = the full global graph). The
  painter draws a prominent **ring** on the center node. `_maybeRebuild`
  (panel) feeds the WHOLE graph + `setCenter` (no bespoke subgraph).
- **Drag-to-pin** — `GraphSimNode.fixed`; dropping a node keeps it in place.
  Behind an OFF-by-default setting **"Pin nodes where you drag them"**
  (`SettingsService.graphPinOnDrag`, `GraphController.setPinOnDrag`). NOTE the
  user wants this moved to be **per-project** (see Feature F).
- **Floating Connections panel (desktop)** — replaces the modal. Every
  `showConnectionsSheet` call on desktop routes to
  `LocalGraphController.openConnections(...)` (all ~13 callers unchanged; mobile
  still uses `showAdaptiveMenu`). The panel is draggable / pinnable / resizable
  with a **list ⟷ graph toggle** (`ConnPanelView`). List face = the embeddable
  `ConnectionsListView` (`lib/widgets/connections_sheet.dart`, now public, with
  an `embedded` flag + a `body` param the panel injects the graph into). One
  consolidated **copy / add / tag-chips** action line shows above BOTH faces
  (`_embeddedActionLine`). Graph is built lazily (only when the graph face is
  shown).
- **Current-item model** — the panel's list + copy/add/tags + title follow
  `LocalGraphController.currentLocation`. It's updated by: the canvas selection
  publisher (below), graph node taps (`navigateTo` sets it), and
  back/forward/recenter. Rich opened-context (canvas aggregate / lasso
  `onAddTarget` / in-canvas jump) applies only while you're still on the item
  the panel was opened for (`atOpened` in `_buildConnectionsBody`); after you
  navigate away it's plain element/canvas connections. A bare-canvas location
  shows the **aggregate** of everything inside it.
- **Selection publisher** (`canvas_screen.dart` `_publishGraphLocation`) —
  debounced listener on the CanvasController; publishes the lasso selection,
  else the edited text box, else the canvas, as `setCurrentLocation`. Gated on
  the panel being open. **Canonicalizes** the selection to an existing linked
  endpoint (`LinkService.canonicalElementEndpoint`) so re-selecting a linked
  item resolves to the SAME node/record. Publishes once on canvas open.
- **Live-navigate toggle** (`◎` in the graph toolbar) — when on,
  `setCurrentLocation` also drives the graph (auto-follow) and records
  back/forward. The push is DEBOUNCED (coalesces section→canvas→element) and
  SKIPS pure container levels (notebook/section/folder). Programmatic nav
  (back/forward/recenter/node-tap) suppresses the echo push via
  `_beginProgrammaticNav()` (token'd 800ms window) so back/forward don't
  corrupt the history.
- **Settings gear** (graph toolbar) — opens `graphAppearanceControls(...)` (the
  same visual sliders/toggles as the global graph) in a `showDialog` popup,
  live-updating via `ListenableBuilder(_g)`.
- **Node identity merge** (`graph_service.dart` `_canonicalKeys`) — an item's
  endpoint GROWS as reciprocal markers get folded in ({A}→{A,M}→{A,M,M2}); the
  graph now merges element endpoints that share any element id into ONE node
  (canonical = the smallest/most-content endpoint), remapping + deduping edges.
  This is what stops "the same item shows as several nodes".
- **Markers on both sides** — `addLinkWithReciprocalMarker(markBothSides:)`;
  the panel connect (`_addTarget`, `markBothSides: widget.embedded`) drops a
  marker on BOTH linked items, like a manual paste.
- **Re-glow / focus** — `SyncService.focusElementsInOpenCanvas` +
  `CanvasSyncListener.onFocusElements` (→ `CanvasController.focusElements`); a
  graph node tap flashes the OPEN canvas directly so the glow re-fires on every
  tap (incl. items in the current canvas, where `openCanvas` would no-op).

### Key files touched
- `lib/screens/graph_screen.dart` — the engine, painter, `GraphScreen`,
  `_GraphFilterPanel`, `LocalGraphController` + the floating panel.
- `lib/services/graph_service.dart` — `buildGraph` + `_canonicalKeys` merge.
- `lib/services/link_service.dart` — `canonicalElementEndpoint`,
  `addLinkWithReciprocalMarker(markBothSides:)`.
- `lib/widgets/connections_sheet.dart` — public `ConnectionsListView`
  (`embedded`/`body`), desktop routing in `showConnectionsSheet`.
- `lib/screens/canvas_screen.dart` — `_publishGraphLocation` (selection/edit →
  current location).
- `lib/services/sync_service.dart` — `onFocusElements` dispatch.
- `lib/canvas/canvas_controller.dart` — registers `onFocusElements`.
- `lib/services/settings_service.dart` — `graphPinOnDrag`.

---

## 3. TO DO NEXT (the two large features the user asked for)

### Feature E — full filter options in the LOCAL graph settings
Right now the local settings gear only shows **appearance** (sliders + a few
toggles). The user wants **all the global-graph options** too: selecting a
group / container (the filter-items tree), tags, projects.

- The local panel's `_g` (its own `GraphController`) currently only gets `setData`
  — it never gets `setStructure` / `setTagData` / `setProjects`, so the filter
  tree / tag chips / project list would be empty.
- Plan: after building the local graph, also load + feed the store structure +
  tags + projects into `_g` (mirror what `GraphScreen._load` does for the
  global controller). Then reuse `_GraphFilterPanel` (or extract its sections)
  in the settings popup, operating on `_g`. `_GraphFilterPanel` is currently
  tied to `_GraphScreenState` with several callbacks — extracting it standalone
  is the bulk of the work.
- Decision to confirm with the user: does a container filter compose with the
  depth scope, or replace it?

### Feature F — pin-on-drag PER-PROJECT + saved/synced node layout (BIG)
The user's exact intent: **pin-on-drag should NOT be a global appearance
toggle. It belongs to each PROJECT.** Each project should **save the node
positions you arranged (the "structure")**, **synced**, so you can:
- activate a project → arrange its graph → the layout is saved,
- toggle pin on/off per project,
- come back later (any device) and the structure/positions are intact.

This is a GLOBAL-graph + projects feature (activate a project in the global
graph → arrange → save → return), not the local panel per se.

Design sketch:
- Store per project: a `pinLayout` bool + a map `nodeKey (endpoint URI) →
  Offset`. Put it in the synced `projects.json` (new `ProjectDef` fields, or a
  new `t:'pl'` record type) — merges like the rest (union + LWW + tombstone).
  See `lib/models/project.dart` + `lib/services/project_service.dart`.
- When a project is active in the `GraphController`: on layout settle (or on
  drag-drop) save each node's position keyed by its endpoint URI; on activate,
  restore saved positions and set `fixed=true` for saved nodes when the
  project's pin flag is on.
- Move the pin toggle out of global Appearance into the **project row/section**
  in `_GraphFilterPanel` (per-project). Remove `graphPinOnDrag` from global
  settings (or keep as a fallback for no-project).
- Watch: node keys are now CANONICAL (post-merge, `_canonicalKeys`) — save
  positions by the canonical key so they survive marker growth. Also the graph
  is depth-scoped in the local panel but full in the global; the project layout
  is for the GLOBAL (project-scoped) graph.

### Lower priority / "maybe"
- Global graph **pin → tap-node → spawn the local panel** on that node.
- **Mobile** list ⟷ graph toggle inside the bottom sheet (the floating panel is
  desktop-only).

---

## 4. Verify on device (nothing is device-tested)
- The floating panel: float / pin / resize / list⟷graph toggle / settings gear.
- The link workflow: select A → **Copy** → select B → **+ · Paste** → links
  A↔B, one node each, both items show a marker, both lists show the link.
- Then link A→C and confirm A stays **one node** (the merge).
- Live-follow `◎` on/off; back/forward while live is on (echo suppression);
  rapid canvas/section switching (shouldn't get stuck on a section).
- Re-tapping the same node re-glows; tapping items in the current canvas glows.
- Navigating canvases via the canvas-list refreshes the panel.
- Appearance toggles (they update the panel now — was the `_bumpUi` bug).
- Node dragging in the local panel feels like the global (the pointer-down
  hit-test fix).

---

## 5. Known limitations / gotchas to remember
- `graph_screen.dart` ↔ `connections_sheet.dart` have an **intentional import
  cycle** (panel hosts `ConnectionsListView`; `showConnectionsSheet` routes to
  `LocalGraphController`). Dart allows it; don't "fix" it by moving code —
  `_GraphPainter` is private to `graph_screen.dart`, so the panel must stay
  there.
- The selection publisher is **debounced ~350ms** and gated on the panel being
  open — there's a small lag after selecting before Copy/Add reflect it.
- The endpoint-merge (`_canonicalKeys`) also merges a subset endpoint into a
  superset (e.g. linking {A} then {A,B}) — accepted as consistent with the
  existing overlap-based `linksOfElements`.
- `LocalGraphController` is a singleton (never disposed); it holds timers
  (`_followDebounce`) and the connections context.
- Everything here is device-UNVERIFIED.
