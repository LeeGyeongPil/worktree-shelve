// AC-6: 백업을 쓸 수 없거나 검증이 어긋나면 워크트리를 지우지 않는다.
import 'dart:io';

import 'package:test/test.dart';

import 'support/fixture.dart';

void main() {
  late Fixture fx;
  setUp(() async => fx = await Fixture.create());
  tearDown(() => fx.dispose());

  Future<String> dirtyWorktree() async {
    final repo = await fx.makeRepo('root/repo');
    final wt = await fx.addWorktree(repo, 'root/wt/work', branch: 'work', ageDays: null);
    fx.b.write('$wt/src/a.txt', 'changed\n');
    fx.b.write('$wt/notes.md', 'untracked note\n');
    await fx.age(wt, 30);
    return wt;
  }

  test('unwritable backup folder (0500): exit 2 before anything is touched', () async {
    final wt = await dirtyWorktree();
    final locked = Directory('${fx.base}/readonly-backups')..createSync();
    Process.runSync('chmod', ['0500', locked.path]);

    final run = await fx.cli(['scan', '--root', '${fx.base}/root', '--apply', '--backup-dir', locked.path]);
    expect(Directory(wt).existsSync(), isTrue, reason: 'worktree must stay');
    if (runningAsRoot) return; // root 는 0500 폴더에도 쓸 수 있다 — 권한 확인만 건너뛴다.
    expect(run.code, 2);
    expect(run.errLines, hasLength(1));
    expect(run.err, startsWith('error: '));
    expect(run.err, contains(locked.path));
    expect(run.err, contains('--backup-dir'));
    expect(run.out, isEmpty);
  });

  test('verification mismatch: exit 1, worktree stays, no half-written backup', () async {
    final wt = await dirtyWorktree();
    final run = await fx.cli(
      ['scan', '--root', '${fx.base}/root', '--apply', '--backup-dir', fx.backups],
      // 검증 직전에 패치를 잘라 "디스크에 쓴 것과 기대한 것이 다른" 상황을 만든다.
      beforeVerify: (staging) => File('$staging/changes.patch').writeAsStringSync('truncated'),
    );
    expect(run.code, 1);
    expect(Directory(wt).existsSync(), isTrue);
    expect(File('$wt/notes.md').existsSync(), isTrue);
    expect(run.errLines, hasLength(1));
    expect(run.err, startsWith('error: '));
    expect(run.err, contains('backup check failed'));
    expect(run.err, contains(fx.backups));
    expect(run.err, contains('--backup-dir'));
    expect(run.err, isNot(contains('.partial')), reason: 'show the user path, not the temp path');
    // 만들다 만 묶음은 남지 않는다.
    expect(Directory(fx.backups).listSync(), isEmpty);
  });

  test('unreadable untracked file: backup fails, exit 1, worktree stays', () async {
    final wt = await dirtyWorktree();
    fx.b.write('$wt/private-notes.txt', 'cannot read me\n');
    await fx.age(wt, 30);
    Process.runSync('chmod', ['000', '$wt/private-notes.txt']);

    final run = await fx.cli(['scan', '--root', '${fx.base}/root', '--apply', '--backup-dir', fx.backups]);
    expect(Directory(wt).existsSync(), isTrue);
    if (runningAsRoot) return;
    expect(run.code, 1);
    expect(run.errLines, hasLength(1));
    expect(run.err, contains(fx.backups));
    expect(run.out, contains('FAILED'));
    expect(Directory(fx.backups).listSync(), isEmpty);
  });
}
