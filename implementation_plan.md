# OminiNote Sync Architecture v2 (Corrected)

**Scope:** Real-time, two-way sync for a Flutter note app (Android, iOS, Windows, macOS, Linux) using Google Drive as the source of truth. No custom server.

**Honest guarantee statement:** No offline-capable system can be "100% conflict-free." This design instead guarantees:

1. **Convergence** — all devices reach the identical state after syncing, regardless of edit order or offline duration.
2. **No silent data loss** — every stroke and object survives a merge; deletions only happen via explicit tombstones.
3. **Rare, recoverable conflicts** — the only true conflicts (same field edited on both sides) resolve deterministically, and anything ambiguous falls back to a *conflicted copy* the user resolves manually.

---

## 1. Data Model & Drive Layout

### 1.1 Drive folder strategy

Use the **`appDataFolder`** scope (hidden app-private space) as the default. It cannot be corrupted by users renaming/moving files in the Drive UI, and it avoids filename-collision issues. Offer an optional "Export/Backup to visible Drive folder" feature separately for user peace of mind.

```
appDataFolder/
  manifest.json                 # notebooks + folder tree + section refs
  sections/<sectionId>.json     # page list & ordering for one section
  pages/<pageId>.json           # stroke/content data for one canvas
  assets/<assetId>.<ext>        # binary blobs (PDF, images) — immutable
```

Splitting pages from hierarchy is kept from v1: concurrent drawing on *different* pages never conflicts because they live in different files.

### 1.2 Critical rule: track Drive files by `fileId`, never by name

Drive filenames are **not unique** — two devices can create two files both named `manifest.json`. Every device maintains a local index:

```json
// local: drive_index.json
{
  "manifest": "1AbCdEf...",
  "sections/sec_01H...": "1XyZ...",
  "pages/pg_01H...": "1QrS..."
}
```

- Uploads use `files.update(fileId)` when the id is known, `files.create` only when it isn't.
- **Duplicate healing:** during full resync, if two Drive files claim the same logical object (same internal `id` field), download both, merge them with the standard merge engine, write the result to the older `fileId`, and trash the newer one. This self-heals the create/create race.

### 1.3 Common object envelope

Every JSON file and every object inside it carries:

```json
{
  "schemaVersion": 1,
  "id": "nb_01HZX...",        // ULID/UUID, generated once, never reused
  "rev": 14,                   // monotonic counter, +1 on every local edit
  "updatedAt": 1751871234000,  // wall clock, ms epoch — advisory only
  "deviceId": "dev_a3f9...",   // stable per-install random id
  "deletedAt": null            // non-null ⇒ tombstone
}
```

### 1.4 manifest.json

```json
{
  "schemaVersion": 1,
  "notebooks": [ { ...envelope, "title": "...", "color": "...", "folderTree": [...], "sectionRefs": ["sec_.."] } ],
  "tombstones": [ { "id": "nb_...", "type": "notebook", "deletedAt": 1751000000000, "rev": 9, "deviceId": "dev_.." } ]
}
```

Tombstones for notebooks, folders, and sections live here. Tombstones for pages live in their section file. Tombstones for strokes live in their page file (see 1.6).

### 1.5 sections/<id>.json

```json
{
  "schemaVersion": 1,
  "id": "sec_...",
  "rev": 22,
  "pages": [ { "id": "pg_...", "title": "...", "order": "0|hzzzzz:", "rev": 5, "updatedAt": ..., "deviceId": "...", "deletedAt": null } ],
  "tombstones": [ ... ]
}
```

`order` uses **fractional indexing** (lexicographic keys like `"0|a0"`, `"0|a0V"`) instead of integer positions, so two devices reordering different pages offline merge without renumbering conflicts.

### 1.6 pages/<id>.json — the stroke-set model (replaces locking)

This is the core correction. A page is a **grow-only set of immutable strokes plus erase tombstones** — effectively a set CRDT. Ink merges trivially under this model; there is nothing "mathematically complex" to merge.

```json
{
  "schemaVersion": 1,
  "id": "pg_...",
  "rev": 87,
  "background": { "type": "grid", "rev": 2, "updatedAt": ..., "deviceId": "..." },
  "strokes": [
    {
      "id": "st_dev_a3f9_000381",   // deviceId + local counter ⇒ globally unique, no coordination
      "createdAt": 1751871111000,
      "z": "0|b3:",                  // fractional index for draw order
      "props": { "tool": "pen", "color": "#1a1a1a", "width": 2.0,
                 "rev": 1, "updatedAt": ..., "deviceId": "..." },
      "points": "base64/delta-encoded point data"   // IMMUTABLE after creation
    }
  ],
  "erased": [ { "strokeId": "st_...", "erasedAt": ..., "rev": 3, "deviceId": "..." } ],
  "objects": [ /* text boxes, images — same envelope, LWW per object */ ]
}
```

Rules:

- **Drawing** appends strokes. `points` never mutate. Partial-stroke erasing is modeled as: erase original stroke + create new stroke(s) for the surviving segments (this is what most ink apps do internally).
- **Erasing** appends to `erased[]` — an operation, not a removal. Rendering = `strokes − erased`.
- **Moving/recoloring** a stroke mutates only `props` (bumping its `rev`). This is the *only* per-stroke LWW surface, and it's rare and low-stakes.
- Text boxes and embedded images are objects with the standard envelope; whole-object LWW, with a conflicted-copy fallback for simultaneous text edits (see §3.4).

---

## 2. Clocks & Ordering — never trust wall time alone

Device clocks drift and users change them. All comparisons use the tuple:

```
winner = max by (rev, updatedAt, deviceId)   // lexicographic tuple compare
```

- `rev` is a per-object monotonic counter — the primary signal (a hybrid-logical-clock in spirit).
- `updatedAt` breaks ties when both sides made the same number of edits.
- `deviceId` is the final deterministic tiebreaker so both devices pick the **same** winner (critical for convergence — if tiebreaking differed per device, they'd ping-pong forever).

**Rev merge rule:** when local (rev 5) loses to remote (rev 7), the local copy adopts rev 7. When local *wins* a merge that consumed remote changes, set `rev = max(localRev, remoteRev) + 1` before pushing, so the pushed version dominates both ancestors.

---

## 3. The Merge Engine

Called whenever a remote file version arrives. Never overwrite blindly; never discard remote data.

### 3.1 Hierarchy merge (manifest.json, sections/*.json) — Union + Tombstones

```
function mergeHierarchy(local, remote):
    all = {}   // id → object
    for obj in local.items + remote.items + local.tombstones + remote.tombstones:
        if obj.id not in all:
            all[obj.id] = obj
        else:
            all[obj.id] = winner(all[obj.id], obj)   // tuple compare §2;
                                                      // a tombstone is just an object whose
                                                      // deletedAt is set — it competes on (rev, ts, dev)
    merged.items      = [o for o in all if o.deletedAt == null]
    merged.tombstones = [o for o in all if o.deletedAt != null]
    return merged
```

Consequences:

- **Delete on A + untouched on B** → tombstone (newer rev) wins → deleted everywhere. The v1 resurrection bug is gone.
- **Delete on A + edit on B (offline)** → whichever has the higher tuple wins. To be safe against losing edited content, apply one asymmetric guard: *if a tombstone beats an object that contains child content edited after the deletion, restore the object and flag it in the Conflicts Inbox* ("Notebook 'Physics' was deleted on Pixel 8 on 07/05/26 but edited here — kept. Delete again?"). Losing a delete is annoying; losing edits is unacceptable.
- **Same notebook renamed on both sides** → deterministic LWW; the losing title is recorded in the Conflicts Inbox as an informational entry.

### 3.2 Page merge — Set Union (no locks)

```
function mergePage(local, remote):
    merged.strokes = unionById(local.strokes, remote.strokes)
        // identical id ⇒ identical points (immutable); props resolved by winner()
    merged.erased  = unionByStrokeId(local.erased, remote.erased)
    merged.objects = unionById + winner() per object          // §3.1 logic
    merged.background = winner(local.background, remote.background)
    merged.rev = max(local.rev, remote.rev) + (1 if localContributed else 0)
    return merged
```

Two people drawing on the same page offline → both sets of strokes appear. One draws, one erases the same stroke → erase wins (erase set is grow-only). This is deterministic, order-independent, and idempotent — the three properties that make the write-back loop in §5.4 converge.

### 3.3 Why the v1 lock is removed

Drive has **no atomic compare-and-swap**: two devices can both read "no lock," both create `page.lock.json`, and both believe they own the page (Drive even permits duplicate names). Locks are invisible to offline devices — the main conflict source — and the v1 rule "discard remote changes while I hold the lock" silently destroys data on stale/raced locks. The stroke-set model makes locking unnecessary. Optionally keep a **presence file** (`presence/<pageId>.json`, TTL 2 min) purely as a soft UI hint ("Sara is editing this page") — it must never gate writes.

### 3.4 Manual fallback — Conflicted Copies + Conflicts Inbox

For the genuinely ambiguous cases the automatic merge should not guess on:

- The same **text box** edited on both devices (character-level text merging is out of scope): keep the winner in place, and materialize the loser as a new text object titled *"Conflicted copy (Pixel 8, 07/07/26 14:32)"* placed offset below the winner. Log to the Inbox.
- A remote file that fails schema validation / JSON parse: quarantine it as `conflicts/<fileId>.json`, keep serving local, log to the Inbox, never crash the sync loop.
- Tombstone-vs-edit restores from §3.1.

The **Conflicts Inbox** is a simple screen listing these events with "Keep mine / Keep theirs / Keep both" actions. This satisfies the manual-resolution requirement without making manual action ever *required* for sync to proceed.

---

## 4. Push Pipeline (Local → Drive)

### 4.1 Atomic local writes

Every local save writes to `file.tmp` then `rename()` over the target (atomic on all five platforms). A crash mid-save can never corrupt a note.

### 4.2 Dirty journal (not just an in-memory queue)

The v1 in-memory `UploadQueue` loses pending uploads if the app is killed. Instead, persist a journal:

```json
// local: sync_journal.json
{ "dirty": { "pages/pg_01H...": { "since": 1751871234000 } },
  "lastPushedRev": { "pages/pg_01H...": 86 } }
```

A file is marked dirty on local mutation and cleared only after a confirmed 2xx upload. On startup, the journal is replayed — nothing is ever lost to a process kill.

### 4.3 Debounce & flush policy

- **Hierarchy files:** 800 ms debounce (cheap, small).
- **Page files while actively drawing:** 3–5 s debounce — 800 ms will hammer Drive's per-user quota (~12,000 queries/min sounds high, but per-user-per-app write bursts throttle much earlier in practice).
- **Immediate flush triggers:** page closed, app backgrounded (`AppLifecycleState.paused`), section switched, manual "Sync now."

### 4.4 Execution & error handling

Drain the journal sequentially (one upload at a time preserves causal order: page before its section before the manifest is not required for correctness — merges fix any order — but it minimizes transient dangling refs).

- Network error / 5xx: exponential backoff **with jitter** (2 s, 4 s, 8 s, 16 s, 32 s cap), job stays in journal.
- **403 rate-limit / 429:** back off using the `Retry-After` header if present; slow the debounce dynamically.
- **404 on `files.update`** (file trashed remotely or index stale): fall back to `files.create`, update `drive_index.json`.
- Uploads use multipart (`files.update` with media) and record the returned `headRevisionId` + `version` for echo suppression (§5.3).

## 5. Pull Pipeline (Drive → Local)

### 5.1 Polling with the Changes API

While foregrounded, poll `changes.list(pageToken)` every 30 s (also on: app resume, window focus, connectivity regained, pull-to-refresh). Store the returned `newStartPageToken` durably *after* all changes in the batch are applied — never before, or a crash skips changes.

### 5.2 Full-resync path (mandatory, built once, used twice)

`changes.list` can return **HTTP 410 Gone** — the token expired. You must have a fallback:

```
fullResync():
    list all files in appDataFolder (files.list, paginated, fields: id,name,headRevisionId,modifiedTime)
    heal duplicates (§1.2)
    for each file: download → mergeEngine → mark dirty if local contributed
    pageToken = changes.getStartPageToken()
```

This exact routine is also the **first-launch bootstrap** on a new device and the "repair sync" button in settings. One code path, three uses.

### 5.3 Echo suppression

After pushing, Drive will report your own write as a change. For each file, store the `headRevisionId` you last uploaded; when a change notification arrives with that same revision id, skip the download. (Never compare by `modifiedTime` alone.)

### 5.4 Write-back convergence loop

There is no upload precondition/CAS on Drive, so a lost-update race is possible: you merge against revision N while another device uploads N+1. The loop that makes this safe:

```
onRemoteChange(file):
    remote = download(file)
    merged = mergeEngine(local, remote)
    save local (atomic)
    if merged != remote content:      // local contributed something Drive lacks
        mark dirty → push pipeline
    // if another device raced us, its upload arrives as a *new* change,
    // we merge again; because the merge is idempotent, commutative, and
    // monotone (§3), every device converges in ≤ a few round trips.
```

## 6. Platform Lifecycle Reality (this replaces the v1 "Background Service")

A persistent 30-second background loop **does not exist** on modern mobile OSes. Design for it:

| Context | Strategy |
|---|---|
| App foreground (all platforms) | Full loop: 30 s poll + debounced push |
| App → background (mobile) | Immediate journal flush during the ~few seconds of grace; schedule a one-shot `workmanager` task if dirty items remain |
| Android background | `workmanager` periodic task (15 min minimum, constraint: network) — best effort, Doze may delay it |
| iOS background | `BGAppRefreshTask` — opportunistic, OS-scheduled, never guaranteed |
| Desktop (Win/mac/Linux) | Real `Timer.periodic` loop works; also sync on window focus |
| All | Sync on launch, on resume, on connectivity regained |

**Design consequence:** devices may not sync for days. That's fine — §3's merge is specifically built to tolerate arbitrarily stale devices. Never assume freshness anywhere in the code.

## 7. Authentication

### 7.1 Mobile (Android/iOS)

`google_sign_in` with scope `drive.appdata`. Silent restore via `signInSilently()` on launch. Tokens live in OS-managed secure storage automatically.

### 7.2 Desktop (Windows/macOS/Linux)

Loopback OAuth (open browser → `http://127.0.0.1:<port>/callback`) with **PKCE** and a Desktop-type OAuth client.

- Store `refresh_token` in **`flutter_secure_storage`** (Keychain / Windows Credential Manager / libsecret) — **never** in `settings.json`. Anyone with the refresh token has the user's Drive appdata forever.
- Access token (≈1 h) refreshed via `oauth2.googleapis.com/token`; refresh proactively at 5 min before expiry, and reactively on any 401.

### 7.3 Refresh-token realities

Refresh tokens are **not** eternal. They die on: user revocation, password change (sometimes), ~6 months of disuse, and — the classic dev-time trap — **after 7 days if the OAuth consent screen is still in "Testing" status**. Publish the app in Google Cloud Console before beta. On `invalid_grant`: transition sync state to `AuthRequired`, show a non-blocking "Reconnect Google Drive" banner, keep the app fully usable offline, and keep journaling edits for later push. Never crash, never block note-taking.

## 8. UI Indications

Sync state machine: `Idle(synced) → Syncing → Idle`, plus `Offline`, `AuthRequired`, `Error(retrying)`. Surface as:

- Global `SyncStatusIcon` in the primary AppBar (all platforms), tap → last-sync time + pending-item count + "Sync now" + "Repair sync (full resync)".
- Per-page subtle "pending" dot while that page sits in the dirty journal.
- **Conflicts Inbox** entry point with a badge when non-empty (§3.4).
- Optional presence hint on canvas ("Editing on another device") — informational only.

## 9. Garbage Collection & Compaction

- **Tombstones:** GC after 90 days *and* only once every registered device has synced past the tombstone's timestamp (track a tiny `devices.json` with per-device `lastSyncAt`; drop devices silent > 90 days). If in doubt, keep the tombstone — they're tiny.
- **Erased strokes:** compact a page (physically drop stroke data for erased strokes, keep the erase tombstone ids) when erased count > 500 or file > 1 MB, using the same 90-day/all-devices rule.
- **Assets:** an asset is deletable when no live page references it and every referencing page's tombstone has passed GC. Run asset GC only after a successful full resync to avoid deleting something a stale device still references.

## 10. Failure Matrix (what happens when)

| Scenario | Outcome |
|---|---|
| Two devices draw on same page offline | Union — both devices' strokes appear. No conflict. |
| A erases a stroke, B recolors it, both offline | Erase wins (grow-only erase set). Deterministic. |
| A deletes notebook, B unaware | Tombstone wins → deleted everywhere. |
| A deletes notebook, B edits it offline | Restore + Conflicts Inbox prompt (§3.1 guard). |
| Both rename same notebook | Deterministic LWW by (rev, ts, deviceId); loser logged to Inbox. |
| Both edit same text box | Winner stays; loser becomes a conflicted-copy object (§3.4). |
| Both devices create `manifest.json` on first run | Duplicate healing merges & trashes one (§1.2). |
| App killed mid-upload | Persistent journal replays on next launch (§4.2). |
| Changes token expired (410) | Full resync path (§5.2). |
| Device clock wrong by hours | `rev` counter dominates comparisons; damage limited to rare exact-rev ties (§2). |
| Refresh token revoked / 7-day testing expiry | `AuthRequired` banner; offline editing + journaling continue (§7.3). |
| Corrupt/unparseable remote file | Quarantined; sync continues; Inbox entry (§3.4). |

## 11. Implementation Order & Testing

**Phases**

1. Local layer: schemas, envelopes, atomic writes, stroke-set page model, fractional indexing.
2. Merge engine as a **pure, side-effect-free library** (this is 80% of correctness and 100% unit-testable).
3. Auth (mobile + desktop PKCE + secure storage).
4. Push pipeline with persistent journal.
5. Pull pipeline: changes polling, echo suppression, full resync/bootstrap.
6. Lifecycle wiring (workmanager / BGAppRefresh / desktop timer) + status UI.
7. Conflicts Inbox, presence hints, GC.

**Testing the merge engine (do this before touching Drive):** property-based tests asserting, for random edit histories A and B: `merge(A,B) == merge(B,A)` (commutative), `merge(A, merge(A,B)) == merge(A,B)` (idempotent), and no live stroke ever disappears without a matching erase/tombstone. Then integration tests with two simulated devices sharing a fake in-memory "Drive" that injects: reordered deliveries, duplicate files, 410s, 403 rate limits, and mid-upload kills. If the merge engine passes property tests, everything above it is plumbing.

---

### Summary of corrections vs v1

Tombstones added (deletion resurrection fixed) · pessimistic locking removed and replaced by a stroke-set CRDT-style page model · `rev` counters added so wall-clock drift can't corrupt LWW · deterministic deviceId tiebreak for convergence · fileId tracking + duplicate healing (names aren't unique) · 410 full-resync/bootstrap path · echo suppression via `headRevisionId` · persistent dirty journal (survives process death) · realistic mobile background model (no 30 s background loop) · refresh token moved to secure storage + 7-day testing-mode gotcha handled · conflicted copies + Conflicts Inbox for manual resolution · GC rules for tombstones, erased strokes, and assets.
