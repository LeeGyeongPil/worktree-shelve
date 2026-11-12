// AC-7: 오류는 트레이스백 없이 정확히 한 줄, `error:`(ko `오류:`)로 시작, 종료 코드 2.
// 영어는 실제 실행 파일(bin/worktree_shelve.dart)을 별도 프로세스로 띄워 확인하고,
// 한국어는 같은 프로세스에서 확인한다.
import 'dart:io';

import 'package:test/test.dart';

import 'support/fixture.dart';

void main() {
  late Fixture fx;
  setUp(() async => fx = await Fixture.create());
  tearDown(() => fx.dispose());

  /// 다섯 가지 오류 상황: (이름, 인자, 환경 덮어쓰기)
  List<(String, List<String>, Map<String, String>)> cases() {
    final emptyBin = Directory('${fx.base}/empty-bin')..createSync(recursive: true);
    final readonly = Directory('${fx.base}/readonly')..createSync(recursive: true);
    Process.runSync('chmod', ['0500', readonly.path]);
    return [
      ('missing root', ['scan', '--root', '${fx.base}/missing'], {}),
      ('unknown option', ['scan', '--frobnicate'], {}),
      ('git not on PATH', ['scan', '--root', fx.base], {'PATH': emptyBin.path}),
      (
        'backup folder permission denied',
        ['scan', '--root', fx.base, '--apply', '--backup-dir', readonly.path],
        {}
      ),
      ('unknown backup id', ['restore', '20200101-000000-nope', '--backup-dir', fx.backups], {}),
    ];
  }

  void expectOneLine(String name, int code, String err, String prefix) {
    final lines = err.split('\n').where((l) => l.isNotEmpty).toList();
    expect(code, 2, reason: '$name: exit code');
    expect(lines, hasLength(1), reason: '$name: $err');
    expect(lines.single, startsWith(prefix), reason: name);
    expect(err, isNot(contains('Unhandled exception')), reason: name);
    expect(err, isNot(contains('#0')), reason: name);
  }

  test('english, through the real executable', () async {
    for (final (name, args, extra) in cases()) {
      if (name.contains('permission') && runningAsRoot) continue;
      final r = await Process.run(
        Platform.resolvedExecutable,
        ['bin/worktree_shelve.dart', ...args],
        workingDirectory: packageRoot,
        environment: {...fx.env, ...extra, 'WORKTREE_SHELVE_LANG': 'en'},
        includeParentEnvironment: false,
      );
      expectOneLine(name, r.exitCode, r.stderr as String, 'error: ');
      expect(r.stdout as String, isEmpty, reason: name);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('korean, in process', () async {
    for (final (name, args, extra) in cases()) {
      if (name.contains('permission') && runningAsRoot) continue;
      final r = await fx.cli(args, envOverride: {...fx.env, ...extra, 'WORKTREE_SHELVE_LANG': 'ko'});
      expectOneLine(name, r.code, r.err, '오류: ');
    }
  });

  test('the error names the user path and the fix', () async {
    final r = await fx.cli(['scan', '--root', '${fx.base}/missing']);
    expect(r.err, contains('${fx.base}/missing'));
    final unknown = await fx.cli(['restore', '20200101-000000-nope', '--backup-dir', fx.backups]);
    expect(unknown.err, contains('worktree-shelve backups'));
    final opt = await fx.cli(['restore', 'x', '--apply']);
    expect(opt.err, contains('unknown option for restore: --apply'));
    final bad = await fx.cli(['restore', '../escape', '--backup-dir', fx.backups]);
    expect(bad.code, 2);
    expect(bad.err, contains('not a valid backup id'));
  });
}
