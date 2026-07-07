# OminiNote Sync Architecture v2 Implementation Tasks

Status: `[x]` done · `[/]` partial/deviates from plan · `[ ]` not done.

## Phase 1: Local Layer & Data Models
- `[x]` Common object envelope (`schemaVersion`, `id`, `rev`, `updatedAt`, `deviceId`, `deletedAt`) on Notebook, Section, **Canvas**, CanvasPage, and CanvasElement.
- `[x]` Envelope `rev`/`updatedAt` now actually advance — `NotebookService` save methods call `bumpRev(deviceId)` on every real edit (previously `bumpRev` was defined but never called, so LWW was useless).
- `[/]` Fractional indexing for page order — **not** implemented. Structural files (`section.json`/`canvas.json`) use whole-doc LWW instead; page-add order within one canvas is therefore LWW, not fractional-merge (see KNOWN_ISSUES).
- `[x]` Atomic local writes (temp + rename), incl. a binary variant for pulled assets.

## Phase 2: Merge Engine (Core Logic)
- `[x]` `MergeEngine` — pure, side-effect-free, unit-tested (`test/merge_engine_test.dart`).
- `[x]` Hierarchy merge: `notebooks.json` is a **union map keyed by notebook id**, per-id LWW (two devices' distinct notebooks both survive first sync); `section.json`/`canvas.json` are single-doc LWW.
- `[x]` Page merge: set-union of immutable strokes + grow-only erase tombstones; LWW for text/image objects and background.
- `[x]` Deterministic tie-break tuple `(rev, updatedAt, deviceId)`.

## Phase 3: Authentication & Secure Storage
- `[x]` `flutter_secure_storage` dependency + wired.
- `[x]` Loopback OAuth **PKCE** flow for desktop (`desktop_oauth.dart`).
- `[x]` `refresh_token` persisted to secure storage (never `settings.json`); silent restore on launch.
- `[x]` Access-token refresh — proactive (5 min before expiry) and reactive; concurrent refreshes collapsed.

## Phase 4: Push Pipeline (Local → Drive)
- `[x]` Persistent dirty journal (`sync_journal.json`) — survives process kill, replayed on launch.
- `[x]` Upload queue drains sequentially, debounced (1.5 s), snapshot so mid-drain edits aren't stranded.
- `[x]` Exponential backoff + jitter for retryable errors; SocketException → offline (stays journaled).
- `[x]` Drive `fileId` tracking (`drive_index.json`, path ↔ fileId ↔ headRevisionId).

## Phase 5: Pull Pipeline (Drive → Local)
- `[x]` `changes.list(pageToken)` polling every 30 s (+ on resume / manual).
- `[x]` Full-resync path — bootstrap on first sign-in, 410-Gone recovery, and manual "Repair sync".
- `[x]` Duplicate healing — all "omininote" roots are treated as one logical tree keyed by relative path, so create/create races reconcile.
- `[x]` Echo suppression via `headRevisionId`.

## Phase 6: Lifecycle & UI
- `[x]` `AppLifecycleState` handling — flush pending on background, sync on resume.
- `[/]` Android `WorkManager` periodic background task — **not** implemented (foreground + lifecycle sync only; deferred).
- `[x]` `SyncStatusIcon` in app bars/sidebar; `dataVersion` notifier reloads home + desktop shell after a pull.

## Phase 7: Conflicts & Garbage Collection
- `[ ]` Conflicts Inbox / conflicted-copy materialization — not implemented (merge is deterministic; ambiguous text-box edits currently resolve by LWW, not conflicted-copy).
- `[x]` Garbage collection for tombstones (notebooks/sections/canvases/pages) and stale erase/delete-object tombstone entries, >90 days (`NotebookService.runGarbageCollection`). Local-disk only — see KNOWN_ISSUES.

## v3 revision (2026-07-07): tombstones fixed for real

v2's envelope fields existed on every model but the **service layer still hard-deleted** (map-key removal, recursive directory delete, array splice with no tombstone) — so a delete only stuck once *every* device had independently deleted the same thing; any device that still held a live copy would resurrect it on the next merge. v3 fixes this end to end:

- `[x]` Notebook/Section/Canvas delete = soft-delete (`deletedAt` + `bumpRev`, entry/file kept on disk) instead of removing the map key / deleting the directory. `getNotebooks`/`getNotebook`/`getSection`/`getCanvas` filter `deletedAt != null` so the UI still sees them as gone.
- `[x]` Text/image object delete = new `CanvasPage.deletedObjects` tombstone list (mirrors `erased` for strokes) instead of a bare `objects.removeWhere`. `MergeEngine.mergePage` unions the tombstones and filters `objects` by them.
- `[x]` Lasso "Delete" and single-element remove now tombstone strokes too (previously only the eraser *tool* did; `deleteSelection`/`removeElement` just spliced the array with no `erased[]` entry — same resurrection bug, now fixed).
- `[x]` Page delete: `CanvasPage.deletedAt` explicitly saved (the page leaves the controller's in-memory map before the normal debounced flush would ever save it) instead of only dropping the row reference. `NotebookService.loadPages` prunes any row that still points at a tombstoned page (self-heals a canvas.json structural race) and guarantees a canvas is never left with zero pages.
- `[x]` 90-day GC sweep purges expired tombstoned notebooks/sections/canvases/pages from local disk and trims old tombstone *entries* from otherwise-live pages. Runs once on launch and after every `fullResync`.
