import 'package:flutter/material.dart';

/// A **non-modal** live progress indicator shown as a [MaterialBanner] at the
/// top of the current scaffold. Unlike a blocking progress dialog, the app
/// stays fully usable while a long task (PDF export / notebook import-export)
/// runs on a background isolate — the point of moving that work off the main
/// isolate. Update it live with [report]; call [close] when done. (Perf
/// 07/14/26.)
class ProgressBanner {
  final ScaffoldMessengerState _messenger;
  final ValueNotifier<double?> _fraction; // null = indeterminate
  final ValueNotifier<String> _label;
  bool _closed = false;

  ProgressBanner._(this._messenger, String label)
      : _fraction = ValueNotifier<double?>(null),
        _label = ValueNotifier<String>(label);

  /// Shows the banner immediately. Grab the returned handle to [report]
  /// progress and [close] it when the task finishes (or fails).
  static ProgressBanner show(BuildContext context, String label) {
    final messenger = ScaffoldMessenger.of(context);
    final banner = ProgressBanner._(messenger, label);
    messenger.clearMaterialBanners();
    messenger.showMaterialBanner(
      MaterialBanner(
        dividerColor: Colors.transparent,
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        content: _ProgressContent(
          fraction: banner._fraction,
          label: banner._label,
        ),
        // MaterialBanner requires a non-empty actions list; this task can't be
        // cancelled mid-flight, so it's an invisible spacer.
        actions: const [SizedBox.shrink()],
      ),
    );
    return banner;
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
    _messenger.hideCurrentMaterialBanner();
    _fraction.dispose();
    _label.dispose();
  }
}

class _ProgressContent extends StatelessWidget {
  final ValueNotifier<double?> fraction;
  final ValueNotifier<String> label;
  const _ProgressContent({required this.fraction, required this.label});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        ValueListenableBuilder<String>(
          valueListenable: label,
          builder: (_, l, _) =>
              Text(l, style: const TextStyle(fontSize: 13)),
        ),
        const SizedBox(height: 8),
        ValueListenableBuilder<double?>(
          valueListenable: fraction,
          builder: (_, f, _) => ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(value: f, minHeight: 5),
          ),
        ),
      ],
    );
  }
}
