import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'progress_overlay.dart';

/// A small, theme-matched toast that slides in from the right edge, sits at the
/// bottom-right, auto-dismisses, and can be swiped away or closed with its ✕.
/// It replaces the app's full-width `SnackBar`s, which spanned the whole window
/// on desktop and covered content. Rendered in the **root [Overlay]** so it
/// survives navigation and never shifts page layout.
///
/// Only one toast shows at a time — a new one replaces the current (matching
/// SnackBar's single-slot feel and avoiding overlap).
OverlayEntry? _current;

void _remove() {
  _current?.remove();
  _current = null;
}

/// Shows [message] as a toast anchored to [context]'s root overlay. Pass
/// [error] to tint it with the theme error color. A no-op if no overlay can be
/// resolved (a missing toast must never break the flow it reported on).
void showAppToast(BuildContext context, String message, {bool error = false}) {
  final overlay = (context.mounted
          ? Overlay.maybeOf(context, rootOverlay: true)
          : null) ??
      progressOverlayFallback?.call();
  if (overlay == null) return;
  _showOn(overlay, message, error);
}

/// Like [showAppToast] but for callers that captured an [OverlayState] before
/// an `await` (their `BuildContext` may be gone by the time they report).
void showAppToastOverlay(
  OverlayState overlay,
  String message, {
  bool error = false,
}) =>
    _showOn(overlay, message, error);

void _showOn(OverlayState overlay, String message, bool error) {
  _remove();
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _AppToast(
      message: message,
      error: error,
      onGone: () {
        if (identical(_current, entry)) _current = null;
        if (entry.mounted) entry.remove();
      },
    ),
  );
  _current = entry;
  overlay.insert(entry);
}

class _AppToast extends StatefulWidget {
  final String message;
  final bool error;
  final VoidCallback onGone;

  const _AppToast({
    required this.message,
    required this.error,
    required this.onGone,
  });

  @override
  State<_AppToast> createState() => _AppToastState();
}

class _AppToastState extends State<_AppToast>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  )..forward();
  Timer? _timer;
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(seconds: 4), _dismiss);
  }

  Future<void> _dismiss() async {
    if (_leaving) return;
    _leaving = true;
    _timer?.cancel();
    if (mounted) {
      await _c.reverse(); // slides back out to the right
    }
    widget.onGone();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<AppPalette>()!;
    final mq = MediaQuery.of(context);
    final isMobile = Platform.isAndroid || Platform.isIOS;
    final bottom = mq.padding.bottom + (isMobile ? 80.0 : 20.0);
    final accent = widget.error ? theme.colorScheme.error : palette.border;
    final slide = CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);
    return Positioned(
      right: 16,
      bottom: bottom,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(1.15, 0),
          end: Offset.zero,
        ).animate(slide),
        child: FadeTransition(
          opacity: _c,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: (mq.size.width - 32).clamp(0.0, 380.0),
            ),
            child: Dismissible(
              key: const ValueKey('app_toast'),
              direction: DismissDirection.horizontal,
              onDismissed: (_) {
                _timer?.cancel();
                widget.onGone();
              },
              child: Material(
                color: Colors.transparent,
                child: Container(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface,
                    borderRadius: BorderRadius.circular(kRadius),
                    border: Border.all(color: accent),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.18),
                        blurRadius: 10,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (widget.error) ...[
                        Icon(Icons.error_outline,
                            size: 18, color: theme.colorScheme.error),
                        const SizedBox(width: 8),
                      ],
                      Flexible(
                        child: Text(
                          widget.message,
                          style: TextStyle(
                            fontSize: 13,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      InkResponse(
                        onTap: _dismiss,
                        radius: 16,
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Icon(Icons.close,
                              size: 16, color: palette.textDim),
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
