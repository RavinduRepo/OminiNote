import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'notebook_service.dart';

/// Elects a **single sync owner** across app instances (windows) so only one
/// runs the Drive poll/push loop and writes the shared `drive_index.json` /
/// `sync_journal.json` — two writers would corrupt them.
///
/// Coordination is a heartbeat **lease file** (`sync_owner.lock`), which works
/// regardless of the isolate/process topology of Android multi-window. A lone
/// window always wins the lease immediately, so single-instance behavior is
/// unchanged. If the owner window closes (its heartbeat goes stale), a watching
/// window takes over and starts syncing.
class SyncCoordinator {
  SyncCoordinator._();
  static final SyncCoordinator instance = SyncCoordinator._();

  /// Random per-launch id identifying this window in the lease.
  final String instanceId = _randomId();

  bool _isOwner = false;
  bool get isOwner => _isOwner;

  VoidCallback? _onBecomeOwner;
  Timer? _timer;
  File? _lock;

  /// A lease older than this is considered abandoned (owner window gone).
  static const _stale = Duration(seconds: 12);
  static const _heartbeat = Duration(seconds: 4);
  static const _watch = Duration(seconds: 5);

  /// Tries to become the sync owner now. Returns true if this window should run
  /// sync. [onBecomeOwner] fires later if this window takes over the lease after
  /// the previous owner disappears (it is NOT called for the initial win — the
  /// return value covers that).
  Future<bool> start({required VoidCallback onBecomeOwner}) async {
    _onBecomeOwner = onBecomeOwner;
    _lock = File('${NotebookService().appDir.path}/sync_owner.lock');
    _isOwner = await _tryAcquire(ownOnError: true);
    _timer = Timer.periodic(_isOwner ? _heartbeat : _watch, (_) => _tick());
    return _isOwner;
  }

  Future<void> _tick() async {
    if (_isOwner) {
      await _writeLease(); // heartbeat
      return;
    }
    // Watching: only take over on a positively-confirmed stale lease (never on
    // a transient read error, which would risk two owners).
    if (await _tryAcquire(ownOnError: false)) {
      _isOwner = true;
      _timer?.cancel();
      _timer = Timer.periodic(_heartbeat, (_) => _tick());
      _onBecomeOwner?.call();
    }
  }

  /// Returns true if we now hold the lease. When the current lease is fresh and
  /// held by someone else, returns false. On an unreadable/unwritable lock,
  /// returns [ownOnError] — true at startup (a lone window must still sync),
  /// false while watching (don't seize on a transient glitch).
  Future<bool> _tryAcquire({required bool ownOnError}) async {
    try {
      final lock = _lock!;
      if (await lock.exists()) {
        final data = jsonDecode(await lock.readAsString()) as Map;
        if (leaseHeldByOther(
          ownerId: data['instanceId'] as String?,
          heartbeatMs: (data['heartbeat'] as num?)?.toInt() ?? 0,
          myId: instanceId,
          nowMs: DateTime.now().millisecondsSinceEpoch,
        )) {
          return false; // another window is alive and owns it
        }
      }
      await _writeLease();
      // Verify we won the write (guards a rare simultaneous-acquire race).
      final check = jsonDecode(await lock.readAsString()) as Map;
      return check['instanceId'] == instanceId;
    } catch (_) {
      return ownOnError;
    }
  }

  /// Whether a *live* other window currently owns the lease — i.e. the lease
  /// names a different instance and its heartbeat is within the staleness
  /// window. Pure; the load-bearing take-over decision.
  @visibleForTesting
  static bool leaseHeldByOther({
    required String? ownerId,
    required int heartbeatMs,
    required String myId,
    required int nowMs,
  }) {
    if (ownerId == null || ownerId == myId) return false;
    return nowMs - heartbeatMs < _stale.inMilliseconds;
  }

  Future<void> _writeLease() async {
    await _lock?.writeAsString(jsonEncode({
      'instanceId': instanceId,
      'heartbeat': DateTime.now().millisecondsSinceEpoch,
    }));
  }

  /// Best-effort release when this window closes, so another can take over
  /// immediately rather than waiting out the staleness window.
  Future<void> release() async {
    _timer?.cancel();
    if (_isOwner) {
      try {
        await _lock?.delete();
      } catch (_) {}
    }
  }

  static String _randomId() {
    final r = Random();
    return List.generate(8, (_) => r.nextInt(16).toRadixString(16)).join();
  }
}
