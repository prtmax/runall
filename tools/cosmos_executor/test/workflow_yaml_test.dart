import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  test(
    'every runtime job checks out executor tools at the active run revision',
    () {
      final root = Directory.current.parent.parent.path;
      var checkouts = 0;
      for (final file in Directory(
        '$root/.github/workflows',
      ).listSync().whereType<File>()) {
        final workflow = loadYaml(file.readAsStringSync()) as YamlMap;
        if (file.path.endsWith('contract-tests.yml')) continue;
        for (final job
            in (workflow['jobs'] as YamlMap).values.cast<YamlMap>()) {
          if (job['steps'] == null) continue;
          final checkout = (job['steps'] as YamlList)
              .cast<YamlMap>()
              .firstWhere(
                (step) => (step['uses'] as String? ?? '').startsWith(
                  'actions/checkout@',
                ),
              );
          final settings = checkout['with'] as YamlMap;
          expect(settings['repository'], 'prtmax/runall');
          expect(settings['persist-credentials'], false);
          expect(settings.containsKey('ref'), false, reason: file.path);
          checkouts++;
        }
      }
      expect(checkouts, 7);
    },
  );
  test(
    'prepare emits per-platform matrices and finalizers isolate item failure',
    () {
      final root = Directory.current.parent.parent.path;
      final prepare = loadYaml(
        File('$root/.github/workflows/reusable-prepare.yml').readAsStringSync(),
      ) as YamlMap;
      final call = prepare['on']['workflow_call'];
      expect(call['inputs']['build_run_ids']['required'], false);
      expect(
        (call['outputs'] as YamlMap).keys,
        containsAll(['has_android', 'has_ios', 'android_matrix', 'ios_matrix']),
      );
      for (final platform in ['android', 'ios']) {
        final sign = loadYaml(
          File('$root/.github/workflows/reusable-sign-$platform.yml')
              .readAsStringSync(),
        ) as YamlMap;
        final steps = sign['jobs']['sign-$platform']['steps'] as YamlList;
        final exchange = steps.indexWhere(
          (dynamic step) =>
              (step['name'] as String? ?? '').startsWith('Exchange OIDC'),
        );
        final unsigned = steps.indexWhere(
          (dynamic step) =>
              step['with']?['name'] == r'unsigned-${{ inputs.build_run_id }}',
        );
        expect(exchange, lessThan(unsigned));
        expect(steps[unsigned]['continue-on-error'], isNull);
        final finalize = File(
          '$root/.github/workflows/reusable-finalize-$platform.yml',
        ).readAsStringSync();
        expect(finalize, contains("if: steps.signed.outcome == 'success'"));
        expect(finalize, contains('./scripts/verify-artifact-set'));
        expect(
          finalize,
          isNot(contains("inputs.upstream_result == 'success'")),
        );
      }
    },
  );

  test('finalize requires every requested signed artifact', () async {
    final root = Directory.current.parent.parent.path;
    final temp = Directory.systemTemp.createTempSync('signed-check');
    try {
      final spec = File('${temp.path}/spec.json')
        ..writeAsStringSync('{"targets":["apk","aab"]}');
      final signed = Directory('${temp.path}/signed')..createSync();
      Future<int> verify() async => (await Process.run('bash', [
        '$root/scripts/verify-artifact-set',
        spec.path,
        signed.path,
      ])).exitCode;
      expect(await verify(), isNot(0));
      File('${signed.path}/app.apk').writeAsStringSync('apk');
      expect(await verify(), isNot(0));
      File('${signed.path}/app.aab').writeAsStringSync('aab');
      expect(await verify(), 0);
      File('${signed.path}/second.apk').writeAsStringSync('ambiguous');
      expect(await verify(), isNot(0));
      spec.writeAsStringSync('{"targets":[]}');
      expect(await verify(), isNot(0));
    } finally {
      temp.deleteSync(recursive: true);
    }
  });
  test('caller fans out bounded independent platform matrices with shared sources', () {
    final root = Directory.current.parent.parent.path;
    final workflow = loadYaml(
      File('$root/.github/workflows/android-build.yml').readAsStringSync(),
    ) as YamlMap;
    expect(
      workflow['on']['workflow_dispatch']['inputs']['build_run_ids']['required'],
      false,
    );
    final jobs = workflow['jobs'] as YamlMap;
    for (final platform in ['android', 'ios']) {
      for (final stage in ['build', 'sign', 'finalize']) {
        final job = jobs['$stage-$platform'];
        expect(job['strategy']['fail-fast'], false);
        expect(job['strategy']['max-parallel'], platform == 'android' ? 4 : 2);
        expect(
          job['strategy']['matrix']['item'],
          contains('fromJson(needs.prepare.outputs.' + platform + '_matrix)'),
        );
        expect(job['if'], contains('!cancelled()'));
        expect(job['if'], isNot(contains('needs.sign-')));
        if (stage != 'build') {
          expect(
            job['with']['build_run_id'],
            r'${{ matrix.item.build_run_id }}',
          );
          expect(
            job['uses'],
            endsWith('@cdea94792a52f4bcfe1bd04fda3d3de27176cd5b'),
          );
        } else {
          final steps = job['steps'] as YamlList;
          expect(
            steps
                .where(
                  (dynamic step) => (step['uses'] as String? ?? '').startsWith(
                    'actions/cache@',
                  ),
                )
                .length,
            greaterThanOrEqualTo(2),
          );
          expect(
            steps.any(
              (dynamic step) =>
                  step['with']?['name'] ==
                  r'source-workspace-${{ matrix.item.source_sha }}',
            ),
            true,
          );
        }
      }
    }
  });
}
