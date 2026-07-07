import 'dart:convert';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:omininote/models/canvas_page.dart';
import 'package:omininote/models/element.dart';
import 'package:omininote/services/sync/merge_engine.dart';

StrokeElement _stroke(String id, {String device = 'dev', int rev = 1}) =>
    StrokeElement(
      id: id,
      deviceId: device,
      rev: rev,
      z: '0|a0:',
      tool: StrokeTool.pen,
      color: const Color(0xFF000000),
      size: 3,
      points: [StrokePoint(0, 0, 0.5), StrokePoint(10, 10, 0.5)],
    );

TextElement _text(String id, {String device = 'dev', int rev = 1}) =>
    TextElement(
      id: id,
      deviceId: device,
      rev: rev,
      rect: const Rect.fromLTWH(0, 0, 100, 40),
      text: 'hi',
      color: const Color(0xFF000000),
    );

CanvasPage _page({
  required String id,
  int rev = 1,
  String device = 'dev',
  List<StrokeElement>? strokes,
  List<EraseTombstone>? erased,
  List<CanvasElement>? objects,
  List<EraseTombstone>? deletedObjects,
}) =>
    CanvasPage(
      id: id,
      deviceId: device,
      rev: rev,
      strokes: strokes,
      erased: erased,
      objects: objects,
      deletedObjects: deletedObjects,
    );

void main() {
  group('mergePage — set union', () {
    test('strokes drawn on both devices all survive, order-independent', () {
      final local = _page(id: 'p1', strokes: [_stroke('a'), _stroke('b')]);
      final remote = _page(id: 'p1', strokes: [_stroke('a'), _stroke('c')]);

      final ab = MergeEngine.mergePage(local, remote);
      final ba = MergeEngine.mergePage(remote, local);

      final idsAb = ab.strokes.map((s) => s.id).toSet();
      final idsBa = ba.strokes.map((s) => s.id).toSet();
      expect(idsAb, {'a', 'b', 'c'});
      expect(idsAb, idsBa, reason: 'merge must be commutative');
    });

    test('erase tombstone wins over a stroke present on the other side', () {
      final local = _page(id: 'p1', strokes: [_stroke('a'), _stroke('b')]);
      final remote = _page(
        id: 'p1',
        strokes: [_stroke('a')],
        erased: [EraseTombstone(strokeId: 'b', erasedAt: DateTime.now(), deviceId: 'dev2')],
      );

      final merged = MergeEngine.mergePage(local, remote);
      expect(merged.strokes.map((s) => s.id), ['a'],
          reason: 'erased stroke b must not render');
      expect(merged.erased.map((e) => e.strokeId), contains('b'),
          reason: 'tombstone survives so the erase re-applies everywhere');
    });

    test('deleted text/image object does not resurrect from a live remote copy', () {
      // Device A deleted object 'x' (tombstoned + physically removed from
      // objects[], mirroring the eraser pattern). Device B never touched it —
      // its objects[] still lists it live. A naive union would bring it back.
      final local = _page(
        id: 'p1',
        objects: [],
        deletedObjects: [
          EraseTombstone(strokeId: 'x', erasedAt: DateTime.now(), deviceId: 'devA'),
        ],
      );
      final remote = _page(id: 'p1', objects: [_text('x', device: 'devB')]);

      final ab = MergeEngine.mergePage(local, remote);
      final ba = MergeEngine.mergePage(remote, local);

      expect(ab.objects.map((o) => o.id), isNot(contains('x')));
      expect(ba.objects.map((o) => o.id), isNot(contains('x')),
          reason: 'merge must be commutative regardless of argument order');
      expect(ab.deletedObjects.map((e) => e.strokeId), contains('x'));
    });

    test('the edited (higher-rev) copy of the same element wins on both sides',
        () {
      // Device B moved/edited stroke 's' → its copy carries rev 2. Device A
      // holds the stale rev-1 copy. Whichever side merges, rev 2 must win —
      // this is "the most up-to-date one wins", and it only works because
      // edits bump the element rev.
      final stale = _stroke('s', device: 'devA', rev: 1);
      final edited = _stroke('s', device: 'devB', rev: 2)
        ..points = [StrokePoint(50, 50, 0.5), StrokePoint(60, 60, 0.5)];

      final a = _page(id: 'p1', strokes: [stale]);
      final b = _page(id: 'p1', strokes: [edited]);

      final ab = MergeEngine.mergePage(a, b);
      final ba = MergeEngine.mergePage(b, a);
      expect(ab.strokes.single.points.first.x, 50);
      expect(ba.strokes.single.points.first.x, 50,
          reason: 'both merge orders must pick the rev-2 copy');
    });
  });

  group('reconcile — notebooks.json union', () {
    Map<String, dynamic> _nb(String id,
            {int rev = 1, String name = 'N', int? deletedAt}) =>
        {
          'schemaVersion': 1,
          'id': id,
          'rev': rev,
          'updatedAt': 1000,
          'deviceId': 'dev',
          'deletedAt': deletedAt,
          'name': name,
          'createdAt': '2026-01-01T00:00:00.000',
          'nodes': [],
        };

    test('a soft-deleted notebook (tombstone kept, higher rev) beats a live '
        'remote copy — deletion does not require every device to delete', () {
      // This is the v1/v2 bug: a hard-removed map entry has no envelope to
      // win the comparison, so remote's still-live copy resurrects it. A
      // *kept* tombstone with a bumped rev wins deterministically instead.
      final local = jsonEncode({'n1': _nb('n1', rev: 5, deletedAt: 2000)});
      final remote = jsonEncode({'n1': _nb('n1', rev: 3, name: 'live')});

      final r = MergeEngine.reconcile('notebooks.json', local, remote);
      final merged = jsonDecode(r.content) as Map<String, dynamic>;
      expect((merged['n1'] as Map)['deletedAt'], 2000);
      expect(r.localContributed, isTrue,
          reason: 'the tombstone must be pushed back to Drive');
    });

    test('two devices\' distinct notebooks both survive first sync', () {
      final local = jsonEncode({'n1': _nb('n1')});
      final remote = jsonEncode({'n2': _nb('n2')});

      final r = MergeEngine.reconcile('notebooks.json', local, remote);
      final merged = jsonDecode(r.content) as Map<String, dynamic>;
      expect(merged.keys.toSet(), {'n1', 'n2'});
      expect(r.changedLocal, isTrue, reason: 'local gains n2');
      expect(r.localContributed, isTrue, reason: 'remote lacks n1');
    });

    test('same notebook edited on both — higher rev wins', () {
      final local = jsonEncode({'n1': _nb('n1', rev: 5, name: 'local')});
      final remote = jsonEncode({'n1': _nb('n1', rev: 7, name: 'remote')});

      final r = MergeEngine.reconcile('notebooks.json', local, remote);
      final merged = jsonDecode(r.content) as Map<String, dynamic>;
      expect((merged['n1'] as Map)['name'], 'remote');
      expect(r.changedLocal, isTrue);
      expect(r.localContributed, isFalse);
    });
  });

  group('reconcile — section/canvas single-doc LWW', () {
    Map<String, dynamic> _sec(int rev, String name) => {
          'schemaVersion': 1,
          'id': 's1',
          'rev': rev,
          'updatedAt': 1000,
          'deviceId': 'dev',
          'notebookId': 'n1',
          'name': name,
          'createdAt': '2026-01-01T00:00:00.000',
          'nodes': [],
        };

    test('missing local takes remote (bootstrap)', () {
      final r = MergeEngine.reconcile(
          'notebooks/n1/sections/s1/section.json', null, jsonEncode(_sec(1, 'x')));
      expect(r.changedLocal, isTrue);
      expect(r.localContributed, isFalse);
    });

    test('local newer wins and is re-pushed', () {
      final r = MergeEngine.reconcile(
        'notebooks/n1/sections/s1/section.json',
        jsonEncode(_sec(9, 'mine')),
        jsonEncode(_sec(4, 'theirs')),
      );
      expect(jsonDecode(r.content)['name'], 'mine');
      expect(r.localContributed, isTrue);
      expect(r.changedLocal, isFalse);
    });
  });
}
