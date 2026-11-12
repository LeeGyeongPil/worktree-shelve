// AC-4: `git worktree remove` 가 지우는 무시 파일 중 산출물이 아닌 것만 백업한다. 상한을 넘으면 보존.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:worktree_shelve/worktree_shelve.dart';

import 'support/fixture.dart';

void main() {
  late Fixture fx;
  setUp(() async => fx = await Fixture.create());
  tearDown(() => fx.dispose());

  test('ignored.tar holds .env, .env.local and config.local.json but not node_modules or dist', () async {
    final repo = await fx.makeRepo('root/repo');
    final wt = await fx.addWorktree(repo, 'root/wt/cfg', branch: 'cfg', ageDays: null);
    fx.b.write('$wt/.env', 'A=1\n');
    fx.b.write('$wt/.env.local', 'B=2\n');
    fx.b.write('$wt/config.local.json', '{"port": 3000}\n');
    fx.b.write('$wt/node_modules/pkg/index.js', 'x\n');
    fx.b.write('$wt/dist/app.js', 'y\n');
    await fx.age(wt, 30);

    final run = await fx.cli(
        ['scan', '--root', '${fx.base}/root', '--apply', '--json', '--backup-dir', fx.backups]);
    expect(run.code, 0, reason: run.err);
    final item = Fixture.item(run.json, '/wt/cfg');
    expect(item['verdict'], 'remove');
    expect(item['result'], 'ok');
    expect(Directory(wt).existsSync(), isFalse);

    final dir = '${fx.backups}/${item['backup_id']}';
    final tar = findExecutable('tar', fx.env)!;
    final listed = Process.runSync(tar, ['-t', '-f', '$dir/ignored.tar']).stdout as String;
    final names = listed.split('\n').where((l) => l.isNotEmpty).toSet();
    expect(names, {'.env', '.env.local', 'config.local.json'});

    final manifest = jsonDecode(File('$dir/manifest.json').readAsStringSync()) as Map<String, Object?>;
    final ignored = (manifest['ignored'] as List).map((e) => (e as Map)['path']).toSet();
    expect(ignored, {'.env', '.env.local', 'config.local.json'});
    expect(File('$dir/untracked.tar').existsSync(), isFalse, reason: 'nothing untracked');
  });

  test('ignored non-build files over --ignored-cap keep the worktree (ignored_too_large)', () async {
    final repo = await fx.makeRepo('root/repo');
    final wt = await fx.addWorktree(repo, 'root/wt/bigdata', branch: 'bigdata', ageDays: null);
    fx.b.writeBytes('$wt/data.local.json', List.filled(2 * 1024 * 1024, 32)); // 2 MB
    fx.b.writeBytes('$wt/node_modules/huge/blob.js', List.filled(3 * 1024 * 1024, 32)); // 산출물은 상한과 무관
    await fx.age(wt, 30);
    final small = await fx.addWorktree(repo, 'root/wt/small', branch: 'small', ageDays: null);
    fx.b.writeBytes('$small/node_modules/huge/blob.js', List.filled(3 * 1024 * 1024, 32));
    fx.b.write('$small/.env', 'A=1\n');
    await fx.age(small, 30);

    final run = await fx.cli([
      'scan', '--root', '${fx.base}/root', '--apply', '--json', //
      '--backup-dir', fx.backups, '--ignored-cap', '1',
    ]);
    expect(run.code, 0, reason: run.err);
    final big = Fixture.item(run.json, '/wt/bigdata');
    expect(big['verdict'], 'keep');
    expect(big['reason'], 'ignored_too_large');
    expect(Directory(wt).existsSync(), isTrue);
    // 산출물(3 MB node_modules)은 상한 계산에 들어가지 않아 작은 쪽은 지워진다.
    final smallItem = Fixture.item(run.json, '/wt/small');
    expect(smallItem['verdict'], 'remove');
    expect(Directory(small).existsSync(), isFalse);
  });
}
