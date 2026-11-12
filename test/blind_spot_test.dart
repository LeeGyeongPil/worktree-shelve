// 회귀(Q-3): 백업이 다 담지 못하는 워크트리 — 서브모듈, 안쪽 git 저장소, 끝나지 않은 merge 등.
// 오래됐어도 보존(has_submodules / nested_repo / git_in_progress)하고, `git worktree remove --force` 에 넘기지 않는다.
// 스캔 뒤에 그런 것이 생기면 제거 직전 확인이 멈춘다.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support/fixture.dart';

void main() {
  late Fixture fx;
  setUp(() async => fx = await Fixture.create());
  tearDown(() => fx.dispose());

  /// 로컬 경로(file 프로토콜) 서브모듈을 허용한 git 실행 — 실패하면 테스트 실패.
  Future<void> gitOk(String cwd, List<String> args) async {
    final r = await fx.git.withEnv({'GIT_ALLOW_PROTOCOL': 'file'}).run(args, cwd: cwd);
    expect(r.exitCode, 0, reason: 'git ${args.join(' ')}: ${r.stderrText}');
  }

  /// 서브모듈 `sub` 가 있는 저장소와, 서브모듈을 받아 둔(`update --init`) 워크트리 하나.
  Future<(String repo, String wt)> submoduleWorktree(String name) async {
    final upstream = '${fx.base}/upstream/sub';
    await fx.b.init(upstream);
    fx.b.write('$upstream/s.txt', 's\n');
    await fx.b.commitAll(upstream, 'sub initial', fx.daysAgo(40));

    final repo = await fx.makeRepo('root/app');
    await gitOk(repo, ['submodule', 'add', '-q', upstream, 'sub']);
    await fx.b.commitAll(repo, 'add sub', fx.daysAgo(40));

    final wt = await fx.addWorktree(repo, 'root/wt/$name', branch: name, ageDays: null);
    await gitOk(wt, ['submodule', 'update', '-q', '--init']);
    return (repo, wt);
  }

  List<FileSystemEntity> backupEntries() =>
      Directory(fx.backups).existsSync() ? Directory(fx.backups).listSync() : const [];

  test('uncommitted work inside a submodule: kept, never force-removed, nothing lost', () async {
    final (repo, wt) = await submoduleWorktree('feat');

    // 서브모듈 안에만 있는 커밋(어디에도 push 안 함) + 미커밋 수정 + 미추적 파일, 바깥 수정.
    fx.b.write('$wt/sub/committed.txt', 'committed only here\n');
    final subSha = await fx.b.commitAll('$wt/sub', 'local sub commit', fx.daysAgo(30));
    fx.b.write('$wt/sub/s.txt', 's\nmodified in submodule\n');
    fx.b.write('$wt/sub/only-here.txt', 'work in submodule\n');
    fx.b.write('$wt/src/a.txt', 'alpha\nchanged outside\n');
    await fx.age(wt, 30);

    final logFile = '${fx.base}/logs/sweep.log';
    final run = await fx.cli([
      'scan', '--root', '${fx.base}/root', '--apply', '--json', //
      '--backup-dir', fx.backups, '--log', logFile,
    ]);
    expect(run.code, 0, reason: run.err);
    expect(run.err, isEmpty);
    final item = Fixture.item(run.json, '/wt/feat');
    expect(item['verdict'], 'keep');
    expect(item['reason'], 'has_submodules');
    expect(item['reason_text'], contains('sub'));
    expect(item['result'], isNull);
    expect(item['backup_id'], isNull);

    // 폴더·파일·서브모듈 안 작업·로컬 커밋이 모두 그대로다.
    expect(Directory(wt).existsSync(), isTrue);
    expect(File('$wt/sub/only-here.txt').readAsStringSync(), 'work in submodule\n');
    expect(File('$wt/sub/s.txt').readAsStringSync(), 's\nmodified in submodule\n');
    expect(File('$wt/src/a.txt').readAsStringSync(), 'alpha\nchanged outside\n');
    expect((await fx.gitRun('$wt/sub', ['cat-file', '-e', '$subSha^{commit}'])).exitCode, 0);
    expect(await fx.porcelain(repo), contains('worktree $wt\x00'));
    expect(backupEntries(), isEmpty, reason: 'nothing to back up, no stray backup folder');

    // 로그에는 "건너뜀" 한 줄이 이유와 함께 남는다.
    final lines = File(logFile).readAsLinesSync().where((l) => l.isNotEmpty).toList();
    expect(lines, hasLength(1));
    final entry = jsonDecode(lines.single) as Map<String, Object?>;
    expect(entry['action'], 'skip');
    expect(entry['result'], 'skipped');
    expect(entry['reason'], 'has_submodules');
    expect(entry['path'], wt);
    expect(entry['reason_text'], contains('submodule'));
  });

  test('preview explains the submodule rule in English and Korean', () async {
    final (_, wt) = await submoduleWorktree('feat');
    fx.b.write('$wt/sub/only-here.txt', 'work in submodule\n');
    await fx.age(wt, 30);

    final en = await fx.cli(['scan', '--root', '${fx.base}/root', '--lang', 'en']);
    expect(en.code, 0, reason: en.err);
    final enRow = en.out.split('\n').firstWhere((l) => l.contains('wt/feat'));
    expect(enRow, contains('keep'));
    expect(enRow, contains('submodule sub'));

    final ko = await fx.cli(['scan', '--root', '${fx.base}/root', '--lang', 'ko']);
    expect(ko.code, 0, reason: ko.err);
    final koRow = ko.out.split('\n').firstWhere((l) => l.contains('wt/feat'));
    expect(koRow, contains('보존'));
    expect(koRow, contains('서브모듈 sub'));
    // 미리보기는 회수 예상에 넣지 않는다.
    expect(en.out, contains('Would reclaim 0 B from 0 worktree(s)'));
  });

  test('a clean stale worktree with a submodule is kept and the run exits 0', () async {
    final (repo, wt) = await submoduleWorktree('clean');
    await fx.age(wt, 30);
    expect((await fx.gitOut(wt, ['status', '--porcelain'])).trim(), isEmpty);

    final run = await fx.cli(
        ['scan', '--root', '${fx.base}/root', '--apply', '--json', '--backup-dir', fx.backups]);
    expect(run.code, 0, reason: run.err);
    final item = Fixture.item(run.json, '/wt/clean');
    expect(item['verdict'], 'keep');
    expect(item['reason'], 'has_submodules');
    expect(Directory('$wt/sub').listSync(), isNotEmpty);
    expect(await fx.porcelain(repo), contains('worktree $wt\x00'));
    expect(backupEntries(), isEmpty);
  });

  test('a gone folder whose submodule store remains is kept, not pruned', () async {
    final (repo, wt) = await submoduleWorktree('gone');
    Directory(wt).deleteSync(recursive: true);
    final store = '$repo/.git/worktrees/gone/modules';
    expect(Directory(store).existsSync(), isTrue);

    final run = await fx.cli(
        ['scan', '--root', '${fx.base}/root', '--apply', '--json', '--backup-dir', fx.backups]);
    expect(run.code, 0, reason: run.err);
    final item = Fixture.item(run.json, '/wt/gone');
    expect(item['verdict'], 'keep');
    expect(item['reason'], 'has_submodules');
    expect(Directory(store).existsSync(), isTrue, reason: 'submodule commits live here');
    expect(await fx.porcelain(repo), contains('worktree $wt\x00'));
  });

  test('nested git repositories (untracked, or inside an ignored artifact folder) are kept', () async {
    final repo = await fx.makeRepo('root/repo');

    // 1) 바깥 저장소에 등록하지 않은 안쪽 저장소(미추적 폴더로 보인다).
    final scratch = await fx.addWorktree(repo, 'root/wt/scratch', branch: 'scratch', ageDays: null);
    await fx.b.init('$scratch/tools/scratch');
    fx.b.write('$scratch/tools/scratch/draft.txt', 'draft inside a nested repo\n');
    await fx.age(scratch, 30);

    // 2) 무시되는 산출물 폴더 안에 직접 clone 해서 고치던 의존성(백업 대상이 아니다).
    final patched = await fx.addWorktree(repo, 'root/wt/patched', branch: 'patched', ageDays: null);
    await fx.b.init('$patched/node_modules/forked-lib');
    fx.b.write('$patched/node_modules/forked-lib/patch.js', 'hand-made fix\n');
    await fx.age(patched, 30);

    final run = await fx.cli(
        ['scan', '--root', '${fx.base}/root', '--apply', '--json', '--backup-dir', fx.backups]);
    expect(run.code, 0, reason: run.err);
    final s = Fixture.item(run.json, '/wt/scratch');
    expect(s['verdict'], 'keep');
    expect(s['reason'], 'nested_repo');
    expect(s['reason_text'], contains('tools/scratch'));
    final p = Fixture.item(run.json, '/wt/patched');
    expect(p['verdict'], 'keep');
    expect(p['reason'], 'nested_repo');
    expect(p['reason_text'], contains('node_modules/forked-lib'));

    expect(File('$scratch/tools/scratch/draft.txt').existsSync(), isTrue);
    expect(File('$patched/node_modules/forked-lib/patch.js').readAsStringSync(), 'hand-made fix\n');
    expect(backupEntries(), isEmpty);
  });

  test('a stale worktree stuck in a conflicted merge is kept with its merge state', () async {
    final repo = await fx.makeRepo('root/repo');
    await fx.gitRun(repo, ['branch', 'other']);
    fx.b.write('$repo/src/a.txt', 'main side\n');
    await fx.b.commitAll(repo, 'main side', fx.daysAgo(35));

    // main 이 갈라지기 전(other)에서 출발해 같은 줄을 다르게 고친다 → merge main 이 충돌한다.
    final wt = '${fx.base}/root/wt/merging';
    await fx.b.addWorktree(repo, wt, branch: 'merging', from: 'other');
    fx.b.write('$wt/src/a.txt', 'merging side\n');
    await fx.b.commitAll(wt, 'merging side', fx.daysAgo(30));
    final merge = await fx.gitRun(wt, ['merge', '--no-edit', 'main']);
    expect(merge.exitCode, isNot(0), reason: 'the merge must stop on a conflict');
    expect(await fx.gitOut(wt, ['status', '--porcelain']), contains('UU src/a.txt'));
    await fx.age(wt, 30);
    final mergeHead = '$repo/.git/worktrees/merging/MERGE_HEAD';
    expect(File(mergeHead).existsSync(), isTrue);

    final run = await fx.cli(
        ['scan', '--root', '${fx.base}/root', '--apply', '--json', '--backup-dir', fx.backups]);
    expect(run.code, 0, reason: run.err);
    final item = Fixture.item(run.json, '/wt/merging');
    expect(item['verdict'], 'keep');
    expect(item['reason'], 'git_in_progress');
    expect(item['reason_text'], 'unfinished git merge; backups cannot cover it');
    expect(Directory(wt).existsSync(), isTrue);
    expect(File(mergeHead).existsSync(), isTrue, reason: 'the merge can still be finished');
    expect(await fx.gitOut(wt, ['status', '--porcelain']), contains('UU src/a.txt'));
    expect(backupEntries(), isEmpty);
  });

  test('a nested repo that appears while the backup is written stops the removal', () async {
    final repo = await fx.makeRepo('root/repo');
    final wt = await fx.addWorktree(repo, 'root/wt/late', branch: 'late');

    final run = await fx.cli(
      ['scan', '--root', '${fx.base}/root', '--apply', '--json', '--backup-dir', fx.backups],
      // 스캔 뒤·제거 전에 무시 폴더 안에 저장소가 생긴다(git status 에는 보이지 않는다).
      beforeVerify: (_) {
        final r = Process.runSync(fx.git.executable, ['init', '-q', '$wt/node_modules/late-clone'],
            environment: fx.env, includeParentEnvironment: false);
        expect(r.exitCode, 0, reason: '${r.stderr}');
        File('$wt/node_modules/late-clone/wip.txt').writeAsStringSync('wip\n');
      },
    );
    expect(run.code, 1);
    final item = Fixture.item(run.json, '/wt/late');
    expect(item['verdict'], 'remove');
    expect(item['result'], 'failed');
    expect(item['error'], contains('node_modules/late-clone'));
    expect(run.errLines, hasLength(1));
    expect(run.err, contains('run the scan again'));
    expect(File('$wt/node_modules/late-clone/wip.txt').existsSync(), isTrue);
    expect(await fx.porcelain(repo), contains('worktree $wt\x00'));
  });
}
