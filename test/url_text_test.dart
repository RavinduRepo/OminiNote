import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omininote/models/element.dart';
import 'package:omininote/utils/url_text.dart';

void main() {
  TextRun run(String text) => TextRun(
        text: text,
        fontSize: 16,
        bold: false,
        italic: false,
        color: const Color(0xFF000000),
        fontFamily: 'sans',
      );

  test('detects an https URL and links only it', () {
    final out = linkifyRuns([run('see https://example.com now')]);
    expect(out.map((r) => r.text).join(), 'see https://example.com now');
    final links = out.where((r) => r.link != null).toList();
    expect(links, hasLength(1));
    expect(links.single.text, 'https://example.com');
    expect(links.single.link, 'https://example.com');
  });

  test('bare domain and www get an https scheme', () {
    final out = linkifyRuns([run('go to www.foo.io or bar.dev')]);
    final links = out.where((r) => r.link != null).toList();
    expect(links.map((r) => r.link),
        containsAll(['https://www.foo.io', 'https://bar.dev']));
  });

  test('trailing punctuation is excluded from the link', () {
    final out = linkifyRuns([run('(https://x.com).')]);
    final link = out.firstWhere((r) => r.link != null);
    expect(link.text, 'https://x.com');
    // The trailing ")." stays as plain text.
    expect(out.map((r) => r.text).join(), '(https://x.com).');
    expect(out.last.link, isNull);
  });

  test('plain text with no URL is unchanged (single run, no link)', () {
    final out = linkifyRuns([run('just some words')]);
    expect(out, hasLength(1));
    expect(out.single.link, isNull);
  });

  test('idempotent: re-linkifying yields the same runs', () {
    final once = linkifyRuns([run('visit https://a.com today')]);
    final twice = linkifyRuns(once);
    expect(twice.map((r) => r.text).toList(),
        once.map((r) => r.text).toList());
    expect(twice.map((r) => r.link).toList(),
        once.map((r) => r.link).toList());
  });

  test('a link-only box gets a trailing non-link space (grab/edit spot)', () {
    final out = linkifyRuns([run('https://only.com')]);
    expect(out.first.link, 'https://only.com');
    expect(out.last.link, isNull); // appended space
    expect(out.last.text, ' ');
    expect(out.map((r) => r.text).join(), 'https://only.com ');
    // Idempotent: the space isn't duplicated on a second pass.
    final twice = linkifyRuns(out);
    expect(twice.map((r) => r.text).join(), 'https://only.com ');
    expect(twice.where((r) => r.link == null && r.text == ' '), hasLength(1));
  });

  test('firstUrlIn returns the normalized first URL or null', () {
    expect(firstUrlIn('x www.a.com y'), 'https://www.a.com');
    expect(firstUrlIn('no links here'), isNull);
  });

  test('run style is preserved across the split', () {
    final styled = TextRun(
      text: 'bold https://b.com',
      fontSize: 20,
      bold: true,
      italic: false,
      color: const Color(0xFFAA0000),
      fontFamily: 'serif',
    );
    final out = linkifyRuns([styled]);
    for (final r in out) {
      expect(r.fontSize, 20);
      expect(r.bold, isTrue);
      expect(r.fontFamily, 'serif');
    }
  });
}
