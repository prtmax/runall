import 'dart:io';

import 'package:yaml/yaml.dart';

/// One row per repository: name followed by any exact commits pub must clone.
Iterable<String> privateGitDependencies(Directory workspace) {
  final repos = <String, Set<String>>{};
  final privateUrl = RegExp(r'^https://github\.com/prtmax/([A-Za-z0-9_.-]+)$');
  final commit = RegExp(r'^[0-9a-f]{40}$');

  void record(Object? url, {Map? lock}) {
    if (url is! String) return;
    var repo = privateUrl.firstMatch(url)?.group(1);
    if (repo == null) return;
    if (repo.endsWith('.git')) repo = repo.substring(0, repo.length - 4);
    if (repo.isEmpty) throw const FormatException('Empty Git repository name');
    final revisions = repos.putIfAbsent(repo, () => <String>{});
    if (lock != null) {
      final sha = lock['resolved-ref'];
      if (sha is! String || !commit.hasMatch(sha)) {
        throw FormatException('Missing or invalid resolved-ref for $repo');
      }
      revisions.add(sha);
    }
  }

  void scan(Directory directory) {
    for (final entry in directory.listSync(followLinks: false)) {
      final name = entry.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (entry is Directory) {
        if (!{'.git', '.dart_tool', 'build'}.contains(name)) scan(entry);
        continue;
      }
      if (entry is! File ||
          !{
            'pubspec.lock',
            'pubspec.yaml',
            'pubspec_overrides.yaml',
          }.contains(name)) {
        continue;
      }
      final doc = loadYaml(entry.readAsStringSync(), sourceUrl: entry.uri);
      if (doc is! Map) continue;
      if (name == 'pubspec.lock') {
        final packages = doc['packages'];
        if (packages is! Map) continue;
        for (final pkg in packages.values) {
          if (pkg is! Map || pkg['source'] != 'git') continue;
          final description = pkg['description'];
          if (description is Map) record(description['url'], lock: description);
        }
      } else {
        for (final section in [
          'dependencies',
          'dev_dependencies',
          'dependency_overrides',
        ]) {
          final deps = doc[section];
          if (deps is! Map) continue;
          for (final dep in deps.values) {
            if (dep is! Map) continue;
            final git = dep['git'];
            record(git is Map ? git['url'] : git);
          }
        }
      }
    }
  }

  scan(workspace);
  return repos.entries.map((e) => [e.key, ...e.value].join(' '));
}
