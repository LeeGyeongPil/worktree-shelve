// AC-9: --json 은 유효한 JSON, --apply --log 는 동작마다 JSON 한 줄을 덧붙인다(기존 줄 보존).
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support/fixture.dart';

void main() {
  late Fixture fx;
  setUp(() async => fx = await Fixture.create());
  tearDown(() => fx.dispose());

  test('--json has repo, path, verdict, reason, size and backup id fields', () async {
    final repo = await fx.makeRepo('root/repo');
    final wt = await fx.addWorktree(repo, 'root/wt/dirty', branch: 'dirty', ageDays: null);
    fx.b.write('$wt/src/a.txt', 'changed\n');
    await fx.age(wt, 30);

    final run = await fx.cli(['scan', '--root', '${fx.base}/root', '--json']);
    expect(run.code, 0, reason: run.err);
    final json = run.json;
    expect(json['tool'], 'worktree-shelve');
    final list = (json['worktrees'] as List).cast<Map<String, Object?>>();
    expect(list, hasLength(2));
    for (final w in list) {
      for (final key in ['repo', 'path', 'verdict', 'reason', 'size_bytes', 'backup_id']) {
        expect(w.containsKey(key), isTrue, reason: key);
      }
    }
    final item = Fixture.item(json, '/wt/dirty');
    expect(item['repo'], repo);
    expect(item['verdict'], 'shelve');
    expect(item['size_bytes'], isA<int>());
    expect((json['totals'] as Map)['reclaim_bytes'], item['size_bytes']);
  });

  test('--apply --log appends one line per action and keeps old lines', () async {
    final repo = await fx.makeRepo('root/repo');
    await fx.addWorktree(repo, 'root/wt/one', branch: 'one');
    final two = await fx.addWorktree(repo, 'root/wt/two', branch: 'two', ageDays: null);
    fx.b.write('$two/notes.md', 'note\n');
    await fx.age(two, 30);

    final logFile = File('${fx.base}/logs/sweep.log')..createSync(recursive: true);
    const old = '{"old":1}\n{"old":2}\n';
    logFile.writeAsStringSync(old);

    final run = await fx.cli([
      'scan', '--root', '${fx.base}/root', '--apply', //
      '--backup-dir', fx.backups, '--log', logFile.path,
    ]);
    expect(run.code, 0, reason: run.err);
    final text = logFile.readAsStringSync();
    expect(text, startsWith(old));
    final lines = text.split('\n').where((l) => l.isNotEmpty).toList();
    expect(lines, hasLength(4));
    final actions = <String>{};
    for (final line in lines.skip(2)) {
      final e = jsonDecode(line) as Map<String, Object?>;
      expect(e['result'], 'ok');
      expect(e['restore_command'], startsWith('worktree-shelve restore '));
      expect(e['restore_command'], contains('--backup-dir ${fx.backups}'));
      actions.add(e['action'] as String);
    }
    expect(actions, {'remove', 'shelve'});

    // 두 번째 실행(할 일 없음)은 줄을 늘리지 않는다.
    await fx.cli(['scan', '--root', '${fx.base}/root', '--apply', '--backup-dir', fx.backups, '--log', logFile.path]);
    expect(logFile.readAsStringSync().split('\n').where((l) => l.isNotEmpty), hasLength(4));
  });
}
