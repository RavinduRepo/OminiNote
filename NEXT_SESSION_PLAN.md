# Next Session Plan — Omininote
_Written 2026-07-15. Untracked file (not committed). Delete or commit as you like._
_Point the assistant at this file first: "read NEXT_SESSION_PLAN.md"._

---

## ⚠️ READ FIRST — state that's easy to miss

### Git / branch state
- **Local `main` is 3 commits AHEAD of `origin/main`, and NOT pushed.** origin/main is still `6d9f949` = the released **v1.9.1**. Local main tip = `58bfef3`.
- The 3 unpushed commits (all **device-verified by me**):
  1. `40da810` perf(export): floating progress overlay + streaming `.omninote` export (OOM fix) + PDF lazy-asset paths.
  2. `5520254` perf(export): yield inside PDF text layout (ANR fix).
  3. `58bfef3` fix(sync): best-effort per-item Drive folder purge (stop the 403 retry loop).
- **These 3 belong in a release → cut v1.9.2** (see "Release v1.9.2" below).
- **I accidentally worked directly on `main`** the last stretch (should've been a branch). **For any NEW work: branch off main FIRST** (`git checkout main` → `git checkout -b feature-xyz`). See [[feedback_no_worktrees]].
- **Branch audit done — nothing is missing from main.** All branches are 0 commits ahead of main EXCEPT `ui-refresh` (18 ahead), which is **stale/superseded** (its v2-UI work is already in main via different SHAs; main has 31 later commits built on top). Safe to delete these stale branches: `feature-open-pdf`, `feature-ink-visibility`, `perf-pattern-eraser`, `perf-responsiveness`, `feature/color-wheel-sidebar-chip`, `feature/onenote-import`, `ui-refresh`.

### Build / run (don't get burned)
- **ALWAYS launch with** `--dart-define-from-file=.dart_defines.json` or OAuth client ids are empty and **sync dies after ~1h**. `make android|linux|windows|macos` (mingw32-make on Windows/Git Bash) wraps this. See [[feedback_launch_with_dart_defines]].
- **The recent fixes are NOT in the installed v1.9.1 APK** — to feel the OOM/ANR/purge fixes on the phone, **build a fresh APK from main**.
- **Release signing:** keystore is `SECRETS/release.jks`. `android/key.properties` is gitignored (not present locally) — recreate it (pointing at `SECRETS/release.jks` + passwords) to build a *release* APK locally. **Never lose that keystore** or you can't update existing installs (and can't publish). The debug→release signing mismatch is what forces an uninstall (data-loss) — see "Build/release infra" backlog.

### The working rhythm (I follow this; keep it)
- Per change: implement → `flutter analyze <files>` **and** `flutter test` (run **SOLO/sequential**, never concurrent — two pub-gets contend on Windows) → **present "how to verify nothing broke" + "what might have improved" → WAIT for the user's go-ahead → commit.** See [[feedback_pre_commit_verify_notes]].

---

## 🚀 Release v1.9.2 (quick, do this to bank the verified fixes)
1. `pubspec.yaml` version `1.9.1+6` → `1.9.2+7`.
2. Commit `chore(release): 1.9.2`.
3. `git push origin main` then `git tag v1.9.2 && git push origin v1.9.2`.
(Tags use `vX.Y.Z`. Remote is `git@github.com:RavinduRepo/OminiNote.git`.)

---

## 🎯 MAIN TASK — Sync-engine isolate (merge offload)

### The problem (confirmed)
Drawing gets **sluggish while sync runs** — user confirmed: **turn internet OFF → jank gone; ON → back.** So it's the sync loop, not PDF rendering or local save. The merge runs on the **main (UI) isolate**, so heavy merges block the frame. Worst when a big import is being synced / another device is active.

### Phase 1 — offload `MergeEngine.reconcile` to a worker (LOW risk, do first)
- **Why safe:** `MergeEngine` (`lib/services/sync/merge_engine.dart`) is **pure** (JSON text in → merged JSON text out, no `ui.Path`/live objects) and **unit-tested**. So wrap the call in `Isolate.run(() => MergeEngine.reconcile(rel, localText, remoteText))`.
- **Call site:** `sync_service.dart:657` (`result = MergeEngine.reconcile(rel, localText, remoteText)`), inside `_pullFile`. Note `notebooks.json` takes a different branch at `:655` (`_mergeIndexForAccount` → `MergeEngine.mergeNotebooksIndexScoped`, :693) — offload that too if it's heavy, else leave inline.
- **Size-gate it** like the existing page-JSON offload (`_kPageDecodeChars`=256KB, `_kPageOffloadElements`=120 in notebook_service): tiny files merge **inline** (isolate spawn+copy costs more than the merge); only big files (dense pages / large `notebooks.json`) go to the worker. Threshold on `localText.length + remoteText.length`.
- **MUST STAY ON-MAIN (do NOT offload):**
  - `_notifyOpenCanvas(rel, result.content)` → `CanvasController.applyRemotePage` — the **open-canvas live merge** mutates live in-memory `CanvasPage` objects (painter/undo refs). Can't cross an isolate.
  - Orchestration: echo suppression (`drive.recordRemote`), `writeAtomicPublic` disk write, `_applyPurgeMarkers`, `_markDirty`/`dataVersion`, all Drive API calls.
- **Fallback:** any isolate failure → run `reconcile` inline (same guard style as the page-JSON offload — a hiccup must never drop a merge).

### DON'T BREAK — load-bearing sync-correctness rules (memorize before touching sync)
- Deletion is **always soft-delete** (set `deletedAt` + bump `rev`, keep the file); a hard-removed entry loses LWW and gets resurrected.
- Every element-mutating op must `_stamp` (bump rev/updatedAt/deviceId); every element removal writes an `erased`/`deletedObjects` tombstone in the same op.
- Stroke/object deletion is **rev-based LWW** (`EraseTombstone.rev`; element dead only while `element.rev <= tombstone.rev`). Undo/redo never removes a tombstone — it re-revs.
- Sync-write path must use `writeAtomicPublic`/`writeAtomicBytesPublic` — **NOT** `savePage`/`saveNotebook` (those `bumpRev` + re-trigger `onLocalFileSaved` → an upload **echo loop**).
- `purgedAt` is grow-only / earliest-wins; the **marker + `isPurgedContentPath` filter** enforce purges, NOT the Drive folder-delete (which is now best-effort per-item after the 403 fix).
- Merge merges: `notebooks.json` = union by id + per-id LWW; `section/canvas.json` = single-doc LWW `(rev,updatedAt,deviceId)`; page files = set-union of immutable strokes + grow-only erase tombstones + LWW text/image filtered by `deletedObjects`.

### Tests that MUST stay green
`merge_engine_test`, `canvas_controller_test`, `partial_eraser_test`, `split_paste_test` (+ the whole suite, currently **199 pass**).

### Phase 2 — measure, then address the remainder
After Phase 1, re-test on device. If jank remains, the rest of the sync-loop cost is likely: (a) processing the Drive **changes feed** + resolving fileIds in the pull loop, and (b) the **upload push** (I/O + Drive folder bookkeeping). Prefer **yield/batch** (process changes in chunks so a burst can't block a frame) over more isolates. Measure first — don't guess.

### GC (garbage collection) — SEPARATE, later
`NotebookService.runGarbageCollection` (notebook_service.dart:2138) walks the **whole store** on **app launch** + after full resync to purge tombstones >30 days old. It's the **launch-time** jank, not the sync-time pain. Offload its heavy read/decode scan to an isolate later (keep the mutations — purge, dir deletes, journal, Drive — on-main). Only if launch feels slow.

---

## 📋 Rest of the backlog (organized, not urgent)

### PDF export (further hardening — the giant-notebook OOM)
Known limit: a *very large* notebook still OOMs (~128 MiB) — Syncfusion builds the whole PDF in memory (`save()` = one byte array, no streaming), it's copied across the isolate, and Android SAF save needs the bytes → peak ≈ 2× the PDF. Options if it bites:
- **Temp-file output** (moderate risk): isolate writes the PDF to a temp file + returns the path (halves peak — no cross-isolate copy, no main hold; mobile still reads 1× for SAF). Touches `exportPdfInIsolate` return type + `runTreeExport` (pdf_export_ui.dart) + `canvas_screen._exportPdf` + the isolate result protocol + `pdf_export_isolate_test`. **Use `Directory.systemTemp`** (dart:io, works in the test + isolate — no path_provider stub needed).
- **Per-section / per-canvas export** = the real fix for extremes (shrink the job).
- A friendly **"too large — export a section"** message instead of the current silent fail.

### Import streaming (#4b)
`.omninote` **import** still decodes the whole zip in memory + copies the map back (symmetric to the export OOM). Stream-extract each entry to disk in the isolate if importing huge bundles becomes a problem.

### Open-with-PDF follow-ups
- **Linux `.desktop` `MimeType=application/pdf` + Windows registry** file-association (installer/packaging) so the app shows in "Open with" there. Runtime argv handling is already done; the OS-registration must be build-verified.
- **macOS sandbox** file-read verify in a **release** build (open-with should be granted; unverified).
- Suppress the starter blank **"Canvas 1"** that `createSection` seeds into the auto-created "Quick Section".

### Build / release infra (high practical value — stops uninstall/data-loss)
- Make **release signing consistent** (`key.properties` → `SECRETS/release.jks`, and CI always signs with it) so future updates install *over* the previous with no uninstall. User already hit the debug→release signature mismatch (forced uninstall).
- Optional: a **debug flavor with a separate `applicationId`** so `flutter run` dev-testing doesn't clash with the real release install.

### Perf backlog (from [[project_performance_backlog]])
- **#8** incremental `notebooks.json` writes (minor).
- **#9** lazy ItemTreeView — **REVIEWED + DEFERRED** (real win needs a risky multi-host sliver refactor; animations must survive; not worth it now).
- **#7** = this sync-isolate task (merge + GC).
- **#10** minor: painter O(all pages) visibility scan; Drive `listAllFiles` offload.
- **Parked:** live-stroke per-frame recompute (needs a frozen-prefix outline; genuinely hard; the decimation attempt jiggled and was reverted).

### KEEP AS-IS (user preferences — do NOT "fix")
- **Ink two-step undo** (bg change + recolor are separate ops) — user prefers this; **do not merge into one undo.**
- Adaptive ink visibility applies to **Pen / Highlighter / Text** individually (user's final choice includes highlighter).
- **Default target** is a **device-local pointer** (`SettingsService.defaultNotebookId`, never synced) — marking a synced notebook default does **NOT** make it local-only. Only the fallback **"Quick Notes"** is local-only.

---

## 🔒 Other gotchas worth remembering
- `exportBundle` now returns a **temp-file path** (streaming), not bytes — callers move/copy/read the file.
- `createCanvasFromPdf(section, name, bytes, {onProgress})` seeds a canvas from a PDF with **no blank starter page**.
- Progress UI is `ProgressOverlay` (`lib/utils/progress_overlay.dart`) — a root-Overlay floating ring, bottom-right (mobile: above nav bar). `progress_banner.dart` was deleted.
- Keep **CLAUDE.md** and **KNOWN_ISSUES.md** in sync with changes. See [[feedback_maintain_docs]].
