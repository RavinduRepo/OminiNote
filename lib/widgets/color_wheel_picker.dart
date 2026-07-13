import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';

/// A rainbow sweep-gradient used by the "custom color" trigger dots that open
/// [showColorWheelPicker], so every picker row advertises the wheel the same
/// way.
const SweepGradient kColorWheelGradient = SweepGradient(
  colors: [
    Color(0xFFFF0000),
    Color(0xFFFFFF00),
    Color(0xFF00FF00),
    Color(0xFF00FFFF),
    Color(0xFF0000FF),
    Color(0xFFFF00FF),
    Color(0xFFFF0000),
  ],
);

/// Full HSV color picker dialog: hue/saturation wheel, brightness slider and
/// a hex field. Returns the chosen color, or null when dismissed.
Future<Color?> showColorWheelPicker(
  BuildContext context, {
  required Color initial,
}) {
  return showDialog<Color>(
    context: context,
    builder: (context) => _ColorWheelDialog(initial: initial),
  );
}

class _ColorWheelDialog extends StatefulWidget {
  final Color initial;
  const _ColorWheelDialog({required this.initial});

  @override
  State<_ColorWheelDialog> createState() => _ColorWheelDialogState();
}

class _ColorWheelDialogState extends State<_ColorWheelDialog> {
  late HSVColor _hsv;
  late final TextEditingController _hex;

  @override
  void initState() {
    super.initState();
    _hsv = HSVColor.fromColor(widget.initial);
    _hex = TextEditingController(text: _hexOf(_hsv.toColor()));
  }

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  String _hexOf(Color c) =>
      c.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase();

  void _setHsv(HSVColor hsv) {
    setState(() {
      _hsv = hsv;
      _hex.text = _hexOf(hsv.toColor());
    });
  }

  void _applyHex(String text) {
    final cleaned = text.replaceAll('#', '').trim();
    if (cleaned.length != 6) return;
    final v = int.tryParse(cleaned, radix: 16);
    if (v == null) return;
    _setHsv(HSVColor.fromColor(Color(0xFF000000 | v)));
  }

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppPalette>()!;
    final color = _hsv.toColor();

    return AlertDialog(
      title: const Text('Custom color', style: TextStyle(fontSize: 16)),
      contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      content: SizedBox(
        width: 264,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _HueSatWheel(hsv: _hsv, onChanged: _setHsv, size: 216),
            const SizedBox(height: 16),
            _ValueSlider(hsv: _hsv, onChanged: _setHsv),
            const SizedBox(height: 14),
            Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: palette.border),
                  ),
                ),
                const SizedBox(width: 10),
                Text('#',
                    style: TextStyle(color: palette.textDim, fontSize: 14)),
                const SizedBox(width: 2),
                Expanded(
                  child: TextField(
                    controller: _hex,
                    maxLength: 6,
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 14),
                    decoration: const InputDecoration(
                      counterText: '',
                      isDense: true,
                    ),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(
                          RegExp('[0-9a-fA-F]')),
                    ],
                    onSubmitted: _applyHex,
                    onChanged: (t) {
                      if (t.length == 6) _applyHex(t);
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, color),
          child: const Text('Select'),
        ),
      ],
    );
  }
}

/// Hue (angle) / saturation (radius) disk with a draggable indicator.
class _HueSatWheel extends StatelessWidget {
  final HSVColor hsv;
  final ValueChanged<HSVColor> onChanged;
  final double size;

  const _HueSatWheel({
    required this.hsv,
    required this.onChanged,
    required this.size,
  });

  void _pick(Offset local) {
    final center = Offset(size / 2, size / 2);
    final d = local - center;
    final radius = size / 2;
    final sat = (d.distance / radius).clamp(0.0, 1.0);
    var hue = math.atan2(d.dy, d.dx) * 180 / math.pi;
    if (hue < 0) hue += 360;
    onChanged(hsv.withHue(hue).withSaturation(sat));
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onPanDown: (d) => _pick(d.localPosition),
      onPanUpdate: (d) => _pick(d.localPosition),
      child: CustomPaint(
        size: Size.square(size),
        painter: _WheelPainter(hsv: hsv),
      ),
    );
  }
}

class _WheelPainter extends CustomPainter {
  final HSVColor hsv;
  _WheelPainter({required this.hsv});

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);

    canvas.drawCircle(
      center,
      radius,
      Paint()..shader = kColorWheelGradient.createShader(rect),
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = RadialGradient(
          colors: [Colors.white, Colors.white.withValues(alpha: 0)],
        ).createShader(rect),
    );
    if (hsv.value < 1.0) {
      canvas.drawCircle(
        center,
        radius,
        Paint()..color = Colors.black.withValues(alpha: 1 - hsv.value),
      );
    }

    // Indicator at the current hue/saturation.
    final angle = hsv.hue * math.pi / 180;
    final pos = center +
        Offset(math.cos(angle), math.sin(angle)) * (hsv.saturation * radius);
    canvas.drawCircle(
      pos,
      9,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.35)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4,
    );
    canvas.drawCircle(pos, 7, Paint()..color = hsv.toColor());
    canvas.drawCircle(
      pos,
      8,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_WheelPainter old) => old.hsv != hsv;
}

/// Brightness slider drawn over a black → full-brightness gradient track.
class _ValueSlider extends StatelessWidget {
  final HSVColor hsv;
  final ValueChanged<HSVColor> onChanged;

  const _ValueSlider({required this.hsv, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final bright = hsv.withValue(1.0).toColor();
    return SizedBox(
      height: 28,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            height: 12,
            margin: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              gradient: LinearGradient(colors: [Colors.black, bright]),
            ),
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 12,
              activeTrackColor: Colors.transparent,
              inactiveTrackColor: Colors.transparent,
              thumbShape:
                  const RoundSliderThumbShape(enabledThumbRadius: 9),
              overlayShape:
                  const RoundSliderOverlayShape(overlayRadius: 14),
              thumbColor: hsv.toColor(),
            ),
            child: Slider(
              value: hsv.value,
              onChanged: (v) => onChanged(hsv.withValue(v)),
            ),
          ),
        ],
      ),
    );
  }
}
