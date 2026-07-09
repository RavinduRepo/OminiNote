# Sync scope, multi-account & sharing — plan

Three related features share one foundation: **each notebook knowing its sync
target**. Tracked here; update as phases land.

## Status (updated 2026-07-10)

- ✅ **Phase 0 — per-device local-only** — done & shipped.
- ✅ **Phase 1 — sign-out safety** — done & shipped (closes the ★ must-have).
- ⏭️ **Phase 2 — multi-account (simultaneous)** — **NEXT** (not started). See the
  breakdown at the bottom.
- ⬜ **Phase 3 — link sharing** — not started.

**Resume here (Phase 2):** the big piece is making auth/Drive/Sync
account-scoped. Start with the sub-plan in "Phase 2 breakdown" below and confirm
the auth approach before writing code — it's real surgery on `AuthService` (one
account today) and `DriveService` (one root + one index today).

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
- **Phase 3 — Link sharing.** HTTPS link (`.../open?...`) → in-app **Incoming
  share** screen (item, who shared, permission) → **Add to my notes** (copy) or
  **Open shared** (live). Shared items live in a **"Shared with me"** area on
  Home. v1 = copy (no scope risk); v2 = live edit (Picker flow / scope upgrade).

## Phase 2 breakdown (start here next session)

Goal: be signed into several Google accounts at once; each notebook syncs to its
chosen account (or local-only). Current code assumes **one** account everywhere.

**Confirm first (decisions before code):**
- How to add a 2nd+ account: Android `google_sign_in` supports multiple; desktop
  PKCE stores one refresh token today → need a **token set per account** in
  `flutter_secure_storage` (keyed by account id).
- Where a notebook's account lives: `Notebook.syncTarget = <account-id>`
  (**synced** in notebooks.json, so the binding is consistent across devices) —
  distinct from Phase 0's device-local local-only set.

**Work items (rough order):**
1. `AuthService`: from one `account` to a **list of accounts** + a "default"
   (for new notebooks). Per-account token storage/refresh. Keep the single
   `account` API working (compat) or migrate call sites.
2. `DriveService`: from one root+index to **per-account instances** (each its own
   `omininote/` root folder + `drive_index_<acct>.json` + changes token). Likely
   a `DriveService` per account, keyed by account id.
3. `SyncService`: route each dirty relPath / pulled file to **its notebook's
   account's** DriveService. `notebooks.json` gets split/filtered per account
   (each account's Drive only sees its own notebooks — like the local-only
   filter, generalized).
4. Model + UI: `Notebook.syncTarget = <account-id>`; a per-notebook **"Sync to…"**
   picker (accounts + Local-only); Settings shows the list of connected accounts
   with add/remove.
5. Migration: existing notebooks (syncTarget null) → the first/default account.

**Watch-outs:** the changes-poll + index are per-account now (multiple pollers);
echo-suppression + `_pulling/_resyncing` guards must be per-account too, or one
account's sync blocks another. Test the same edge cases as Phase 1 (sign-out of
one account while others stay).
