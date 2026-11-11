import 'dart:io';

import 'package:test/test.dart';

void main() {
  final root = Directory.current.parent.parent.path;
  test('workflows never check out the retired executor revision', () {
    for (final file
        in Directory('$root/.github/workflows')
            .listSync()
            .whereType<File>()
            .where((file) => file.path.endsWith('.yml'))) {
      expect(
        file.readAsStringSync(),
        isNot(contains('fafbdb68079ccce698e08e04bdc55f3d4e846715')),
        reason: file.path,
      );
    }
  });
  test(
    'compile remains uncredentialed; prepare/sign/finalize are isolated',
    () {
      final workflow = File('$root/.github/workflows/android-build.yml')
          .readAsStringSync();
      String job(String start, String end) =>
          workflow.split('  $start:\n')[1].split('\n  $end:\n')[0];
      for (final body in [
        job('build-android', 'sign-android'),
        job('build-ios', 'sign-ios'),
      ]) {
        for (final forbidden in [
          'id-token: write',
          'COSMOS_BUILD_CREDENTIAL',
          'COSMOS_BUILD_REPOSITORY_TOKEN',
          'COSMOS_BUILD_SIGN_MATERIAL_URL',
          'COSMOS_BUILD_SPEC_URL',
        ]) {
          expect(body, isNot(contains(forbidden)));
        }
        expect(body, contains('contents: read'));
        expect(body, contains('RUNALL_FROZEN_RESOURCE_ROOT'));
      }
      final prepare = File('$root/.github/workflows/reusable-prepare.yml')
          .readAsStringSync();
      for (final required in [
        'id-token: write',
        'exchange-build-credential',
        'fetch-packaging-resources',
        'checkout-source',
        '.buildInput.source.ref',
      ]) {
        expect(prepare, contains(required));
      }
      for (final stage in [
        'sign-android',
        'sign-ios',
        'finalize-android',
        'finalize-ios',
      ]) {
        expect(workflow, contains('reusable-$stage.yml'));
      }
    },
  );
}
