import 'dart:ui' show Offset;

/// A user-saved custom shape (Shape Tools Phase 3). Stores **geometry only** —
/// a list of polylines whose points are normalized into the unit box [0,1]²
/// (each polyline is one future stroke). Stamped output takes the current pen
/// colour/size, so a template stays tiny and predictable. Device-local
/// (persisted in settings.json; never synced — the stamped strokes sync like
/// any ink, but the library itself is per-device).
class ShapeTemplate {
  final String id;
  final String name;
  final List<List<Offset>> polylines; // unit-box coords (0..1)
  final DateTime createdAt;

  const ShapeTemplate({
    required this.id,
    required this.name,
    required this.polylines,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'createdAt': createdAt.toIso8601String(),
        // Flat [x,y,x,y,…] per polyline keeps the JSON compact.
        'polys': [
          for (final poly in polylines)
            [for (final p in poly) ...[p.dx, p.dy]]
        ],
      };

  factory ShapeTemplate.fromJson(Map<String, dynamic> json) {
    final polys = <List<Offset>>[];
    for (final flat in (json['polys'] as List? ?? const [])) {
      final nums = (flat as List).cast<num>();
      final pts = <Offset>[];
      for (var i = 0; i + 1 < nums.length; i += 2) {
        pts.add(Offset(nums[i].toDouble(), nums[i + 1].toDouble()));
      }
      polys.add(pts);
    }
    return ShapeTemplate(
      id: json['id'] as String,
      name: (json['name'] as String?) ?? 'Shape',
      polylines: polys,
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
    );
  }
}
