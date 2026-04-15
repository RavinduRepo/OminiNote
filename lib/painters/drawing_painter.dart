import 'package:flutter/material.dart';
import 'package:perfect_freehand/perfect_freehand.dart';
import '../models/stroke.dart';

class DrawingPainter extends CustomPainter {
  final List<Stroke> strokes;
  final Stroke? currentStroke;
  final Matrix4? transform; // Transform for PDF scroll/zoom

  DrawingPainter({required this.strokes, this.currentStroke, this.transform});

  @override
  void paint(Canvas canvas, Size size) {
    // Apply PDF transformation only if valid
    if (transform != null) {
      try {
        final storage = transform!.storage;
        if (storage.isNotEmpty && storage.length >= 16) {
          canvas.transform(storage);
        }
      } catch (e) {
        // If transform fails, continue without it
      }
    }

    for (var stroke in strokes) {
      _drawStroke(canvas, stroke);
    }
    if (currentStroke != null) {
      _drawStroke(canvas, currentStroke!);
    }
  }

  void _drawStroke(Canvas canvas, Stroke stroke) {
    if (stroke.points.isEmpty) return;

    final paint = Paint()
      ..color = stroke.color
      ..style = PaintingStyle.fill;

    final outlinePoints = getStroke(
      stroke.points,
      options: StrokeOptions(
        size: stroke.strokeSize,
        thinning: 0.6,
        smoothing: 0.6,
        streamline: 0.6,
        simulatePressure: false,
      ),
    );

    if (outlinePoints.isEmpty) return;

    final path = Path();
    path.moveTo(outlinePoints[0].dx, outlinePoints[0].dy);

    for (int i = 1; i < outlinePoints.length; i++) {
      path.lineTo(outlinePoints[i].dx, outlinePoints[i].dy);
    }
    path.close();

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant DrawingPainter oldDelegate) => true;
}
