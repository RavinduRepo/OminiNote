import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:omininote/models/link.dart';
import 'package:omininote/services/sync/merge_engine.dart';

void main() {
  group('LinkEndpoint URI codec', () {
    LinkEndpoint roundTrip(LinkEndpoint e) {
      final parsed = LinkEndpoint.tryParse(e.toUri());
      expect(parsed, isNotNull, reason: e.toUri());
      expect(parsed!.sameAs(e), isTrue, reason: e.toUri());
      return parsed;
    }

    test('every kind round-trips through its URI', () {
      expect(roundTrip(const LinkEndpoint(notebookId: 'nb1')).kind,
          LinkTargetKind.notebook);
      expect(
          roundTrip(const LinkEndpoint(notebookId: 'nb1', folderId: 'f1')).kind,
          LinkTargetKind.folder);
      expect(
          roundTrip(const LinkEndpoint(notebookId: 'nb1', sectionId: 's1'))
              .kind,
          LinkTargetKind.section);
      expect(
          roundTrip(const LinkEndpoint(
                  notebookId: 'nb1', sectionId: 's1', folderId: 'f2'))
              .kind,
          LinkTargetKind.folder);
      expect(
          roundTrip(const LinkEndpoint(
                  notebookId: 'nb1', sectionId: 's1', canvasId: 'c1'))
              .kind,
          LinkTargetKind.canvas);
      expect(
          roundTrip(const LinkEndpoint(
                  notebookId: 'nb1',
                  sectionId: 's1',
                  canvasId: 'c1',
                  pageId: 'p1'))
              .kind,
          LinkTargetKind.page);
      expect(
          roundTrip(const LinkEndpoint(
                  notebookId: 'nb1',
                  sectionId: 's1',
                  canvasId: 'c1',
                  pageId: 'p1',
                  elementIds: ['e1', 'e2']))
              .kind,
          LinkTargetKind.element);
      expect(
          roundTrip(const LinkEndpoint(
                  notebookId: 'nb1',
                  sectionId: 's1',
                  canvasId: 'c1',
                  bookmarkId: 'b1'))
              .kind,
          LinkTargetKind.bookmark);
    });

    test('the two folder levels produce distinct URIs', () {
      const nbFolder = LinkEndpoint(notebookId: 'nb', folderId: 'f');
      const secFolder =
          LinkEndpoint(notebookId: 'nb', sectionId: 's', folderId: 'f');
      expect(nbFolder.toUri(), isNot(secFolder.toUri()));
      expect(LinkEndpoint.tryParse(nbFolder.toUri())!.sectionId, isNull);
      expect(LinkEndpoint.tryParse(secFolder.toUri())!.sectionId, 's');
    });

    test('element ids survive as a list', () {
      const e = LinkEndpoint(
          notebookId: 'nb',
          sectionId: 's',
          canvasId: 'c',
          pageId: 'p',
          elementIds: ['x', 'y', 'z']);
      final parsed = LinkEndpoint.tryParse(e.toUri())!;
      expect(parsed.elementIds, ['x', 'y', 'z']);
    });

    test('foreign input never parses (and never throws)', () {
      expect(LinkEndpoint.tryParse('https://example.com'), isNull);
      expect(LinkEndpoint.tryParse('omninote://import?id=abc'), isNull);
      expect(LinkEndpoint.tryParse('omninote://link/'), isNull);
      expect(LinkEndpoint.tryParse('omninote://link/n'), isNull); // odd segs
      expect(LinkEndpoint.tryParse('omninote://link/s/s1'), isNull); // no nb
      expect(LinkEndpoint.tryParse('omninote://link/n/'), isNull); // empty id
      expect(LinkEndpoint.tryParse('omninote://link/n/nb/q/zz'), isNull);
      expect(LinkEndpoint.tryParse(''), isNull);
    });

    test('touchesId sees every level; leafId is the deepest', () {
      const e = LinkEndpoint(
          notebookId: 'nb', sectionId: 's', canvasId: 'c', pageId: 'p');
      for (final id in ['nb', 's', 'c', 'p']) {
        expect(e.touchesId(id), isTrue);
      }
      expect(e.touchesId('zz'), isFalse);
      expect(e.leafId, 'p');
    });
  });

  group('remapLinkUriPage (move a linked element between pages)', () {
    const uri =
        'omninote://link/n/nb/s/s1/c/c1/p/pageA/e/elem1';
    test('rewrites the page when a referenced element moved', () {
      final out = remapLinkUriPage(uri,
          movedIds: {'elem1'},
          canvasId: 'c1',
          fromPage: 'pageA',
          toPage: 'pageB');
      expect(out, 'omninote://link/n/nb/s/s1/c/c1/p/pageB/e/elem1');
    });

    test('leaves URIs for other canvases / pages / elements alone', () {
      // wrong canvas
      expect(
          remapLinkUriPage(uri,
              movedIds: {'elem1'},
              canvasId: 'OTHER',
              fromPage: 'pageA',
              toPage: 'pageB'),
          isNull);
      // wrong from-page
      expect(
          remapLinkUriPage(uri,
              movedIds: {'elem1'},
              canvasId: 'c1',
              fromPage: 'pageZ',
              toPage: 'pageB'),
          isNull);
      // element not among the moved ids
      expect(
          remapLinkUriPage(uri,
              movedIds: {'somethingElse'},
              canvasId: 'c1',
              fromPage: 'pageA',
              toPage: 'pageB'),
          isNull);
    });

    test('non-link / external strings are ignored', () {
      expect(
          remapLinkUriPage('https://example.com',
              movedIds: {'elem1'},
              canvasId: 'c1',
              fromPage: 'pageA',
              toPage: 'pageB'),
          isNull);
    });

    test('withPage keeps every other field', () {
      const e = LinkEndpoint(
          notebookId: 'nb',
          sectionId: 's1',
          canvasId: 'c1',
          pageId: 'pageA',
          elementIds: ['elem1', 'elem2']);
      final moved = e.withPage('pageB');
      expect(moved.pageId, 'pageB');
      expect(moved.canvasId, 'c1');
      expect(moved.elementIds, ['elem1', 'elem2']);
    });
  });

  group('LinkRecord json', () {
    test('round-trips with envelope, label and name snapshots', () {
      final rec = LinkRecord(
        id: 'l1',
        rev: 3,
        deviceId: 'devA',
        a: const LinkEndpoint(notebookId: 'nb1', sectionId: 's1'),
        b: const LinkEndpoint(
            notebookId: 'nb2', sectionId: 's2', canvasId: 'c2'),
        label: 'my label',
        aName: 'Physics',
        bName: 'Notes canvas',
      );
      final back = LinkRecord.tryFromJson(
          jsonDecode(jsonEncode(rec.toJson())) as Map<String, dynamic>)!;
      expect(back.id, 'l1');
      expect(back.rev, 3);
      expect(back.deviceId, 'devA');
      expect(back.deletedAt, isNull);
      expect(back.a.sameAs(rec.a), isTrue);
      expect(back.b.sameAs(rec.b), isTrue);
      expect(back.label, 'my label');
      expect(back.aName, 'Physics');
      expect(back.bName, 'Notes canvas');
    });

    test('otherEndOf answers from either side', () {
      final rec = LinkRecord(
        id: 'l1',
        deviceId: 'd',
        a: const LinkEndpoint(notebookId: 'nb1'),
        b: const LinkEndpoint(notebookId: 'nb2', sectionId: 's2'),
      );
      expect(rec.otherEndOf('nb1')!.sameAs(rec.b), isTrue);
      expect(rec.otherEndOf('s2')!.sameAs(rec.a), isTrue);
      expect(rec.otherEndOf('zz'), isNull);
    });

    test('unparseable endpoint json is skipped, not thrown', () {
      expect(LinkRecord.tryFromJson({'id': 'x', 'a': 'junk', 'b': 'junk'}),
          isNull);
    });
  });

  group('links.json merge', () {
    Map<String, dynamic> record(
      String id, {
      int rev = 1,
      int updatedAt = 1000,
      String device = 'devA',
      int? deletedAt,
      String label = '',
    }) =>
        {
          'schemaVersion': 1,
          'id': id,
          'rev': rev,
          'updatedAt': updatedAt,
          'deviceId': device,
          'deletedAt': deletedAt,
          'a': 'omninote://link/n/nb1',
          'b': 'omninote://link/n/nb2/s/s2',
          if (label.isNotEmpty) 'label': label,
          'createdAt': 500,
        };

    test('union: both devices\' distinct links survive', () {
      final local = jsonEncode({'l1': record('l1')});
      final remote = jsonEncode({'l2': record('l2', device: 'devB')});
      final result = MergeEngine.reconcile('links.json', local, remote);
      final merged = jsonDecode(result.content) as Map<String, dynamic>;
      expect(merged.keys.toSet(), {'l1', 'l2'});
      expect(result.changedLocal, isTrue); // gained l2
      expect(result.localContributed, isTrue); // remote lacks l1
    });

    test('LWW: the higher-rev copy of the same link wins', () {
      final local =
          jsonEncode({'l1': record('l1', rev: 2, label: 'renamed')});
      final remote = jsonEncode({'l1': record('l1', rev: 1)});
      final result = MergeEngine.reconcile('links.json', local, remote);
      final merged = jsonDecode(result.content) as Map<String, dynamic>;
      expect((merged['l1'] as Map)['label'], 'renamed');
      expect(result.localContributed, isTrue);
    });

    test('tombstone at higher rev beats a live copy (delete propagates)', () {
      final local = jsonEncode({'l1': record('l1', rev: 1)});
      final remote =
          jsonEncode({'l1': record('l1', rev: 2, deletedAt: 2000)});
      final result = MergeEngine.reconcile('links.json', local, remote);
      final merged = jsonDecode(result.content) as Map<String, dynamic>;
      expect((merged['l1'] as Map)['deletedAt'], 2000);
      expect(result.changedLocal, isTrue);
    });

    test('revival at higher rev beats the tombstone (re-link survives)', () {
      final local = jsonEncode({'l1': record('l1', rev: 3)});
      final remote =
          jsonEncode({'l1': record('l1', rev: 2, deletedAt: 2000)});
      final result = MergeEngine.reconcile('links.json', local, remote);
      final merged = jsonDecode(result.content) as Map<String, dynamic>;
      expect((merged['l1'] as Map)['deletedAt'], isNull);
    });

    test('identical maps are a clean no-op (no push loop)', () {
      final same = jsonEncode({'l1': record('l1')});
      final result = MergeEngine.reconcile('links.json', same, same);
      expect(result.changedLocal, isFalse);
      expect(result.localContributed, isFalse);
    });
  });
}
