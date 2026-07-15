import 'dart:io';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// App-wide fallback that returns the root navigator's [OverlayState], set once
/// at startup (see `main.dart`). Used when [ProgressOverlay.show] is handed a
/// context that has no [Overlay] ancestor — which happens for the global
/// open-with / share-link callbacks, whose only context is the root
/// `Navigator`'s own (the Navigator sits *above* the Overlay it hosts, so
/// `Overlay.of` there throws "No Overlay widget found"). Without this the
/// notebook import from an opened `.omninote` file / `omninote://` link crashed
/// before it ever started.
OverlayState? Function()? progressOverlayFallback;

/// A small, non-modal **floating** progress indicator — a filling ring pinned
/// to the bottom-right of the screen via the **root [Overlay]**. Unlike the old
/// top `MaterialBanner`, it never shifts page layout and it stays put as you
/// navigate between screens, so a long export/import runs while you keep using
/// your notes. Same `show`/`report`/`close` API as the banner it replaces.
class ProgressOverlay {
  final OverlayEntry _entry;
  final ValueNotifier<double?> _fraction; // null = indeterminate (spinning)
  final ValueNotifier<String> _label;
  final bool _inserted;
  bool _closed = false;

  ProgressOverlay._(this._entry, this._fraction, this._label,
      {bool inserted = true})
      : _inserted = inserted;

  /// Inserts the indicator into the root overlay. Grab the handle to [report]
  /// progress and [close] it when the task finishes (or fails). If no overlay
  /// can be resolved (context has none *and* no [progressOverlayFallback] is
  /// registered), the handle is a harmless no-op — a missing progress ring must
  /// never break the task it was tracking.
  static ProgressOverlay show(BuildContext context, String label) {
    final fraction = ValueNotifier<double?>(null);
    final lbl = ValueNotifier<String>(label);
    final entry = OverlayEntry(
      builder: (context) => _ProgressWidget(fraction: fraction, label: lbl),
    );
    final overlay = Overlay.maybeOf(context, rootOverlay: true) ??
        progressOverlayFallback?.call();
    overlay?.insert(entry);
    return ProgressOverlay._(entry, fraction, lbl, inserted: overlay != null);
  }

  /// [fraction] in 0..1 (null = indeterminate); optional new [label].
  void report(double? fraction, [String? label]) {
    if (_closed) return;
    _fraction.value = fraction;
    if (label != null) _label.value = label;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    if (_inserted) _entry.remove();
    _fraction.dispose();
    _label.dispose();
  }
}

class _ProgressWidget extends StatelessWidget {
  final ValueNotifier<double?> fraction;
  final ValueNotifier<String> label;
  const _ProgressWidget({required this.fraction, required this.label});

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final isMobile = Platform.isAndroid || Platform.isIOS;
    // Bottom-right; on mobile lift it above the nav bar, plus the system inset.
    final bottom = mq.padding.bottom + (isMobile ? 72.0 : 20.0);
    return Positioned(
      right: 16,
      bottom: bottom,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        builder: (_, t, child) =>
            Opacity(opacity: t, child: Transform.scale(scale: 0.8 + 0.2 * t, child: child)),
        child: _Bubble(fraction: fraction, label: label),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  final ValueNotifier<double?> fraction;
  final ValueNotifier<String> label;
  const _Bubble({required this.fraction, required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<AppPalette>()!;
    return ValueListenableBuilder<String>(
      valueListenable: label,
      builder: (context, lbl, _) => Tooltip(
        message: lbl,
        child: Material(
          color: Colors.transparent,
          child: Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              shape: BoxShape.circle,
              border: Border.all(color: palette.border),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.18),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Center(
              child: ValueListenableBuilder<double?>(
                valueListenable: fraction,
                builder: (context, f, _) => SizedBox(
                  width: 26,
                  height: 26,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      CircularProgressIndicator(
                        value: f,
                        strokeWidth: 3,
                        backgroundColor: palette.border,
                        valueColor:
                            AlwaysStoppedAnimation<Color>(palette.accent),
                      ),
                      if (f != null)
                        Text(
                          '${(f.clamp(0.0, 1.0) * 100).round()}',
                          style: TextStyle(
                            fontSize: 8.5,
                            fontWeight: FontWeight.w700,
                            color: palette.textDim,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
