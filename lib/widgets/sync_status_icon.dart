import 'package:flutter/material.dart';
import '../services/sync_service.dart';
import '../services/auth_service.dart';
import '../theme/app_theme.dart';

/// A compact cloud-sync status icon for the app bar / sidebar header.
///
/// Shows:
///   • Nothing (invisible) when Google Drive is not connected.
///   • Animated ↑↓ icon while syncing.
///   • ✓ cloud icon when fully synced (fades to dim after 3 seconds).
///   • ⚠ amber when there is a pending upload queue (offline / backoff).
///   • ✕ red on error.
class SyncStatusIcon extends StatefulWidget {
  const SyncStatusIcon({super.key});

  @override
  State<SyncStatusIcon> createState() => _SyncStatusIconState();
}

class _SyncStatusIconState extends State<SyncStatusIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin;

  @override
  void initState() {
    super.initState();
    _spin = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat();
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      // Auth notifier drives visibility.
      valueListenable: _BoolNotifier(AuthService().account),
      builder: (context, _, child) {
        if (!AuthService().isSignedIn) return const SizedBox.shrink();
        return ValueListenableBuilder<SyncStatus>(
          valueListenable: SyncService().status,
          builder: (context, status, child) => _buildIcon(context, status),
        );
      },
    );
  }

  Widget _buildIcon(BuildContext context, SyncStatus status) {
    final palette = Theme.of(context).extension<AppPalette>()!;

    switch (status) {
      case SyncStatus.syncing:
        return Tooltip(
          message: 'Syncing…',
          child: RotationTransition(
            turns: _spin,
            child: Icon(
              Icons.sync,
              size: 20,
              color: palette.accent,
            ),
          ),
        );
      case SyncStatus.error:
        return Tooltip(
          message: 'Sync error — tap to retry',
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () => SyncService().syncNow(),
            child: const Icon(
              Icons.cloud_off_outlined,
              size: 20,
              color: Colors.redAccent,
            ),
          ),
        );
      case SyncStatus.offline:
        return Tooltip(
          message: 'Offline — changes will sync when connected',
          child: Icon(
            Icons.cloud_off_outlined,
            size: 20,
            color: palette.textDim,
          ),
        );
      case SyncStatus.idle:
        return Tooltip(
          message: _lastSyncLabel(),
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () => SyncService().syncNow(),
            child: Icon(
              Icons.cloud_done_outlined,
              size: 20,
              color: palette.textDim,
            ),
          ),
        );
    }
  }

  String _lastSyncLabel() {
    final t = SyncService().lastSyncAt.value;
    if (t == null) return 'Tap to sync';
    final diff = DateTime.now().difference(t);
    if (diff.inSeconds < 60) return 'Synced just now';
    if (diff.inMinutes < 60) return 'Synced ${diff.inMinutes}m ago';
    return 'Synced ${diff.inHours}h ago';
  }
}

/// Thin wrapper to make [ValueNotifier<T?>] usable in a bool-typed listener
/// without a state-management library.
class _BoolNotifier extends ValueNotifier<bool> {
  _BoolNotifier(ValueNotifier<dynamic> source)
      : super(source.value != null) {
    source.addListener(() => value = source.value != null);
  }
}
