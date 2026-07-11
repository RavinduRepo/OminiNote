import 'package:flutter_test/flutter_test.dart';
import 'package:omininote/services/notebook_service.dart';

/// `NotebookService.isPurgedContentPath` decides what the sync layer drops
/// (content under a purged item) vs. keeps flowing (the marker docs that
/// propagate the purge, and everything unrelated).
void main() {
  const nbPage = 'notebooks/nb1/sections/s1/canvases/c1/pages/p1.json';
  const nbAsset = 'notebooks/nb1/sections/s1/canvases/c1/assets/abc.png';
  const cvJson = 'notebooks/nb1/sections/s1/canvases/c1/canvas.json';
  const secJson = 'notebooks/nb1/sections/s1/section.json';

  test('nothing is filtered when nothing is purged', () {
    for (final rel in [nbPage, nbAsset, cvJson, secJson, 'notebooks.json']) {
      expect(NotebookService.isPurgedContentPath(rel, const {}), isFalse);
    }
  });

  test('purged notebook: everything under it is content (marker lives in '
      'notebooks.json, outside the subtree)', () {
    const purged = {'nb1'};
    expect(NotebookService.isPurgedContentPath(nbPage, purged), isTrue);
    expect(NotebookService.isPurgedContentPath(nbAsset, purged), isTrue);
    expect(NotebookService.isPurgedContentPath(cvJson, purged), isTrue);
    expect(NotebookService.isPurgedContentPath(secJson, purged), isTrue);
    // The index itself and other notebooks still flow.
    expect(
        NotebookService.isPurgedContentPath('notebooks.json', purged), isFalse);
    expect(
        NotebookService.isPurgedContentPath(
            'notebooks/nb2/sections/s1/section.json', purged),
        isFalse);
  });

  test('purged section: content drops but its own section.json (the marker) '
      'still flows', () {
    const purged = {'nb1/s1'};
    expect(NotebookService.isPurgedContentPath(nbPage, purged), isTrue);
    expect(NotebookService.isPurgedContentPath(cvJson, purged), isTrue);
    expect(NotebookService.isPurgedContentPath(secJson, purged), isFalse,
        reason: 'the marker is how the purge propagates');
    expect(
        NotebookService.isPurgedContentPath(
            'notebooks/nb1/sections/s2/section.json', purged),
        isFalse,
        reason: 'sibling section unaffected');
  });

  test('purged canvas: pages/assets drop but its canvas.json still flows', () {
    const purged = {'nb1/s1/c1'};
    expect(NotebookService.isPurgedContentPath(nbPage, purged), isTrue);
    expect(NotebookService.isPurgedContentPath(nbAsset, purged), isTrue);
    expect(NotebookService.isPurgedContentPath(cvJson, purged), isFalse);
    expect(NotebookService.isPurgedContentPath(secJson, purged), isFalse,
        reason: 'the parent section doc is not canvas content');
    expect(
        NotebookService.isPurgedContentPath(
            'notebooks/nb1/sections/s1/canvases/c2/pages/p.json', purged),
        isFalse,
        reason: 'sibling canvas unaffected');
  });
}
