import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:cosmos_executor/core.dart';
import 'package:cosmos_executor/resources.dart';
import 'package:cosmos_executor/plist.dart';

void main() {
  test(
    'packaging exact set, digest, strict fields and base64 are verified',
    () {
      final bytes = utf8.encode('frozen');
      final hash = digest(bytes);
      final row = {
        'ref': 'app-studio/icon',
        'digest': hash,
        'contentType': 'image/png',
        'contentBase64': base64Encode(bytes),
      };
      expect(decodePackaging([row], {'app-studio/icon': hash}), {
        'app-studio/icon': bytes,
      });
      for (final invalid in [
        <dynamic>[],
        [row, row],
        [
          {...row, 'password': 'not-allowed'},
        ],
        [
          {...row, 'contentBase64': 'bad%'},
        ],
        [
          {...row, 'digest': '0' * 64},
        ],
        [
          {...row, 'contentType': 'text/plain'},
        ],
      ]) {
        expect(
          () => decodePackaging(invalid, {'app-studio/icon': hash}),
          throwsFormatException,
        );
      }
    },
  );
  test('index cannot escape or traverse symlinks and verifies exact refs', () {
    final temp = Directory.systemTemp.createTempSync('runall-resource-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final file = File('${temp.path}/data')..writeAsStringSync('frozen');
    final hash = digest(file.readAsBytesSync());
    final index = '${temp.path}/index.json';
    writeJson(index, {'r': 'data'});
    expect(verified(index, {'r': hash})['r'], file.readAsBytesSync());
    for (final path in ['../data', 'http://example.test', 'bad\\path']) {
      writeJson(index, {'r': path});
      expect(() => verified(index, {'r': hash}), throwsFormatException);
    }
    Link('${temp.path}/link').createSync(file.path);
    writeJson(index, {'r': 'link'});
    expect(() => verified(index, {'r': hash}), throwsFormatException);
    writeJson(index, {'extra': 'data'});
    expect(() => verified(index, {'r': hash}), throwsFormatException);
    expect(
      () => requiredResources({
        'buildInput': {
          'resources': [
            {'ref': 'r', 'digest': 'a'},
            {'ref': 'r', 'digest': 'b'},
          ],
        },
      }),
      throwsFormatException,
    );
  });
  test(
    'staging writes content-addressed names and refuses nonempty destination',
    () {
      final temp = Directory.systemTemp.createTempSync('runall-stage-');
      addTearDown(() => temp.deleteSync(recursive: true));
      writeResources('${temp.path}/out', {
        'opaque/ref': [1, 2, 3],
      });
      final mapping =
          readJson('${temp.path}/out/index.json') as Map<String, dynamic>;
      expect(mapping['opaque/ref'], digest(utf8.encode('opaque/ref')));
      expect(
        () => writeResources('${temp.path}/out', {}),
        throwsFormatException,
      );
    },
  );
  test('plist preserves profile dates, entitlement arrays, flags and data', () {
    final original = {
      'date': DateTime.utc(2030),
      'Entitlements': {
        'groups': <dynamic>['one', 'two'],
        'enabled': true,
        'count': 2,
      },
    };
    expect(decodePlist(encodePlist(original)), original);
  });
}
