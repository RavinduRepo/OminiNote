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
  late final _BoolNotifier _signedIn;

  @override
  void initState() {
    super.initState();
    _spin = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    );
    // Spin only while actually syncing. A forever-`repeat()`ing ticker forced
    // Flutter to produce frames the whole time any sync icon was on screen,
    // and while status == syncing (near-continuous during fast writing with
    // internet on) the un-bounded RotationTransition re-rastered the whole
    // app bar / sidebar header every frame — visible ink jank on mid-range
    // devices (smooth in full screen, where no sync icon is visible).
    SyncService().status.addListener(_syncSpin);
    _signedIn = _BoolNotifier(AuthService().account);
    _syncSpin();
  }

  void _syncSpin() {
    final syncing = SyncService().status.value == SyncStatus.syncing;
    if (syncing && !_spin.isAnimating) {
      _spin.repeat();
    } else if (!syncing && _spin.isAnimating) {
      _spin.stop();
    }
  }

  @override
  void dispose() {
    SyncService().status.removeListener(_syncSpin);
    _signedIn.dispose();
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      // Auth notifier drives visibility.
      valueListenable: _signedIn,
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
          // RepaintBoundary: keep the spin repaint 20px big — without it each
          // animation tick re-rasters up to the nearest ancestor boundary
          // (the whole app bar / sidebar header).
          child: RepaintBoundary(
            child: RotationTransition(
              turns: _spin,
              child: Icon(
                Icons.sync,
                size: 20,
                color: palette.accent,
              ),
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
/// without a state-management library. Detaches from [source] on dispose.
class _BoolNotifier extends ValueNotifier<bool> {
  final ValueNotifier<dynamic> _source;

  _BoolNotifier(this._source) : super(_source.value != null) {
    _source.addListener(_onSource);
  }

  void _onSource() => value = _source.value != null;

  @override
  void dispose() {
    _source.removeListener(_onSource);
    super.dispose();
  }
}
