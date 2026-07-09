import 'package:flutter_test/flutter_test.dart';
import 'package:omininote/models/notebook.dart';
import 'package:omininote/services/search_service.dart';

void main() {
  final nb = Notebook(
    id: 'n1',
    deviceId: 'test_device',
    name: 'NB',
    createdAt: DateTime(2026, 7, 9),
  );

  SearchResult r(String title) => SearchResult(
        kind: SearchKind.canvas,
        title: title,
        path: '',
        notebook: nb,
      );

  final index = [
    r('Physics'),
    r('Photography'),
    r('Chemistry notes'),
    r('Biology'),
    r('History of Physics'),
  ];

  final svc = SearchService();

  test('empty query returns the whole index unchanged', () {
    expect(svc.filter(index, ''), hasLength(index.length));
    expect(svc.filter(index, '   '), hasLength(index.length));
  });

  test('exact / prefix matches outrank looser subsequence matches', () {
    final res = svc.filter(index, 'phy');
    expect(res, isNotEmpty);
    // "Physics" (prefix) should rank above "Photography" (subsequence p..h..y)
    // and "History of Physics" (contains, but not at the start).
    expect(res.first.title, 'Physics');
    final titles = res.map((e) => e.title).toList();
    expect(titles.indexOf('Physics'), lessThan(titles.indexOf('Photography')));
  });

  test('non-matching query is filtered out', () {
    final res = svc.filter(index, 'zzzz');
    expect(res, isEmpty);
  });

  test('subsequence matching is case-insensitive', () {
    final res = svc.filter(index, 'CHEM');
    expect(res.map((e) => e.title), contains('Chemistry notes'));
  });

  test('"contains" match is found even when not a prefix', () {
    final res = svc.filter(index, 'notes');
    expect(res.first.title, 'Chemistry notes');
  });
}
