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
}
