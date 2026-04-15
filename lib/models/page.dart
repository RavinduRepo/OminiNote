import 'stroke.dart';

class Page {
  final String id;
  final String notebookId;
  final String name;
  final DateTime createdAt;
  final String? pdfPath; // null if empty page
  final List<Stroke> strokes;

  Page({
    required this.id,
    required this.notebookId,
    required this.name,
    required this.createdAt,
    this.pdfPath,
    this.strokes = const [],
  });

  /// Get the path to the strokes file for this page
  String getStrokesFilePath(String appDirPath) {
    return '$appDirPath/notebooks/$notebookId/${id}_strokes.json';
  }

  Page copyWith({
    String? id,
    String? notebookId,
    String? name,
    DateTime? createdAt,
    String? pdfPath,
    List<Stroke>? strokes,
  }) {
    return Page(
      id: id ?? this.id,
      notebookId: notebookId ?? this.notebookId,
      name: name ?? this.name,
      createdAt: createdAt ?? this.createdAt,
      pdfPath: pdfPath ?? this.pdfPath,
      strokes: strokes ?? this.strokes,
    );
  }

  /// Add a stroke to the page
  Page addStroke(Stroke stroke) => copyWith(strokes: [...strokes, stroke]);

  /// Remove the last stroke
  Page removeLastStroke() {
    if (strokes.isEmpty) return this;
    return copyWith(strokes: strokes.sublist(0, strokes.length - 1));
  }

  /// Clear all strokes
  Page clearStrokes() => copyWith(strokes: []);

  Map<String, dynamic> toJson() => {
    'id': id,
    'notebookId': notebookId,
    'name': name,
    'createdAt': createdAt.toIso8601String(),
    'pdfPath': pdfPath,
    'strokes': strokes.map((s) => s.toJson()).toList(),
  };

  factory Page.fromJson(Map<String, dynamic> json) => Page(
    id: json['id'],
    notebookId: json['notebookId'],
    name: json['name'],
    createdAt: DateTime.parse(json['createdAt']),
    pdfPath: json['pdfPath'],
    strokes: List<Stroke>.from(
      (json['strokes'] ?? []).map(
        (s) => Stroke.fromJson(s as Map<String, dynamic>),
      ),
    ),
  );
}
