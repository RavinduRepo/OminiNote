# Sync scope, multi-account & sharing — plan

Three related features share one foundation: **each notebook knowing its sync
target**. Tracked here; update as phases land.

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
- **Phase 1 — Sign-out safety.** Warn if a synced notebook has unflushed edits;
  offer to remove local copies of notebooks fully synced to the account being
  left; local-only notebooks always stay. Closes the accidental-delete gap.
- **Phase 2 — Multi-account (simultaneous).** `AuthService` holds multiple
  accounts; `DriveService`/`SyncService` become per-account (own root + index);
  per-notebook "which account" picker.
- **Phase 3 — Link sharing.** HTTPS link (`.../open?...`) → in-app **Incoming
  share** screen (item, who shared, permission) → **Add to my notes** (copy) or
  **Open shared** (live). Shared items live in a **"Shared with me"** area on
  Home. v1 = copy (no scope risk); v2 = live edit (Picker flow / scope upgrade).
