import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:omininote/models/project.dart';

void main() {
  group('ProjectDef pin-layout serialization (Feature F)', () {
    test('defaults: no layout, no pinLayout, byte-stable JSON', () {
      final d = ProjectDef(id: 'p1', deviceId: 'dev', name: 'Alpha');
      expect(d.pinLayout, isFalse);
      expect(d.layout, isEmpty);
      final json = d.toJson();
      // Omitted when empty/false so old readers + old data stay byte-stable.
      expect(json.containsKey('pinLayout'), isFalse);
      expect(json.containsKey('layout'), isFalse);
    });

    test('round-trips pinLayout + node positions', () {
      final d = ProjectDef(
        id: 'p2',
        deviceId: 'dev',
        name: 'Beta',
        pinLayout: true,
        layout: {
          'omninote://link/n/nb1/s/s1/c/c1': [12.5, -40.0],
          'omninote://link/n/nb2': [0.0, 100.0],
        },
      );
      final json = jsonDecode(jsonEncode(d.toJson())) as Map<String, dynamic>;
      expect(json['pinLayout'], isTrue);
      expect(json['layout'], isA<Map>());

      final back = ProjectDef.tryFromJson(json)!;
      expect(back.pinLayout, isTrue);
      expect(back.layout.length, 2);
      expect(back.layout['omninote://link/n/nb1/s/s1/c/c1'], [12.5, -40.0]);
      expect(back.layout['omninote://link/n/nb2'], [0.0, 100.0]);
    });

    test('legacy record (no pinLayout/layout keys) loads as unpinned/empty', () {
      final legacy = {
        'id': 'p3',
        'deviceId': 'dev',
        'name': 'Gamma',
        'rev': 3,
      };
      final d = ProjectDef.tryFromJson(legacy)!;
      expect(d.pinLayout, isFalse);
      expect(d.layout, isEmpty);
      // And writing it back still omits the new keys.
      expect(d.toJson().containsKey('layout'), isFalse);
    });

    test('malformed layout entries are dropped, not fatal', () {
      final json = {
        'id': 'p4',
        'deviceId': 'dev',
        'name': 'Delta',
        'pinLayout': true,
        'layout': {
          'good': [1.0, 2.0],
          'short': [5.0], // too few components → skipped
          'bad': 'nope', // not a list → skipped
        },
      };
      final d = ProjectDef.tryFromJson(json)!;
      expect(d.layout.keys, ['good']);
      expect(d.layout['good'], [1.0, 2.0]);
    });
  });
}
