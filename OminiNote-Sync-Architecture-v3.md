# OminiNote — Google Drive Sync Architecture v3

This document defines the final, hardened sync architecture for OminiNote, adapting the original v1 PDF concepts (Changes API, fine-grained object syncing) and upgrading them with Stroke-Set CRDTs and standard envelopes to mathematically eliminate data loss and "ghost resurrections."

---

## 1. Data Hierarchy
The core hierarchy of the application remains unchanged, but how it maps to sync units is strictly defined:

```text
Notebook
 └─ Section
     └─ Canvas (infinite in one direction, paginated in the other)
         └─ Page (unit of sync)
```

* **A Canvas** behaves like OneNote's infinite canvas, composed of discrete **Pages** that the user scrolls through and appends to.
* **Each Page** is a single JSON file containing its content: text blocks, images, PDFs, and strokes.
* **The Page** is the atomic unit of sync for canvas data, which minimizes conflict surfaces and sync payload size.

---

## 2. The Universal Sync Envelope (Replaces `last_modified` rules)
To solve clock skew and identical millisecond edits, *every* synced object in the app (Notebooks, Sections, CanvasPages, and even individual Strokes) carries a standard synchronization envelope.

### Required Fields:
* `schemaVersion` (int): Data model schema for future migrations.
* `id` (String): Globally unique, permanent identifier (UUID v4 or nanoid). Never reused.
* `rev` (int): Monotonic counter incremented locally on *every edit*. (Replaces `content_version`).
* `updatedAt` (DateTime): Timestamp of the last edit.
* `deviceId` (String): The UUID of the device that made the edit. Required for tie-breaking.
* `deletedAt` (DateTime?): A tombstone flag. If present, this object has been explicitly deleted.

**Why this is better than v1:** Applying this envelope to *every* object (not just the page file) allows us to safely merge objects inside a page, rather than just overwriting the whole page file.

---

## 3. Conflict Resolution & Merging (Stroke-Set CRDT)
The v1 architecture relied on pure Last-Write-Wins (LWW) at the file level, which silently deleted data if two devices edited offline simultaneously. v3 solves this using a **Union-Based / Stroke-Set CRDT**.

### How CanvasPages Merge:
1. **Strokes are Sets:** A `CanvasPage` does not store a flat list of elements. It stores a list of `strokes` and a list of `objects` (Text/Images).
2. **Set Union:** When two devices sync the same page, the `MergeEngine` takes the *Union* of both stroke sets. No strokes are ever lost; strokes drawn on the phone and strokes drawn on the desktop are cleanly combined.
3. **LWW Fallback:** For metadata (like page background color), we fall back to Last-Write-Wins using a deterministic tie-breaker:
   * **Rule:** `rev` > `updatedAt` > `deviceId`
   * We check the revision counter first (ignores clock skew). If revisions match, we check timestamps. If timestamps match, we deterministically pick based on `deviceId`.

---

## 4. Deletions & Tombstones (Fixing "Ghost Resurrection")
In older architectures, deleting an offline file caused it to resurrect when syncing with another device that still had it. 

### Tombstone Rules:
1. **Never actually delete:** When a user deletes a Notebook, Section, or even uses the eraser on a stroke, the app **does not** delete the record.
2. **Mark as Deleted:** It sets the `deletedAt` timestamp (creating a "Tombstone"). 
3. **Enforcement:** When syncing, if Device A sends a Tombstone for "Page X", Device B sees the Tombstone, compares it to its local copy, and deletes its local copy to comply. Deletions are strictly enforced.
4. **Garbage Collection (GC):** To prevent storage bloat, any tombstone older than 90 days is permanently purged from the system.

---

## 5. Change Tracking via Drive Changes API (Pull Pipeline)
Instead of manually scanning Google Drive folders for changes (which is incredibly slow and burns API quota), OminiNote uses the **Google Drive Changes API**.

1. **The Page Token:** The app stores a `pageToken` locally. 
2. **Polling for Deltas:** When syncing, the app asks Drive: *"Give me everything that changed in the AppData folder since `pageToken`."*
3. **Efficiency:** Drive instantly returns a tiny delta list (e.g., "File A modified, File B deleted"). The app only downloads those specific files.
4. **Updating:** The app updates its `pageToken` and merges the downloaded files via the `MergeEngine`.

---

## 6. Implementation Phases (Roadmap)
This architecture is implemented in the following phases:

* **Phase 1: Local Layer & Models (Done)** - Define Envelopes, refactor `CanvasPage` to support Stroke-Sets.
* **Phase 2: Merge Engine (Done)** - Build the pure `MergeEngine` logic (`compareRevisions`, `mergePage`).
* **Phase 3: Authentication & Secure Storage (Next)** - Implement `flutter_secure_storage` and loopback OAuth for Desktop.
* **Phase 4: Push Pipeline** - Create `sync_journal.json` to queue offline edits and push them to Drive with exponential backoff.
* **Phase 5: Pull Pipeline** - Implement the `changes.list` API polling and full-resync paths.
* **Phase 6: Lifecycle & UI** - Background fetching (WorkManager) and UI sync indicators.
* **Phase 7: Conflicts & GC** - Implement the manual Conflicts Inbox for ambiguous edge cases and Garbage Collection for old tombstones.
