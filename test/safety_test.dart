// AC-5: 지우면 안 되는 워크트리는 --apply 뒤에도 남는다. 분리된 커밋은 참조로 고정된다.
import 'dart:io';

import 'package:test/test.dart';

import 'support/fixture.dart';

void main() {
  late Fixture fx;
  setUp(() async => fx = await Fixture.create());
  tearDown(() => fx.dispose());

  test('locked, main, cwd, outside --root and mounted worktrees survive; detached commit is pinned',
      () async {
    final root = '${fx.base}/root';
    final repo = await fx.makeRepo('root/repo');
    await fx.age(repo, 30);
    final locked = await fx.addWorktree(repo, 'root/wt/locked', branch: 'locked');
    await fx.gitRun(repo, ['worktree', 'lock', '--reason', 'agent running', locked]);
    final here = await fx.addWorktree(repo, 'root/wt/here', branch: 'here');
    final outside = await fx.addWorktree(repo, 'elsewhere/out', branch: 'out');
    final mounted = await fx.addWorktree(repo, 'root/wt/mounted', branch: 'mounted');
    Directory('$mounted/disk').createSync();
    await fx.age(mounted, 30);

    // 분리된(detached) 워크트리에서 어떤 브랜치에도 없는 커밋을 만든다.
    final det = '${fx.base}/root/wt/det';
    await fx.b.addWorktree(repo, det);
    fx.b.write('$det/src/only-here.txt', 'only on a detached commit\n');
    final sha = await fx.b.commitAll(det, 'detached work', fx.daysAgo(30));
    await fx.age(det, 30);

    final run = await fx.cli(
      ['scan', '--root', root, '--apply', '--json', '--backup-dir', fx.backups],
      cwd: '$here/src', // 실행 위치가 here 워크트리 안
      mounts: ['$mounted/disk'], // 주입한 마운트 표
    );
    expect(run.code, 0, reason: run.err);
    final json = run.json;
    expect(Fixture.item(json, '/root/repo')['reason'], 'main');
    expect(Fixture.item(json, '/wt/locked')['reason'], 'locked');
    expect(Fixture.item(json, '/wt/here')['reason'], 'cwd');
    expect(Fixture.item(json, '/elsewhere/out')['reason'], 'outside_root');
    expect(Fixture.item(json, '/wt/mounted')['reason'], 'mounted');

    // 다섯 개 모두 git 목록과 디스크에 그대로 있다.
    final listing = await fx.porcelain(repo);
    for (final p in [repo, locked, here, outside, mounted]) {
      expect(listing, contains('worktree $p\x00'), reason: p);
      expect(Directory(p).existsSync(), isTrue, reason: p);
    }

    // 분리된 워크트리는 제거됐고, 커밋은 refs/worktree-shelve/<id> 로 살아 있다.
    final detItem = Fixture.item(json, '/wt/det');
    expect(detItem['verdict'], 'remove', reason: '${detItem['reason']}');
    expect(detItem['result'], 'ok');
    expect(Directory(det).existsSync(), isFalse);
    final ref = detItem['pinned_ref'] as String;
    expect(ref, 'refs/worktree-shelve/${detItem['backup_id']}');
    expect((await fx.gitOut(repo, ['rev-parse', ref])).trim(), sha);
    expect((await fx.gitRun(repo, ['cat-file', '-e', '$sha^{commit}'])).exitCode, 0);
  });

  test('a detached worktree on a commit that a branch contains is not pinned', () async {
    final repo = await fx.makeRepo('root/repo');
    final det = '${fx.base}/root/wt/det2';
    await fx.b.addWorktree(repo, det, from: 'main');
    await fx.age(det, 30);
    final run = await fx.cli(
        ['scan', '--root', '${fx.base}/root', '--apply', '--json', '--backup-dir', fx.backups]);
    expect(run.code, 0, reason: run.err);
    final item = Fixture.item(run.json, '/wt/det2');
    expect(item['result'], 'ok');
    expect(item['pinned_ref'], isNull);
  });
}
