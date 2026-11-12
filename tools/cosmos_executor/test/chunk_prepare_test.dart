import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  late Directory temp;
  late Directory executor;
  final source = Directory.current.parent.parent;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('runall chunk ');
    executor = Directory('${temp.path}/executor')..createSync();
    for (final file in ['prepare-chunk', 'lib/common.sh']) {
      final out = File('${executor.path}/scripts/$file')
        ..parent.createSync(recursive: true);
      File('${source.path}/scripts/$file').copySync(out.path);
    }
    void script(String name, String body) {
      final file = File('${executor.path}/scripts/$name')
        ..writeAsStringSync('#!/usr/bin/env bash\nset -euo pipefail\n$body\n');
      Process.runSync('chmod', ['+x', file.path]);
    }

    script('exchange-build-credential', r'''
[[ "$1" == --run-id && "$3" == --output-env ]]
echo "COSMOS_BUILD_CREDENTIAL=credential-$2" > "$4"
echo "exchange:$2" >> "$OBSERVED"
''');
    script('load-build-spec', r'''
[[ "$COSMOS_BUILD_CREDENTIAL" == "credential-$BUILD_RUN_ID" ]]
if [[ "${FAIL_RUN:-}" == "$BUILD_RUN_ID" ]]; then exit 1; fi
platform=android
if [[ "$BUILD_RUN_ID" == 2 ]]; then platform=ios; fi
jq -n --arg platform "$platform" --arg app "$BUILD_RUN_ID" --arg ref "${DISTINCT_SOURCES:+ref-$BUILD_RUN_ID}" \
 '{platform:$platform,buildInput:{source:{ref:(if $ref == "" then "main" else $ref end)},app:{applicationId:("com.example.app"+$app)}}}' > "$2"
''');
    script('report-result', r'echo "report:$BUILD_RUN_ID:$2" >> "$OBSERVED"');
    script(
      'fetch-packaging-resources',
      r'mkdir -p "$4"; echo "{}" > "$4/index.json"',
    );
    script(
      'stage-frozen-resources',
      r'mkdir -p "$4"; echo "{}" > "$4/index.json"',
    );
    script('checkout-source', r'''
workspace="$4"
mkdir -p "$workspace/.git"
if [[ "$5" == --resolve-only ]]; then
 sha=1111111111111111111111111111111111111111
 if [[ -n "${DISTINCT_SOURCES:-}" ]]; then sha="$(printf '%040d' "$BUILD_RUN_ID")"; fi
 echo "$sha" > "$workspace/.git/runall-resolved-sha"
 echo resolve >> "$OBSERVED"
else
 echo checkout >> "$OBSERVED"
 echo frozen-source > "$workspace/source.txt"
fi
''');
  });
  tearDown(() => temp.deleteSync(recursive: true));

  Future<ProcessResult> run(
    String primary,
    String? ids, {
    String? fail,
    bool distinct = false,
  }) => Process.run(
    'bash',
    ['${executor.path}/scripts/prepare-chunk'],
    environment: {
      'BUILD_RUN_ID': primary,
      if (ids != null) 'BUILD_RUN_IDS': ids,
      if (fail != null) 'FAIL_RUN': fail,
      if (distinct) 'DISTINCT_SOURCES': '1',
      'GITHUB_OUTPUT': '${temp.path}/outputs',
      'OBSERVED': '${temp.path}/observed',
      'RUNALL_PREPARE_OUTPUT': '${temp.path}/prepared',
    },
  );

  test('one prepare shares source across Apps and platforms, keeping credentials per item', () async {
    final result = await run('1', '1,2,3');
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    final outputs = Map.fromEntries(
      File('${temp.path}/outputs').readAsLinesSync().map((line) {
        final offset = line.indexOf('=');
        return MapEntry(line.substring(0, offset), line.substring(offset + 1));
      }),
    );
    expect(outputs['has_android'], 'true');
    expect(outputs['has_ios'], 'true');
    final android = jsonDecode(outputs['android_matrix']!) as List;
    expect(android.map((dynamic row) => row['build_run_id']), ['1', '3']);
    expect(android.first['application_id'], 'com.example.app1');
    expect(
      (jsonDecode(outputs['ios_matrix']!) as List).single['build_run_id'],
      '2',
    );
    final calls = File('${temp.path}/observed').readAsLinesSync();
    expect(calls.where((line) => line == 'checkout'), hasLength(1));
    expect(calls.where((line) => line.startsWith('exchange:')), hasLength(3));
    final uploads = jsonDecode(
      File('${temp.path}/prepared/uploads.json').readAsStringSync(),
    ) as List;
    expect(uploads, hasLength(7));
    expect(
      uploads.where(
        (dynamic row) => row['name'].startsWith('source-workspace-'),
      ),
      hasLength(1),
    );
    expect(
      File(
        '${temp.path}/prepared/source-1111111111111111111111111111111111111111/source-workspace.tar',
      ).existsSync(),
      true,
    );
    expect(jsonEncode(uploads), isNot(contains('credential-')));
  });

  test('different source revisions have isolated shared archives', () async {
    final result = await run('1', '1,2,3', distinct: true);
    expect(result.exitCode, 0, reason: result.stderr.toString());
    final calls = File('${temp.path}/observed').readAsLinesSync();
    expect(calls.where((line) => line == 'checkout'), hasLength(3));
    final uploads = jsonDecode(
      File('${temp.path}/prepared/uploads.json').readAsStringSync(),
    ) as List;
    expect(
      uploads.where(
        (dynamic row) => row['name'].startsWith('source-workspace-'),
      ),
      hasLength(3),
    );
  });

  test(
    'all failed preparation items return a failure with empty matrices',
    () async {
      final result = await run('1', '1', fail: '1');
      expect(result.exitCode, isNot(0));
      expect(
        File('${temp.path}/outputs').readAsStringSync(),
        contains('android_matrix=[]'),
      );
      expect(
        File('${temp.path}/observed').readAsStringSync(),
        contains('report:1:failed'),
      );
    },
  );

  test(
    'single run remains the default and emits an empty iOS matrix',
    () async {
      expect((await run('1', null)).exitCode, 0);
      final outputs = File('${temp.path}/outputs').readAsStringSync();
      expect(outputs, contains('has_ios=false'));
      expect(outputs, contains('ios_matrix=[]'));
    },
  );

  test(
    'failed prepare reports its own run and successful siblings still build',
    () async {
      final result = await run('1', '1,2,3', fail: '2');
      expect(result.exitCode, 0, reason: result.stderr.toString());
      final calls = File('${temp.path}/observed').readAsLinesSync();
      expect(calls, contains('report:2:failed'));
      final items = jsonDecode(
        File('${temp.path}/prepared/items.json').readAsStringSync(),
      ) as List;
      expect(items.map((dynamic row) => row['build_run_id']), ['1', '3']);
    },
  );

  test('invalid, duplicate, unbounded and non-primary-leading chunks fail before exchanges', () async {
    for (final ids in [
      '2,1',
      '1,1',
      '1,',
      '1,\$(echo unsafe)',
      List.generate(21, (i) => '${i + 1}').join(','),
    ]) {
      expect((await run('1', ids)).exitCode, isNot(0), reason: ids);
    }
    expect(File('${temp.path}/observed').existsSync(), false);
  });
}
