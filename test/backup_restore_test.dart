// AC-3: 백업 후 제거 → restore 왕복. git status 와 미추적·.env 바이트가 그대로 돌아온다.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support/fixture.dart';

void main() {
  late Fixture fx;
  setUp(() async => fx = await Fixture.create());
  tearDown(() => fx.dispose());

  test('shelve then restore gives the same status and bytes', () async {
    final repo = await fx.makeRepo('root/repo');
    final wt = await fx.addWorktree(repo, 'root/wt/feat', branch: 'feat', ageDays: null);

    // 스테이지된 수정 + 스테이지된 새 파일 + 미스테이지 수정 + 미추적 바이너리 + 무시된 .env
    fx.b.write('$wt/README.md', '# fixture\nstaged line\n');
    fx.b.write('$wt/src/new_staged.txt', 'brand new\n');
    await fx.gitRun(wt, ['add', 'README.md', 'src/new_staged.txt']);
    fx.b.write('$wt/src/a.txt', 'alpha\nunstaged line\n');
    final binary = List<int>.generate(4096, (i) => (i * 37) % 256);
    fx.b.writeBytes('$wt/assets/blob.bin', binary);
    const envText = 'API_BASE_URL=http://127.0.0.1:9000\nMODE=dev\n';
    fx.b.write('$wt/.env', envText);
    await fx.age(wt, 30);

    final statusBefore = await fx.gitOut(wt, ['status', '--porcelain']);
    expect(statusBefore, contains('M  README.md'));
    expect(statusBefore, contains('A  src/new_staged.txt'));
    expect(statusBefore, contains(' M src/a.txt'));
    expect(statusBefore, contains('?? assets/'));

    final run = await fx.cli(
        ['scan', '--root', '${fx.base}/root', '--apply', '--json', '--backup-dir', fx.backups]);
    expect(run.code, 0, reason: run.err);
    final item = Fixture.item(run.json, '/wt/feat');
    expect(item['verdict'], 'shelve');
    expect(item['result'], 'ok');
    final id = item['backup_id'] as String;

    // 폴더는 사라지고 브랜치는 남는다.
    expect(Directory(wt).existsSync(), isFalse);
    expect((await fx.gitRun(repo, ['rev-parse', '--verify', 'refs/heads/feat'])).exitCode, 0);

    // 백업 묶음 파일과 manifest.
    for (final f in ['manifest.json', 'changes.patch', 'staged.patch', 'untracked.tar', 'ignored.tar']) {
      expect(File('${fx.backups}/$id/$f').existsSync(), isTrue, reason: f);
    }
    final manifest =
        jsonDecode(File('${fx.backups}/$id/manifest.json').readAsStringSync()) as Map<String, Object?>;
    expect(manifest['branch'], 'refs/heads/feat');
    expect((manifest['untracked'] as List).single, containsPair('path', 'assets/blob.bin'));
    expect((manifest['ignored'] as List).single, containsPair('path', '.env'));
    expect(((manifest['ignored'] as List).single as Map)['hash'], matches(RegExp(r'^[0-9a-f]{40}$')));

    // backups 목록에도 보인다.
    final list = await fx.cli(['backups', '--backup-dir', fx.backups, '--json']);
    expect(list.code, 0);
    expect(((list.json['backups'] as List).single as Map)['id'], id);

    // 되살리기
    final restore = await fx.cli(['restore', id, '--backup-dir', fx.backups]);
    expect(restore.code, 0, reason: restore.err);
    expect(restore.out, contains('Restored'));
    expect(await fx.gitOut(wt, ['status', '--porcelain']), statusBefore);
    expect(File('$wt/assets/blob.bin').readAsBytesSync(), binary);
    expect(File('$wt/.env').readAsStringSync(), envText);
    expect((await fx.gitOut(wt, ['branch', '--show-current'])).trim(), 'feat');

    // 같은 자리에 다시 restore 하면 한 줄 오류(덮어쓰지 않는다).
    final again = await fx.cli(['restore', id, '--backup-dir', fx.backups]);
    expect(again.code, 2);
    expect(again.errLines, hasLength(1));
    expect(again.err, contains('already exists'));
  });

  test('restore --to puts a clean removed worktree in a new place', () async {
    final repo = await fx.makeRepo('root/repo');
    final wt = await fx.addWorktree(repo, 'root/wt/clean', branch: 'clean', ageDays: null);
    fx.b.write('$wt/.env.local', 'LOCAL=1\n');
    await fx.age(wt, 30);

    final run = await fx.cli(
        ['scan', '--root', '${fx.base}/root', '--apply', '--json', '--backup-dir', fx.backups]);
    final item = Fixture.item(run.json, '/wt/clean');
    expect(item['verdict'], 'remove');
    final id = item['backup_id'] as String;

    final target = '${fx.base}/restored/clean';
    final restore = await fx.cli(['restore', id, '--backup-dir', fx.backups, '--to', target]);
    expect(restore.code, 0, reason: restore.err);
    expect(File('$target/.env.local').readAsStringSync(), 'LOCAL=1\n');
    expect((await fx.gitOut(target, ['status', '--porcelain'])).trim(), isEmpty);
  });

  // 언어마다 따로 저장소를 만든다(앞 언어에서 되살린 워크트리가 다음 스캔에 섞이지 않게).
  for (final lang in ['en', 'ko']) {
    test('restore closing hint keeps --backup-dir and works as printed ($lang)', () async {
      final repo = await fx.makeRepo('root/repo');
      final wt = await fx.addWorktree(repo, 'root/wt/$lang', branch: 'b-$lang', ageDays: null);
      fx.b.write('$wt/src/a.txt', 'changed $lang\n');
      await fx.age(wt, 30);
      final run = await fx.cli(
          ['scan', '--root', '${fx.base}/root', '--apply', '--json', '--backup-dir', fx.backups]);
      expect(run.code, 0, reason: run.err);
      final item = Fixture.item(run.json, '/wt/$lang');
      // 실패하면 판정·이유가 그대로 보이게(백업이 없으면 아래 형 변환 오류만으로는 원인을 알 수 없다).
      expect(item['backup_id'], isA<String>(), reason: '$item');
      final id = item['backup_id'] as String;
      final restore = await fx.cli(['restore', id, '--backup-dir', fx.backups, '--lang', lang]);
      expect(restore.code, 0, reason: restore.err);
      final last = restore.out.trim().split('\n').last;
      expect(last, contains('worktree-shelve backups --delete $id --backup-dir ${fx.backups}'),
          reason: 'full output:\n${restore.out}');
      final del = await fx.cli(['backups', '--delete', id, '--backup-dir', fx.backups]);
      expect(del.code, 0, reason: del.err);
    });
  }

  test('restore closing hint has no --backup-dir when none was given', () async {
    final repo = await fx.makeRepo('root/repo');
    final wt = await fx.addWorktree(repo, 'root/wt/def', branch: 'b-def', ageDays: null);
    fx.b.write('$wt/src/a.txt', 'changed\n');
    await fx.age(wt, 30);
    final env = {...fx.env, 'WORKTREE_SHELVE_BACKUP_DIR': fx.backups};
    final run = await fx.cli(['scan', '--root', '${fx.base}/root', '--apply', '--json'], envOverride: env);
    expect(run.code, 0, reason: run.err);
    final item = Fixture.item(run.json, '/wt/def');
    expect(item['backup_id'], isA<String>(), reason: '$item');
    final id = item['backup_id'] as String;
    final restore = await fx.cli(['restore', id], envOverride: env);
    expect(restore.code, 0, reason: restore.err);
    final last = restore.out.trim().split('\n').last;
    expect(last, endsWith('worktree-shelve backups --delete $id'), reason: 'full output:\n${restore.out}');
    expect(last, isNot(contains('--backup-dir')));
  });
}
