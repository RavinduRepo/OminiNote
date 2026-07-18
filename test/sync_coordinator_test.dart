import 'package:flutter_test/flutter_test.dart';
import 'package:omininote/services/sync_coordinator.dart';

void main() {
  // Staleness window is 12s (see SyncCoordinator).
  const staleMs = 12000;
  const now = 1000000;

  group('SyncCoordinator.leaseHeldByOther', () {
    test('no lease → free to take', () {
      expect(
        SyncCoordinator.leaseHeldByOther(
            ownerId: null, heartbeatMs: 0, myId: 'me', nowMs: now),
        isFalse,
      );
    });

    test('our own lease → not "held by other"', () {
      expect(
        SyncCoordinator.leaseHeldByOther(
            ownerId: 'me', heartbeatMs: now - 1000, myId: 'me', nowMs: now),
        isFalse,
      );
    });

    test('another window, fresh heartbeat → held (yield)', () {
      expect(
        SyncCoordinator.leaseHeldByOther(
            ownerId: 'other', heartbeatMs: now - 3000, myId: 'me', nowMs: now),
        isTrue,
      );
    });

    test('another window, stale heartbeat → free to take over', () {
      expect(
        SyncCoordinator.leaseHeldByOther(
            ownerId: 'other',
            heartbeatMs: now - (staleMs + 500),
            myId: 'me',
            nowMs: now),
        isFalse,
      );
    });

    test('exactly at the staleness edge is treated as stale (>= threshold)', () {
      // age == staleMs is NOT < staleMs → not held → free to take.
      expect(
        SyncCoordinator.leaseHeldByOther(
            ownerId: 'other',
            heartbeatMs: now - staleMs,
            myId: 'me',
            nowMs: now),
        isFalse,
      );
    });
  });
}
