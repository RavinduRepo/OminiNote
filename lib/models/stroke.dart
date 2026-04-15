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

  Map<String, dynamic> toJson() => {
    'points': points.map((p) => {'x': p.x, 'y': p.y}).toList(),
    'color': color.value,
    'strokeSize': strokeSize,
  };

  factory Stroke.fromJson(Map<String, dynamic> json) {
    final pointsList = List<Map<String, dynamic>>.from(json['points'] ?? []);
    final points = pointsList
        .map((p) => PointVector(p['x'] ?? 0.0, p['y'] ?? 0.0, 0.5))
        .toList();

    return Stroke(
      points: points,
      color: Color(json['color'] ?? Colors.white.value),
      strokeSize: (json['strokeSize'] ?? 4.0).toDouble(),
    );
  }
}
