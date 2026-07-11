# Sync scope, multi-account & sharing — plan

Three related features share one foundation: **each notebook knowing its sync
target**. Tracked here; update as phases land.

## Status (updated 2026-07-11)

- ✅ **Phase 0 — per-device local-only** — done & shipped.
- ✅ **Phase 1 — sign-out safety** — done & shipped (closes the ★ must-have).
- ✅ **Phase 2 — multi-account (simultaneous)** — **done & three-device-verified**
  (A-hybrid). 2a auth foundation, 2b model `syncTarget`, 2c per-account
  Drive/Sync routing + scoped index merge + picker, and a **2e account-model
  redesign** driven by real bugs: no default account (**account chosen at
  creation**), **"Sync to a different account" = MOVE with sync-down + deep
  re-id** (new notebook/section/canvas ids so a moved notebook shares no identity
  — else the canvas-id-keyed live-merge bridged edits across accounts), and
  **per-account removal** (all accounts equal, purge-this-account's-copies).
  Key auth fix: **`forceCodeForRefreshToken: true`** so multiple devices can use
  the same account (no `disconnect()`/revoke). Perf fix: batched sync-journal
  saves.
- ✅ **Phase 3 — link sharing** — done & shipped, but via a different mechanism
  than originally sketched below (bundle transfer, not HTTPS link + Drive ACLs —
  see "Verified constraint"). Stage 1: **send a copy** via a `.omninote` bundle.
  Stage 2: tap-to-open on Android. Stage 3: an `omininote://` share link (host
  bundle → download → import). Desktop open-with follow-on: Linux wired +
  verified; Windows (Inno Setup installer) and macOS (`Info.plist` +
  `AppDelegate.swift`) implemented but **unverified** — no local Windows/macOS
  toolchain, needs a CI-built artifact or a real machine to confirm registration
  + launch-arg routing. See `KNOWN_ISSUES.md` "Notebook sharing" for shipped
  limitations.

**Open-canvas refresh:** fixed — a pushed `CanvasScreen` listens to
`SyncService.dataVersion` and pops (with a message) when its notebook is
tombstoned/moved away; the desktop shell clears its selection in `_loadAll`
(`CanvasScreen` gets an `embedded` flag so it doesn't self-pop when hosted).
**Remaining caveats (not blocking)** in `KNOWN_ISSUES.md` "Multi-account sync":
the move's inherent lagging-unsynced-device edge + orphaned old-Drive content.

**Phase 3 shipped as "send a copy" only** (no scope risk) — live-collab (v2:
open + edit a notebook someone else owns, via the Google Picker / a `drive`
scope upgrade) was never started and isn't currently planned; see the
constraint section below for why it's the harder path.

```
          Notebook.syncTarget   ← foundation (small model change)
           /            \
  Sign-out safety     Multi-account (Auth/Drive/Sync become
  (rules on target)    account-scoped: N accounts, N Drive trees)
                              |
                       Link sharing (live) via Drive ACLs
   (a "copy" share branches off early, needing neither)
```

## Verified constraint — `drive.file` scope + sharing

- **Sharer works:** `drive.file` has full rights over files it created, incl.
  `permissions.create` — we *can* grant another user view/edit on our files.
- **Recipient is the catch:** `drive.file` only exposes files the app created
  **or** the user opens via the Google **Picker**. A file merely *shared with*
  a user is **not** auto-visible to their `drive.file` app; folder sharing has
  quirks. → Live collaboration is possible but fiddly; a clean version may need
  the restricted `drive` scope (Google security assessment). **So: ship
  "send a copy" first; live-collab is a later, harder phase.**

## Model of "local-only" — **per-device**, not synced

A first attempt stored this in the notebook (synced `notebooks.json`), but that's
wrong: the other device still has the notebook as *synced*, its edits win the
LWW merge and flow back, and can even overwrite the flag. **Local-only is a
per-device decision** and lives in device-local `settings.json`
(`SettingsService.localOnlyNotebooks`, never synced):

- **Push:** skip a local-only notebook's content files; strip it from the
  uploaded `notebooks.json`.
- **Pull:** skip pulled content files for a local-only notebook (blocks the
  *download* direction too), and restore its local `notebooks.json` entry over
  any merge (`_preserveLocalOnly`) so a pulled index can't change it.
- **Re-enable:** removing local-only triggers a `fullResync` to catch up.

Result: marking a notebook local-only on device A fully disconnects it **on
device A** (both directions); device B is independent and can sync its own copy
(or mark its own copy local-only too).

Phase 2's per-notebook **account** binding (`syncTarget = <account-id>`) is a
separate, *synced* property — added then.

## Phases

- **Phase 0 — Per-device local-only (foundation).** Device-local
  `SettingsService.localOnlyNotebooks`; per-notebook **Make local-only / Enable
  cloud sync** toggle; `SyncService` blocks sync **both directions** for
  local-only notebooks (push + pull) and preserves their local index entry.
  *Done.*
- **Phase 1 — Sign-out safety.** *Done.* Sign-out dialog warns about unsynced
  edits and offers **"Remove downloaded notebooks"** (`purgeLocalSyncedNotebooks`
  — deletes local copies of synced notebooks WITHOUT tombstoning, keeps
  local-only ones) for a clean account switch + no accidental-delete
  propagation; on sign-out the Drive index + changes token reset so re-sign-in
  bootstraps. Two sync-correctness fixes found via this: (a) re-enabling a
  local-only notebook now `forgetNotebookHeads` + a *guaranteed* resync (a plain
  `repair` was dropped by the in-progress guard, so re-connected notebooks never
  pulled); (b) in-flight guards (`_pulling`/`_resyncing`/`_pushing`) are
  force-reset on sign-out **and** sign-in, so a sync interrupted by sign-out
  can't leave a flag stuck and permanently block the next session's pull (the
  "my edits go up but theirs never come down" bug).
- **Phase 2 — Multi-account (simultaneous).** `AuthService` holds multiple
  accounts; `DriveService`/`SyncService` become per-account (own root + index);
  per-notebook "which account" picker.
- **Phase 3 — Link sharing.** *Done, shipped differently than sketched here:*
  instead of an HTTPS link + in-app "Incoming share"/"Shared with me" screen,
  shipped as a `.omninote` bundle (send-a-copy) + an `omininote://` share link
  that hosts and imports that same bundle, plus OS-level open-with (tap a
  `.omninote` on Android, double-click on desktop) — see `KNOWN_ISSUES.md`
  "Notebook sharing" for the actual mechanism and its limitations. Live edit
  (open + edit someone else's notebook) remains unshipped.

## Phase 2 breakdown (historical — kept for reference)

Goal: be signed into several Google accounts at once; each notebook syncs to its
chosen account (or local-only). Current code assumes **one** account everywhere
(singletons: `AuthService`/`DriveService`/`SyncService` each hold one account,
one Drive root, one `drive_index.json`, one changes token, one poll timer).

### Auth approach — DECIDED: A-hybrid

Both devices must own a **refresh token per account** (`google_sign_in` v6 only
tracks one "current user", so it can't keep two accounts' tokens live for
simultaneous background sync). A-hybrid gets there while keeping native UX:

- **Android:** `google_sign_in` with `serverClientId: WEB_CLIENT_ID` shows the
  native picker and returns a **`serverAuthCode`**; exchange it once at
  `oauth2.googleapis.com/token` with `WEB_CLIENT_ID` + `WEB_CLIENT_SECRET`,
  `grant_type=authorization_code`, and **`redirect_uri=''`** (empty string — the
  classic serverAuthCode-exchange gotcha) → `refresh_token`. Thereafter refresh
  directly like desktop; never depend on `google_sign_in`'s current-user.
- **Desktop:** unchanged — Desktop client (`GOOGLE_CLIENT_ID`/`SECRET`) loopback.
- **Credentials:** all already in `.dart_defines.json` — no new Google Cloud
  client needed. (Considered & rejected: **A** = loopback everywhere, dropped the
  native Android picker + forced re-consent; **B** = keep single-current-user,
  fails the simultaneous-sync goal on Android.)

### Account identity

Key accounts by the Google **`sub`** (stable across devices for the same Google
account), not email (email can change). Desktop currently fetches only `email`
from userinfo → also read `sub`. Store `{sub, email, displayName, photoUrl}`;
`syncTarget` holds the `sub`.

### Sub-stages (each independently testable on the two-device rig)

**2a — Auth foundation (no routing yet).** `AuthService`: `account` →
`accounts: List<Account>` + `defaultAccountId` (used for new notebooks).
Per-account refresh-token storage in `flutter_secure_storage` keyed by `sub`
(desktop key `omninote_drive_refresh_token` → `..._<sub>`; migrate the existing
one). `getAuthHeaders(accountId)` refreshes that account independently (the
per-account collapse-concurrent-refresh guard too). Settings "Account" section
→ **list** (email/avatar + status + Remove) with **Add account**. *All sync still
targets the default account this stage — pure auth-layer change.*

**2b — Model + plumbing (no UI yet).** Add `Notebook.syncTarget = <accountId>?`
(synced in `notebooks.json`; **null is treated as "the default account"** at
read time — no eager mass-rewrite migration needed). `NotebookService`:
`setNotebookSyncTarget` (bumps rev so it propagates), `effectiveSyncTarget(nb) =
syncTarget ?? defaultAccountId`, and `syncedIndexJsonFor(accountId)` (filter the
index to that account's notebooks). **Precedence:** device local-only
(settings.json, per-device) **always wins** over `syncTarget` on this device.
*The **"Sync to…" picker moved to 2c** — a picker without routing is a confusing
half-state (pick account B, but sync still goes to default until 2c). So the
existing local-only toggle stays untouched in 2b; the picker ships with routing.*

**Reorg vs original plan:** the desktop refresh-token key migration is in **2a**
(done); `drive_index.json → drive_index_<acct>.json` and
`driveChangesToken → driveChangesTokens Map` move to **2c** (they only matter
once Drive is split per-account).

**2c — Per-account Drive + Sync routing + the picker (the big surgery).**
- The per-notebook **"Sync to…"** picker `[Local-only, Account A, Account B, …]`
  on Home + desktop sidebar (replaces the binary local-only toggle) — ships here
  so it's always backed by working routing.
- `DriveService` → **per-account instances** behind a registry keyed by
  accountId; each owns its root, `drive_index_<acct>.json`, folder cache, changes
  token. `_AuthedClient` binds to its account (`getAuthHeaders(accountId)`) — it
  has *no* account identity today, that's the seam.
- `SyncService` routes each dirty relPath to `syncTargetOf(notebookId)`'s
  DriveService (need a fast in-memory `notebookId → syncTarget` lookup).
  **Per-account** poll timers + guards (`_pulling`/`_resyncing`/`_pushing`) — one
  account's sync must never block another's.
- `notebooks.json`: **per-account on Drive** (each account's Drive sees only its
  own notebooks) but **one file locally**. Generalize `syncedIndexJson` →
  `syncedIndexJsonFor(accountId)` (filter by syncTarget); generalize
  `_preserveLocalOnly` → a **scoped merge** that reconciles only that account's
  subset and preserves every other account's / local-only entry (the current
  union-merge assumes remote is the *whole* picture — naively applying a per-
  account subset would drop other accounts' notebooks). Stamp `syncTarget=X` on
  notebooks pulled from account X's index.

**2d — Safety + tests.** Per-account "Remove account" reuses Phase-1 sign-out
safety (unsynced warning + purge that account's local copies, keep others).
Re-verify every Phase-1 edge case **per account** (removing one account mustn't
stall another's poller/guards). Extend `merge_engine_test` for the scoped-index
merge. Two-device verification (Linux desktop + Android over USB) per change.

**Migration checklist (2b):** desktop refresh token, `drive_index.json`,
`driveChangesToken`, notebooks' null `syncTarget` — all four migrate to the
default account on first launch after upgrade.
