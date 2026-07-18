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

  test('run-together path query matches via the breadcrumb', () {
    final idx = [
      SearchResult(
        kind: SearchKind.canvas,
        title: 'Canvas1',
        path: 'Notebook1 › Section1',
        notebook: nb,
      ),
      SearchResult(
        kind: SearchKind.canvas,
        title: 'Other',
        path: 'Book › Sec',
        notebook: nb,
      ),
    ];
    // "noteseccanv" is a subsequence of "notebook1 › section1 canvas1" but not
    // of any single title.
    final res = svc.filter(idx, 'noteseccanv');
    expect(res.map((e) => e.title), contains('Canvas1'));
    expect(res.map((e) => e.title), isNot(contains('Other')));
  });

  test('title hits always rank above path-only hits', () {
    final idx = [
      SearchResult(
        kind: SearchKind.canvas,
        title: 'Physics',
        path: 'Zzz › Yyy',
        notebook: nb,
      ),
      SearchResult(
        // path contains p..h..y as a subsequence, but the title doesn't match
        kind: SearchKind.canvas,
        title: 'Notes',
        path: 'Photography › Yearbook',
        notebook: nb,
      ),
    ];
    final res = svc.filter(idx, 'phy');
    expect(res.first.title, 'Physics');
  });

  test('kinds filter restricts the result types', () {
    final idx = [
      SearchResult(
          kind: SearchKind.notebook, title: 'Math', path: '', notebook: nb),
      SearchResult(
          kind: SearchKind.canvas,
          title: 'Math sheet',
          path: 'Math',
          notebook: nb),
    ];
    final res = svc.filter(idx, 'math', kinds: {SearchKind.canvas});
    expect(res.every((e) => e.kind == SearchKind.canvas), isTrue);
    expect(res.map((e) => e.title), contains('Math sheet'));
    expect(res.map((e) => e.title), isNot(contains('Math')));
  });
}
