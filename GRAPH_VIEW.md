# Connections Graph — Reference

Everything about the **Connections graph** feature built on the
`feature/connections-graph-view` branch: an Obsidian-style node/edge graph of
the app's internal Connections, plus **Tags** and **Projects** (two new synced
concepts), a filter/navigator panel, and a floating **local graph**. Written so
you can work on it without reading the whole codebase.

> Status: complete on the branch, analyze-clean, **not merged**. Cross-platform
> (Windows / macOS / Linux / Android / iOS) — pure Flutter `CustomPainter` +
> `Ticker` + local file reads, **no new dependency**.

## Contents

- [1. What it is](#1-what-it-is)
- [2. Files at a glance](#2-files-at-a-glance)
- [3. Entry points](#3-entry-points)
- [4. Architecture](#4-architecture)
- [5. Data model](#5-data-model)
- [6. Building the graph (GraphService)](#6-building-the-graph-graphservice)
- [7. GraphController (layout + viewport + filter)](#7-graphcontroller-layout--viewport--filter)
- [8. Rendering (GraphPainter)](#8-rendering-graphpainter)
- [9. Node shapes (visual encoding)](#9-node-shapes-visual-encoding)
- [10. The filter / navigator panel](#10-the-filter--navigator-panel)
- [11. Filtering & scoping model](#11-filtering--scoping-model)
- [12. Tags](#12-tags)
- [13. Projects](#13-projects)
- [14. In-panel link creation](#14-in-panel-link-creation)
- [15. Local graph (floating card)](#15-local-graph-floating-card)
- [16. Navigation from the graph](#16-navigation-from-the-graph)
- [17. Mobile vs desktop](#17-mobile-vs-desktop)
- [18. Persistence](#18-persistence)
- [19. Sync](#19-sync)
- [20. Interaction details](#20-interaction-details)
- [21. Key decisions & gotchas](#21-key-decisions--gotchas)
- [22. Not done / limitations](#22-not-done--limitations)
- [23. Commit history](#23-commit-history)

---

## 1. What it is

A visualization of the **Connections** system (internal two-way links between
any items — see the "Connections" section of `CLAUDE.md`). Nodes are the linked
items; edges are the connections. It reuses the app's existing endpoint model
(`omninote://link/...` URIs) and the app-owns-the-viewport pattern from the
canvas — so it fits the codebase and needs no graph library.

Three surfaces, **one engine**:

1. **Global graph** — the whole store's connections (desktop nav-rail mode /
   mobile tab).
2. **Filter / navigator panel** — a notebook→section→canvas tree + tag/project
   filters + appearance controls, beside (desktop) or under (mobile) the graph.
3. **Local graph** — a floating, pinnable card centered on one item, opened from
   any Connections menu (desktop only).

Two **new synced concepts** shipped alongside:

- **Tags** — reusable name-only labels on any item; filter the graph by them.
- **Projects** — named saved selections of items; activate one to scope the
  graph.

---

## 2. Files at a glance

| File | Role |
|---|---|
| `lib/screens/graph_screen.dart` | **The heart.** `GraphController`, `_GraphPainter`, `GraphScreen`, the filter panel `_GraphFilterPanel`, and the floating `LocalGraphController` + `LocalGraphPanel`. Shape helpers. |
| `lib/services/graph_service.dart` | `GraphService.buildGraph()` (nodes+edges), `buildStructure()` (container tree), the `GraphNode` / `GraphEdge` / `GraphData` / `GraphContainer` / `GraphStructure` models. |
| `lib/models/tag.dart` | `TagDef` + `TagAssignment` (tags.json records). |
| `lib/services/tag_service.dart` | `TagService` — the tag registry. |
| `lib/widgets/tag_manager_sheet.dart` | Attach/create/rename/delete tags for one item. |
| `lib/models/project.dart` | `ProjectDef` + `ProjectItem` (projects.json records). |
| `lib/services/project_service.dart` | `ProjectService` — the project registry. |
| `lib/services/settings_service.dart` | Device-local graph prefs (`graph*` fields + `graphView` blob). |
| `lib/widgets/connections_sheet.dart` | Gained a Tags strip + a desktop "Open local graph" button. |
| `lib/screens/desktop_shell_screen.dart` | Hosts the graph mode + the floating `LocalGraphPanel`; publishes the current location. |
| `lib/screens/mobile_shell_screen.dart` | Graph replaced the Bin tab; Bin moved to the home app bar. |
| `lib/screens/home_screen.dart` | Bin button in the app bar. |
| `lib/screens/canvas_screen.dart` | Canvas "All connections" gained Copy link / Add / Tags via `selfEndpoint`. |
| `lib/services/{notebook_service,sync_service}.dart`, `lib/services/sync/merge_engine.dart` | Wire `tags.json` + `projects.json` into persistence + sync. |

Reused (not new): `lib/models/link.dart` (`LinkEndpoint`, `LinkRecord`),
`lib/services/link_service.dart`, `link_resolver.dart`, `link_navigator.dart`,
`search_service.dart` (`SearchResult` = the navigation currency).

---

## 3. Entry points

- **Desktop:** nav-rail button (`Icons.hub_outlined`) → `_MainMode.graph` in
  `DesktopShellScreen`, rendered full-pane like Search/Bin.
- **Mobile:** the bottom-nav **Graph** tab (index `_kGraph = 1`, took the Bin's
  old slot; Bin moved to the home-screen app bar).
- **Local graph:** the **"Open local graph"** button (desktop-only) in any
  Connections sheet (`connections_sheet.dart`) → `LocalGraphController().openAt`.

`GraphScreen` is one widget reused by both shells (like `NoteSearchView`).

---

## 4. Architecture

Mirrors the canvas: **the app owns the viewport** (no third-party camera).

- `GraphController extends ChangeNotifier` holds the node/edge set, a
  **force-directed layout**, the pan/zoom camera, and the filter/scope state.
- `_GraphPainter extends CustomPainter(repaint: controller)` draws it.
- A `Ticker` in the screen `State` drives the simulation (`controller.step()`),
  stopping when it settles and restarting via `controller.onWake`.
- Node data comes from `GraphService` (a store walk, like `SearchService`).
- Edges come from `LinkService.allLinks()` (the `links.json` registry).

Force model (`GraphController.step`): pairwise repulsion + edge springs (toward
a rest length) + gentle gravity to the origin + velocity damping, with per-step
speed clamping. Settles when max speed drops below a threshold.

---

## 5. Data model

All in `graph_service.dart`.

**`GraphNode`** — one distinct linked endpoint, keyed by its
`LinkEndpoint.toUri()` (so two records pointing at the same endpoint share a
node):
- `key`, `title`, `kind` (`LinkTargetKind`), `alive`, `degree`, `leafId`.
- `reveal` (`SearchResult?`) — the shell-navigation target (null for
  external/dead).
- `externalUrl`, `color` (identity color for alive internal nodes).
- Container ancestry: `notebookId`, `sectionId`, `canvasId`, `folderId`, plus
  `deepestContainerId` (getter) — drives filtering + tree cross-highlight.
- Ancestor names `notebookName`/`sectionName`/`canvasName` (from the reveal) —
  the filter tree's fallback labels.
- `canvasKey` — for an inside-canvas node, its owning canvas's node key (the
  abstraction target).

**`GraphEdge`** — `aKey`, `bKey`, `label?`, and `implicit` (a dashed
"same-canvas" grouping edge, not a real connection).

**`GraphData`** — `nodes`, `edges`, and `abstractCanvasNodes` (synthesized
canvas nodes used when inside-canvas items are abstracted into a canvas that
isn't itself linked).

**`GraphContainer` / `GraphStructure`** — the store's nested container tree
(notebook → section-group → section → canvas-folder → canvas), each with an
`endpoint` + `reveal`. Drives the filter tree (folders included) and the
unlinked-node synthesis.

Node identity is the endpoint URI; edges are inherently two-way (one
`LinkRecord` backs both directions); dead endpoints resolve greyed via
`resolveEndpoint`.

---

## 6. Building the graph (GraphService)

- **`buildGraph()`** → `GraphData`. Reads `LinkService.allLinks()`, collects the
  distinct endpoints as nodes (deduped by URI), resolves each **once**
  (`resolveEndpoint`, bounded-concurrent) for title / aliveness / reveal /
  identity color / ancestry, and turns alive records into edges (self-links
  skipped). Synthesizes `abstractCanvasNodes` for canvases that own linked items
  but aren't themselves linked.
- **`buildStructure()`** → `GraphStructure`. Walks the store
  (`getNotebooks` → `getSectionMap` → `getCanvasMap`, honoring the `nodes` trees
  so folders/groups appear). O(store), like `SearchService.buildIndex`.
- **Local subgraph** (built in `LocalGraphPanel._maybeRebuild`): `buildGraph()`
  then a **BFS** from the center out to `depth`, plus the center's **same-canvas
  siblings** (so a canvas's cluster is always intact). See
  [§15](#15-local-graph-floating-card).

`GraphScreen._load` runs `buildGraph` + `buildStructure` (via `Future.wait`) +
tags + projects, debounced on `SyncService.dataVersion`.

---

## 7. GraphController (layout + viewport + filter)

- **Viewport:** `zoom`, `pan`, `screenToCanvas`/`canvasToScreen`, `zoomAt`,
  `panBy`, animated `fitToScreen` (camera tween lerped inside `step`).
- **`setData` / `setStructure` / `setTagData` / `setProjects`** feed it; every
  mutation runs `_rebuildActive()`.
- **`_rebuildActive()`** is the core: from the full `_all` graph it computes the
  visible node/edge set applying the filter + abstraction + project scope,
  preserves positions of persisting nodes, recomputes `activeDegree` (node
  size), and appends the dashed same-canvas edges. Fires `notifyListeners`,
  `_bumpUi` (the low-frequency panel signal), `onWake`, `onContentChanged`
  (auto-fit).
- **Crossing reduction:** on the first settle after a change, small graphs
  (≤30 nodes / ≤40 edges) run `_reduceCrossings` — a greedy position-swap pass
  minimizing edge crossings (`_segIntersect`), gated by size so it's free on big
  graphs. Only relabels positions, so the bounding box / fit is unchanged.
- **`uiVersion`** (a separate `ValueNotifier<int>`) is bumped only on
  data/filter/hover changes — the panel listens to it, so the panel's tree isn't
  rebuilt on the 60fps sim ticks.

---

## 8. Rendering (GraphPainter)

`_GraphPainter(controller, palette, theme)`:
- Precomputes screen positions once (avoids O(edges×nodes)).
- Draws edges (thickness + opacity from the sliders; `implicit` edges dashed via
  `_dashLine`; the hovered node's edges highlighted).
- Draws nodes as **shapes by kind** ([§9](#9-node-shapes-visual-encoding)),
  sized by `radiusOf` (active degree × node-size slider), with halos for
  hover / neighbor / tree-hit, and labels (fade with the text-opacity slider;
  "Always show labels" ignores the zoom threshold).
- Colors come from `AppPalette` (`canvas`, `dot`/`textDim` for edges, `accent`
  for highlights, `identityColor` for nodes).

---

## 9. Node shapes (visual encoding)

One silhouette per kind (top-level `_shapeFor` / `_paintShape` / `_polygon`;
reused by the tree/legend via `_ShapeIcon`):

| Shape | Kind |
|---|---|
| Hexagon | Notebook |
| Pentagon | Section-group / canvas-folder |
| Rounded box | Section |
| Circle | Canvas |
| Triangle | Inside-canvas item (page / selection / bookmark) |
| Diamond | External URL |

---

## 10. The filter / navigator panel

`_GraphFilterPanel` (in `graph_screen.dart`). A fixed header + **one scroll
view** holding everything (tree rows inline — no nested `Expanded`, so it never
overflows at any height). Sections, each collapsible and persisted:

- **View toggles:** Expand items inside canvases · External links · Show items
  without links.
- **Tags** (collapsible) — the AND/OR/NOT filter ([§12](#12-tags)).
- **Projects** (collapsible) — list / activate / edit / delete / new
  ([§13](#13-projects)).
- **Filter items** (collapsible tree, default collapsed) — the store structure
  with **independent, cascading checkboxes** (uncheck a section, still re-check
  individual canvases inside it). Hovering a row halos its nodes in the graph
  (and hovering a node halos its path here); tapping a row frames its nodes.
- **Appearance** (collapsible, pinned at the bottom) — sliders: node size, text
  size, text opacity, link thickness, link opacity; toggles: always show labels,
  link items in same canvas.

Layout: a **side column** on wide (≥640px) desktop; a **draggable bottom sheet**
on mobile ([§17](#17-mobile-vs-desktop)).

---

## 11. Filtering & scoping model

Applied in `GraphController._rebuildActive` / `_passesFilter`:

- **Container checkboxes** (`hiddenContainers`): a node is hidden if its
  *deepest* container id is hidden. Toggling a row cascades over its subtree
  (`setSubtreeHidden`) but each child stays independently re-checkable.
- **External toggle** (`showExternal`).
- **Show-unlinked** (`showUnlinked`): adds isolated nodes for containers with no
  links (from the structure walk — `_unlinkedCandidates`).
- **Abstraction** (`abstractInsideItems`, default on): page/element/bookmark
  nodes collapse into their canvas node (edges remapped/deduped via `canvasKey`,
  self-loops dropped); off shows them individually.
- **Same-canvas links** (`sameCanvasLinks`, default on): when items are shown,
  each is connected to its canvas node with a dashed `implicit` edge — keeps a
  canvas's items clustered/visible.
- **Tag filter** (`tagInclude` / `tagExclude` / `tagMatchAll`): each chip cycles
  off→include→exclude; includes combine by ANY/ALL, excludes always remove.
- **Project scope** (`activeProjectId`): restricts to the project's members —
  `_inActiveProject` resolves the node's deepest container against the project's
  inherited include/exclude sets ([§13](#13-projects), nearest-ancestor wins),
  so a new item under a selected section is scoped in automatically; container
  checkboxes still apply on top; activating clears `hiddenContainers` so all
  start shown; `projectPlusLinks` also pulls in members' one-hop neighbors. When
  a project is active the Filter-items tree is scoped to its members
  (`_inProjectSubtree`, which also honors inheritance).

Any change auto-fits the graph (debounced) via `onContentChanged`.

---

## 12. Tags

Reusable **name-only** labels on any of the 8 item kinds; **synced**.

- **Storage:** store-root `tags.json` — one id-keyed map with a `t`
  discriminator: `TagDef` (`t:'d'`, name) and `TagAssignment` (`t:'a'`, tagId +
  endpoint URI). Both carry the sync envelope. (`lib/models/tag.dart`)
- **`TagService`** (lazy, `dataVersion`-gated, like `LinkService`):
  `allTags`, `tagsOf(leafId)`, `tagIdsByLeaf`, `createTag`, `renameTag`,
  `deleteTag` (tombstones the def **and** all its assignments), `assign`,
  `unassign`.
- **Item side:** a **Tags strip** in the Connections sheet (chips + ✕ + "＋
  Add tag") → `tag_manager_sheet.dart`. **Seamless search-or-create (07/22/26):**
  one search field filters existing tags as you type; when the typed name isn't
  an existing tag a **"Create «name»"** row appears (Enter also creates-or-
  reuses, case-insensitively — no duplicate same-named tags). Each listed tag
  still has attach-checkbox / rename / delete.
- **Graph side:** the "Tags" filter section (chips cycle off/include/exclude +
  ANY/ALL + Clear). Filter-only here — no create/delete.
- Assignments reuse the `omninote://link/...` endpoint URIs (no new addressing).

---

## 13. Projects

Named, **graph-side, synced** saved selections of items (invisible from the item
side — the contrast with tags).

- **Storage:** store-root `projects.json` — `ProjectDef` (`t:'pd'`) +
  `ProjectItem` (`t:'pi'`, projectId + endpoint + an **`ex`** flag: an
  *exclude* record when true, else an include). (`lib/models/project.dart`)
- **`ProjectService`:** `allProjects`, `membersOf` (alive include+exclude
  records), `createProject`, `renameProject`, `deleteProject`,
  `setMembers(includes:, excludes:)` (unions/tombstones membership; flips an
  existing record's include/exclude sense in place).
- **Membership is CONTAINER-INHERITING (07/22/26).** Checking a section/notebook
  includes it **and everything under it — now and future**; a canvas added later
  under a checked section is a member with no record of its own. Resolution walks
  each node's container **ancestry nearest-first** (`isProjectMember` /
  `_inActiveProject` in the controller; the panel's `_peEffective`) — a nearer
  include/exclude beats a farther one. So unchecking one canvas under a checked
  section writes an **exclude** record for just it (`_peExcludes`), and
  re-checking it clears the exclude (inherits again — no marker kept). The
  controller builds a `containerId → [self…notebook]` **ancestor map** from the
  store structure (`_buildAncestors` in `setStructure`) so real folder/group
  nesting is honored, which endpoint URIs alone don't encode. Only two sets are
  stored (`_projIncludes`/`_projExcludes`), minimal — descendants inherit.
- **Build mode** (in the panel): "New project" → a name field + the full tree
  with **tri-state checkboxes** — a check driven by an ancestor (inherited)
  renders **dimmer** than an explicit one; tapping a row (`_toggleMember`) clears
  its subtree's explicit markers then writes an explicit include/exclude only
  when the desired state differs from what it inherits.
- **Activate** a project → the graph scopes to it ([§11](#11-filtering--scoping-model));
  an "Include linked neighbors" toggle and a project-scoped "Show items without
  links" toggle appear. Members show even if unlinked. Containers-only, but
  inside-canvas items follow the usual link-only + abstract rule.
- **Known limit:** membership is container-level (notebook/section/folder/
  canvas); you can't add a single inside-canvas item to a project independent of
  its canvas. A canvas selected via its parent **canvas-folder** inherits only if
  the folder id is on its ancestry chain (it is, via the structure map).

---

## 14. In-panel link creation

A **link-mode** toggle (the `add_link` header icon). In link mode the
**Filter-items tree** (already scoped by the active project) is the picker: tap
a source row, then a target row → `LinkService.addLink` + toast + reload. The
visibility checkboxes keep working while linking (row tap picks; checkbox toggles
view). With a project active you link only among its items; with none, across
everything.

---

## 15. Local graph (floating card)

`LocalGraphController` (singleton) + `LocalGraphPanel` (hosted in the desktop
shell's top-level Stack). **Desktop only.**

- **Open** from a Connections menu's "Open local graph". Centers on that item.
- **Subgraph:** BFS from the center over the full graph out to `depth` (1–4),
  **plus every same-canvas sibling of any kept node** — so a canvas's aggregate
  never vanishes after hopping to one item and back. Centering on a canvas seeds
  its whole cluster (matching the Connections menu's aggregate). The center node
  is always injected + emphasized (`setHover`).
- **Interactive:** own `GraphController` + `Ticker`; a `LayoutBuilder` gives it a
  screen size (so it centers/fits — without this it sat at the origin). Full
  pan / zoom / drag / tap.
- **Card:** draggable (title bar) + resizable (grip). Title: back / forward /
  a ⚙ **view menu** (Abstract items into canvas · Link items in same canvas —
  applied to the local controller with `persist: false`, so they don't change
  the global graph) / **pin** / close. Bottom: recenter, depth −/+.
- **Pin** = *keep it visible only*. Unpinned = dismisses on an outside tap
  (a barrier); pinned = stays and the app stays usable. **No auto-follow.**
- **Recenter** = jump the graph to the app's current location (the shell
  publishes it on canvas/section/notebook selection via
  `setCurrentLocation`). Manual — the graph never moves on its own.
- **Back/forward** walk a history stack **and navigate the app** to that node
  (`openCanvas`), not just re-focus the graph.
- **Tap a node** → navigate the app there (+ element flash) and push the hop.

---

## 16. Navigation from the graph

- Tapping a node (global or local) calls `_handOffElementFocus` (sets
  `LinkNavigator.pendingElementFocus` for in-canvas targets, so the destination
  canvas **flashes + scrolls** to the elements) then `LinkNavigator.openCanvas`
  — "go to the actual place" (open the canvas / drill to the container), not the
  stop-at-list reveal.
- Mobile `_revealSearchResult` pops the **root navigator first**, so navigating
  replaces rather than stacks a canvas (one set of widgets, no duplicates).
- Desktop `openCanvas` (`_openCanvasFromResult`) skips its full reload when the
  target notebook is already loaded.
- Navigation is the existing `SearchResult` reveal path — glow trail included.

---

## 17. Mobile vs desktop

| | Desktop | Mobile |
|---|---|---|
| Entry | nav-rail `_MainMode.graph` | bottom-nav Graph tab |
| Panel | resizable side column | draggable bottom sheet |
| Panel behavior | book-icon-style toggle | graph **shrinks** above the sheet (both visible); tap the handle to expand/retract (snaps peek/half/tall); graph re-fits |
| Local graph | floating card | — (not built on mobile) |
| Swipe | — | the Graph tab disables tab-swipe so drags pan the graph |

---

## 18. Persistence

All device-local (never synced — how you *view* the graph is per-device).
`SettingsService`:

- Individual `graph*` fields: `graphNodeSize`, `graphTextSize`,
  `graphLinkThickness`, `graphLinkOpacity`, `graphLabelOpacity`,
  `graphAlwaysLabels`, `graphAbstractItems`, `graphShowExternal`,
  `graphShowUnlinked`, `graphSameCanvasLinks`.
- A **`graphView` blob** (`patchGraphView`) for the rest: hidden/selected
  containers, tag include/exclude/matchAll, active project + include-links, and
  panel expand states (which sections open + which tree rows expanded).

`GraphController` seeds from these in its constructor and saves on every change;
the panel restores/saves its own expand state. Reopen the app → the graph view
is exactly as you left it.

---

## 19. Sync

`tags.json` and `projects.json` are wired **exactly like `links.json`** — no new
merge logic:

- `NotebookService`: `tagsFile`/`projectsFile` + `read*Json`/`save*Json`;
  `isSyncedRelPath` + `listSyncedRelPaths` include them.
- `MergeEngine.reconcile` routes `tags.json` / `projects.json` /`links.json`
  through `mergeNotebooksIndex` — **union by id + per-record LWW + tombstone
  deletes**. (A registry mixing definition + assignment records is fine; the
  merge only compares envelopes.)
- `SyncService` push special-cases all three registries: uploaded **whole to
  every connected account** (records are tiny; the union merge makes any
  account's copy safe; endpoints an account lacks resolve as dead).

So a tag/project/assignment created concurrently on two devices survives first
sync, and a delete propagates as a tombstone. Deletion is always a tombstone,
never a map removal (the durability rule).

---

## 20. Interaction details

- **Pan/zoom/drag/tap:** a `Listener` (wheel zoom via `onPointerSignal`) + a
  `RawGestureDetector` (`ScaleGestureRecognizer` for pan/zoom/drag-a-node,
  `TapGestureRecognizer` for node tap). Dragging a node pins it during the drag.
- **Auto-fit:** any filter/data change fires `onContentChanged`; the screen
  debounces a `fitToScreen` (~700ms) so the graph reframes after the layout
  settles.
- **Hover** (desktop): `MouseRegion` → `setHover`; the hovered node + neighbors
  are emphasized, the rest dimmed.

---

## 21. Key decisions & gotchas

- **`StackFit.expand` is load-bearing** where the shell wraps its body in a Stack
  to host `LocalGraphPanel`: the closed panel is a zero-size child, so without
  `StackFit.expand` the Stack collapses to 0×0 and the desktop renders blank.
- **Panel rebuilds on `uiVersion`, not the controller**, so the tree isn't
  rebuilt on every 60fps sim tick.
- **The panel is one scroll view** (tree rows inline, no nested `Expanded`) so it
  never overflows — required for the short mobile peek height.
- **`_g.setScreenSize` is required** for any graph surface (the local card lacked
  it initially → sat at the origin, un-interactable).
- **Local view options use `persist: false`** so they don't mutate the global
  graph's settings.
- **Same-canvas cluster expansion** (local subgraph) is what keeps a canvas's
  aggregate visible from any of its items.
- **Reveal must pop the root navigator first** on mobile or canvases stack.
- **Element focus handoff** (`pendingElementFocus`) is what makes an in-canvas
  node tap flash + scroll correctly.

---

## 22. Not done / limitations

- **On-device testing** — especially tags/projects **sync across two devices**,
  the mobile bottom-sheet feel, and the local-graph card. Not yet verified.
- **Local graph is desktop-only.**
- **In-canvas scope toggle** (view only this canvas/section/group/notebook from
  inside the canvas) — the filter model supports it, but no in-canvas UI yet.
- Possible follow-up (user hinted): host the graph **inside the Connections list
  sheet** and pin the sheet, rather than opening the separate floating card.
- Deliberately skipped: a greyed "connections inside this section" dropdown on
  the section three-dot menu.
- The graph captures **explicit** connections only (no auto-backlinks), so it's
  as dense as the links people actually make (plus the derived same-canvas dashed
  grouping).

---

## 23. Commit history

Branch `feature/connections-graph-view` (newest first):

```
7482c91 feat(graph): local-graph back/forward nav, notebook/section recenter, same-canvas dashed links + options
f173871 fix(graph): local-graph rework + graph nav (glow/zoom, no dup stacks) + mobile panel
9b0456b fix: desktop blank render + mobile reveal spuriously swiping to the Graph tab
9624729 feat(graph): floating local-graph card (desktop) from Connections menus
2aa2a79 feat(graph): project show-unlinked toggle, mobile sheet snap/retract, no tab-swipe on graph
a0b2e71 feat(graph): mobile — Graph tab replaces Bin, panel as a draggable bottom sheet
d0e58a3 fix(graph): project checkboxes hide, top-bar safe-area, canvas connections aggregate + actions
df069c5 feat(graph): link within project scope + cheap crossing reduction
300153b feat(graph): persist all view state, auto-fit on change, project-scoped tree + cascade select
1840065 feat(graph): flat link browser in link mode
af40af0 feat(projects): graph-side saved selections + canvas Connections parity
3cd8706 feat(tags): name-only tags on any item, synced, with graph AND/OR/NOT filter
4fb202e feat(graph): panel refresh — collapsible tree, bottom Appearance, independent checkboxes
f8bc926 feat(graph): store-structure tree, unlinked items, in-panel linking, persisted view
d2ca5ba feat(graph): Connections graph view (Obsidian-style, desktop)
```
