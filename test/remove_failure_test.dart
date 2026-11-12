// 회귀(Q-7): `git worktree remove` 가 도중에 멈추면 git 은 관리 기록을 지우고 폴더 일부만 남긴다.
//
// (A) 미리 막기: 끝까지 지울 수 없는 폴더(읽기 전용 하위 폴더, 읽기 전용 부모 폴더)가 있으면
//     백업도 제거도 하지 않는다 — exit 1, 파일·worktree list 그대로, 백업 폴더 0개.
// (B) 그래도 git 이 멈추면 사실대로 알린다 — 백업 ID, `restore <id> --to` 안내, 로그 기록.
//     그 백업으로 `restore <id> --to` 하면 git status 가 같아진다.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support/fixture.dart';

void main() {
  late Fixture fx;
  setUp(() async => fx = await Fixture.create());
  tearDown(() => fx.dispose());

  /// 오래된 워크트리 하나: 추적 파일 ro/a.txt·z.txt 를 커밋해 두고,
  /// [dirty] 면 z.txt 를 고치고 미추적 new.txt 를 만든다. 파일 시각은 30일 전.
  Future<(String repo, String wt)> staleWorktree(String repoRel, String wtRel, String branch,
      {required bool dirty}) async {
    final repo = await fx.makeRepo(repoRel);
    final wt = await fx.addWorktree(repo, wtRel, branch: branch, ageDays: null);
    fx.b.write('$wt/ro/a.txt', 'tracked in a folder\n');
    fx.b.write('$wt/z.txt', 'original\n');
    await fx.b.commitAll(wt, 'add ro and z', fx.daysAgo(30));
    if (dirty) {
      fx.b.write('$wt/z.txt', 'original\nmy precious edit\n');
      fx.b.write('$wt/new.txt', 'untracked work\n');
    }
    await fx.age(wt, 30);
    return (repo, wt);
  }

  void readOnly(String dir) => Process.runSync('chmod', ['555', dir]);

  List<FileSystemEntity> backupEntries() =>
      Directory(fx.backups).existsSync() ? Directory(fx.backups).listSync() : const [];

  test('read-only folder inside a clean and a dirty stale worktree: nothing backed up or removed',
      () async {
    final (repoA, clean) = await staleWorktree('root/a', 'root/wt/clean', 'clean', dirty: false);
    final (repoB, dirty) = await staleWorktree('root/b', 'root/wt/dirty', 'dirty', dirty: true);
    readOnly('$clean/ro');
    readOnly('$dirty/ro');
    final before = [fx.listing(clean), fx.listing(dirty)];

    final logFile = '${fx.base}/logs/sweep.log';
    final run = await fx.cli([
      'scan', '--root', '${fx.base}/root', '--apply', //
      '--backup-dir', fx.backups, '--log', logFile,
    ]);
    if (runningAsRoot) return; // root 는 읽기 전용 폴더도 지울 수 있다 — 권한 확인만 건너뛴다.

    expect(run.code, 1, reason: run.err);
    expect(run.errLines, hasLength(2));
    for (final (wt, line) in [(clean, run.errLines[0]), (dirty, run.errLines[1])]) {
      expect(line, startsWith('error: '));
      expect(line, contains('$wt/ro'), reason: 'names the folder that blocks removal');
      expect(line, contains('chmod -R u+w'));
      expect(line, contains('Nothing was removed'));
    }
    expect(run.out, contains('FAILED   wt/clean'));
    expect(run.out, contains('FAILED   wt/dirty'));

    // 모든 파일이 그대로, worktree list 에도 그대로, 백업 폴더는 0개.
    expect([fx.listing(clean), fx.listing(dirty)], before);
    expect(File('$dirty/z.txt').readAsStringSync(), 'original\nmy precious edit\n');
    expect(await fx.porcelain(repoA), contains('worktree $clean\x00'));
    expect(await fx.porcelain(repoB), contains('worktree $dirty\x00'));
    expect(backupEntries(), isEmpty);

    // 로그에는 실패 두 줄(백업 ID 없음).
    final lines = File(logFile).readAsLinesSync().where((l) => l.isNotEmpty).toList();
    expect(lines, hasLength(2));
    for (final l in lines) {
      final entry = jsonDecode(l) as Map<String, Object?>;
      expect(entry['result'], 'failed');
      expect(entry['backup_id'], isNull);
      expect(entry['error'], contains('chmod -R u+w'));
    }
  });

  test('read-only parent folder: the worktree folder itself cannot be deleted, so it is kept',
      () async {
    final (repo, wt) = await staleWorktree('root/app', 'root/frozen/wt', 'frozen', dirty: true);
    readOnly('${fx.base}/root/frozen');
    final before = fx.listing(wt);

    final run = await fx.cli(['scan', '--root', '${fx.base}/root', '--apply', '--backup-dir', fx.backups]);
    if (runningAsRoot) return;
    expect(run.code, 1, reason: run.err);
    expect(run.errLines, hasLength(1));
    expect(run.err, contains('${fx.base}/root/frozen'));
    expect(run.err, contains('chmod -R u+w'));
    expect(fx.listing(wt), before);
    expect(await fx.porcelain(repo), contains('worktree $wt\x00'));
    expect(backupEntries(), isEmpty);
  });

  test('git stops midway: the message has the backup id and a --to restore that brings the work back',
      () async {
    final (repo, wt) = await staleWorktree('root/app', 'root/wt/work', 'work', dirty: true);
    final statusBefore = await fx.gitOut(wt, ['status', '--porcelain=v1', '--untracked-files=all']);
    expect(statusBefore, contains(' M z.txt'));
    expect(statusBefore, contains('?? new.txt'));

    final logFile = '${fx.base}/logs/sweep.log';
    final run = await fx.cli(
      ['scan', '--root', '${fx.base}/root', '--apply', '--backup-dir', fx.backups, '--log', logFile],
      // 사전 확인이 끝난 뒤, git 이 지우기 직전에 하위 폴더를 읽기 전용으로 바꾼다
      // (사전 확인 뒤에 다른 프로그램이 권한을 바꾼 상황) — git 은 일부만 지우고 멈춘다.
      beforeRemove: (path) => readOnly('$path/ro'),
    );
    if (runningAsRoot) return;

    expect(run.code, 1, reason: run.err);
    // git 이 관리 기록을 지우고 폴더 일부를 남겼다(이 테스트가 만들려는 상황인지 먼저 확인).
    expect(await fx.porcelain(repo), isNot(contains('worktree $wt\x00')));
    expect(Directory(wt).existsSync(), isTrue);
    expect(File('$wt/z.txt').existsSync(), isFalse, reason: 'git deleted part of the folder');

    final ids = backupEntries().map((e) => e.uri.pathSegments.where((s) => s.isNotEmpty).last).toList();
    expect(ids, hasLength(1), reason: 'the verified backup is kept');
    final id = ids.single;

    // stderr 한 줄: 무엇이 일어났는지, 백업 ID, --to 복원 명령, 남은 폴더 경로. "그대로 남겼다"는 말은 없다.
    expect(run.errLines, hasLength(1));
    final line = run.errLines.single;
    expect(line, startsWith('error: '));
    expect(line, contains('dropped the worktree record'));
    expect(line, contains(id));
    expect(line, contains('worktree-shelve restore $id --backup-dir ${fx.backups} --to'));
    expect(line, contains(wt), reason: 'tells where the leftover folder is');
    expect(line, isNot(contains('left in place')));
    // 표 아래에도 FAILED 와 복원 명령이 찍힌다.
    expect(run.out, contains('FAILED   wt/work'));
    expect(run.out, contains('restore: worktree-shelve restore $id --backup-dir ${fx.backups} --to'));

    // 로그에서도 찾을 수 있다: 실패, 백업 ID, 복원 명령.
    final entry = jsonDecode(File(logFile).readAsLinesSync().where((l) => l.isNotEmpty).single)
        as Map<String, Object?>;
    expect(entry['result'], 'failed');
    expect(entry['backup_id'], id);
    expect(entry['restore_command'], contains('--to'));
    expect(entry['error'], contains('dropped the worktree record'));

    // 남은 폴더 자리에는 되살릴 수 없고(exit 2), --to 로는 되살아난다 — 상태와 내용이 같다.
    final occupied = await fx.cli(['restore', id, '--backup-dir', fx.backups]);
    expect(occupied.code, 2);
    final target = '${fx.base}/root/wt/work-restored';
    final restored = await fx.cli(['restore', id, '--backup-dir', fx.backups, '--to', target]);
    expect(restored.code, 0, reason: restored.err);
    expect(await fx.gitOut(target, ['status', '--porcelain=v1', '--untracked-files=all']), statusBefore);
    expect(File('$target/z.txt').readAsStringSync(), 'original\nmy precious edit\n');
    expect(File('$target/new.txt').readAsStringSync(), 'untracked work\n');
    expect(File('$target/ro/a.txt').readAsStringSync(), 'tracked in a folder\n');
  });

  test('git refuses without deleting: still listed, files intact, backup id reported and kept',
      () async {
    final (repo, wt) = await staleWorktree('root/app', 'root/wt/tidy', 'tidy', dirty: false);
    final run = await fx.cli(
      ['scan', '--root', '${fx.base}/root', '--apply', '--backup-dir', fx.backups],
      // 깨끗한 워크트리는 --force 없이 지운다 — 직전에 새 파일이 생기면 git 이 아무것도 지우지 않고 거부한다.
      beforeRemove: (path) => File('$path/late.txt').writeAsStringSync('appeared late\n'),
    );
    expect(run.code, 1, reason: run.err);
    expect(await fx.porcelain(repo), contains('worktree $wt\x00'));
    expect(File('$wt/z.txt').readAsStringSync(), 'original\n');
    expect(File('$wt/late.txt').existsSync(), isTrue);
    final ids = backupEntries().map((e) => e.uri.pathSegments.where((s) => s.isNotEmpty).last).toList();
    expect(ids, hasLength(1));
    expect(run.errLines, hasLength(1));
    expect(run.err, contains('git still lists the worktree'));
    expect(run.err, contains(ids.single));
  });
}
