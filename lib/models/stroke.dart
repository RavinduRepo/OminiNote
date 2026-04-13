import 'package:flutter/material.dart';
import 'package:perfect_freehand/perfect_freehand.dart';

class Stroke {
  final List<PointVector> points;
  final Color color;
  final double strokeSize;

  Stroke({
    required this.points,
    this.color = Colors.white,
    this.strokeSize = 4.0,
  });
}
