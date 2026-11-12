// CI portability guard: tests and sources must not depend on the machine they were written on.
// (no OS-specific absolute paths, no global git config, no assumed default branch)
import 'dart:io';

import 'package:test/test.dart';

import 'support/fixture.dart';

List<File> sources() => [
      for (final dir in ['lib', 'bin', 'test'])
        if (Directory(dir).existsSync())
          ...Directory(dir)
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.dart') && !f.path.endsWith('portability_test.dart')),
    ];

void main() {
  test('sources contain no OS-specific absolute paths or global git assumptions', () {
    final banned = <String>[
      '/' 'Users' '/',
      '/' 'private' '/',
      '/' 'var' '/folders',
      '/' 'Volumes' '/',
      'git config --global',
      "'master'",
      '"master"',
    ];
    final hits = <String>[];
    for (final f in sources()) {
      final text = f.readAsStringSync();
      for (final b in banned) {
        if (text.contains(b)) hits.add('${f.path}: $b');
      }
    }
    expect(hits, isEmpty);
  });

  test('fixture isolates git from the machine: no global config, fixed identity, own HOME', () async {
    final fx = await Fixture.create();
    addTearDown(fx.dispose);
    expect(fx.env['GIT_CONFIG_GLOBAL'], '/dev/null');
    expect(fx.env['GIT_CONFIG_NOSYSTEM'], '1');
    for (final k in ['GIT_AUTHOR_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_COMMITTER_NAME', 'GIT_COMMITTER_EMAIL']) {
      expect(fx.env[k], isNotEmpty, reason: k);
    }
    expect(fx.env['HOME'], startsWith(fx.base));
    // A repo made by the fixture works without any user.name/user.email in config.
    final repo = await fx.makeRepo('repo');
    expect(await fx.gitOut(repo, ['rev-parse', '--abbrev-ref', 'HEAD']), 'main\n');
    expect(await fx.gitOut(repo, ['config', '--get', 'user.name']).catchError((_) => ''), isEmpty);
  });
}
