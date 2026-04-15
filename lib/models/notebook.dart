class Notebook {
  final String id;
  final String name;
  final DateTime createdAt;
  final List<String> pageIds; // List of page IDs

  Notebook({
    required this.id,
    required this.name,
    required this.createdAt,
    this.pageIds = const [],
  });

  Notebook copyWith({
    String? id,
    String? name,
    DateTime? createdAt,
    List<String>? pageIds,
  }) {
    return Notebook(
      id: id ?? this.id,
      name: name ?? this.name,
      createdAt: createdAt ?? this.createdAt,
      pageIds: pageIds ?? this.pageIds,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'createdAt': createdAt.toIso8601String(),
    'pageIds': pageIds,
  };

  factory Notebook.fromJson(Map<String, dynamic> json) => Notebook(
    id: json['id'],
    name: json['name'],
    createdAt: DateTime.parse(json['createdAt']),
    pageIds: List<String>.from(json['pageIds'] ?? []),
  );
}
