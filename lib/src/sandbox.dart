/// 연습용 샌드박스: 실제 git 저장소 1개와 워크트리 5개를 만들고 날짜를 일부러 과거로 돌린다.
///
/// README 의 교훈을 그대로 재현한다.
///   old-clean    커밋·파일 모두 30일 전, 변경 없음, node_modules 있음  → remove
///   old-dirty    30일 전, 미커밋 변경 + 미추적 메모 + 무시된 .env      → shelve(.env 까지 백업)
///   recent-edit  커밋은 30일 전이지만 파일을 1시간 전에 고침          → keep(recent_edit)
///   agent-run    오래됐지만 잠김("agent running")                      → keep(locked)
///   gone         폴더가 이미 사라짐                                    → prune
///
/// [RepoBuilder] 는 테스트 픽스처도 같이 쓴다(같은 방식으로 저장소를 만든다).
library;

import 'dart:io';

import 'errors.dart';
import 'git.dart';

/// 연습 폴더 표지 파일. 이 파일이 있는 폴더만 다시 만들 때 지운다.
const sandboxMarker = '.shelve-sandbox';

class RepoBuilder {
  RepoBuilder(this.git);

  final Git git;

  /// 커밋 작성자·날짜를 환경 변수로 넘긴다(사용자 git 설정을 바꾸지 않는다).
  Git _dated(DateTime when) {
    final stamp = '@${when.millisecondsSinceEpoch ~/ 1000} +0000';
    return git.withEnv({
      'GIT_AUTHOR_NAME': 'worktree-shelve sandbox',
      'GIT_AUTHOR_EMAIL': 'sandbox@example.invalid',
      'GIT_COMMITTER_NAME': 'worktree-shelve sandbox',
      'GIT_COMMITTER_EMAIL': 'sandbox@example.invalid',
      'GIT_AUTHOR_DATE': stamp,
      'GIT_COMMITTER_DATE': stamp,
    });
  }

  Future<void> _ok(Future<ProcResult> run, String what) async {
    final r = await run;
    if (r.exitCode != 0) throw ShelveError('err.git_failed', {'cmd': what, 'why': r.firstErrorLine});
  }

  Future<void> init(String dir) async {
    Directory(dir).createSync(recursive: true);
    await _ok(git.run(['init', '-q', '-b', 'main', dir]), 'init');
  }

  /// 모든 변경을 [when] 시각의 커밋 하나로 남긴다.
  /// 훅·서명 설정에 영향받지 않게 배관 명령(write-tree·commit-tree·update-ref)으로 만든다.
  Future<String> commitAll(String dir, String message, DateTime when) async {
    final g = _dated(when);
    await _ok(g.run(['add', '-A'], cwd: dir), 'add');
    final tree = (await g.text(['write-tree'], cwd: dir)).trim();
    final parent = await g.run(['rev-parse', '-q', '--verify', 'HEAD'], cwd: dir);
    final commit = (await g.text([
      'commit-tree',
      '--no-gpg-sign',
      tree,
      if (parent.exitCode == 0) ...['-p', parent.stdoutText.trim()],
      '-m',
      message,
    ], cwd: dir))
        .trim();
    await _ok(g.run(['update-ref', 'HEAD', commit], cwd: dir), 'update-ref');
    return commit;
  }

  Future<void> addWorktree(String repo, String path, {String? branch, String from = 'HEAD'}) =>
      _ok(
          git.run([
            'worktree',
            'add',
            '-q',
            if (branch != null) ...['-b', branch] else '--detach',
            path,
            from,
          ], cwd: repo),
          'worktree add');

  void write(String path, String content) {
    File(path)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  void writeBytes(String path, List<int> bytes) {
    File(path)
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(bytes);
  }

  /// 폴더 아래 파일·폴더의 수정 시각을 [when] 으로 돌린다(링크는 건드리지 않는다).
  /// 파일은 Dart 로, 폴더는 `touch` 로 바꾼다(Dart 는 폴더 시각을 바꾸지 못한다).
  Future<void> age(String root, DateTime when) async {
    final dirs = <String>[root];
    for (final e in Directory(root).listSync(recursive: true, followLinks: false)) {
      if (e is File) {
        e.setLastModifiedSync(when);
      } else if (e is Directory) {
        dirs.add(e.path);
      }
    }
    final u = when.toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp = '${u.year}${two(u.month)}${two(u.day)}${two(u.hour)}${two(u.minute)}.${two(u.second)}';
    final touch = findExecutable('touch', git.env) ?? '/usr/bin/touch';
    for (var i = 0; i < dirs.length; i += 200) {
      final batch = dirs.sublist(i, i + 200 > dirs.length ? dirs.length : i + 200);
      // TZ=UTC 로 고정해 시간대와 무관하게 같은 시각이 되게 한다.
      final r = await runProcess(touch, ['-t', stamp, ...batch], env: {...git.env, 'TZ': 'UTC'});
      if (r.exitCode != 0) {
        throw ShelveError('err.fs', {'path': root, 'why': r.firstErrorLine});
      }
    }
  }
}

/// 연습 폴더를 만든다. 이미 있으면 표지 파일이 있을 때만 지우고 다시 만든다.
Future<void> buildSandbox(String dir, Git git, DateTime now) async {
  final d = Directory(dir);
  if (d.existsSync()) {
    final isSandbox = File('$dir/$sandboxMarker').existsSync();
    if (!isSandbox && d.listSync().isNotEmpty) {
      throw ShelveError('err.sandbox_not_empty', {'path': dir});
    }
    if (isSandbox) d.deleteSync(recursive: true);
  }
  d.createSync(recursive: true);
  File('$dir/$sandboxMarker').writeAsStringSync(
      'Practice sandbox made by worktree-shelve. Dates are back-dated on purpose. Safe to delete.\n');

  final b = RepoBuilder(git);
  final repo = '$dir/demo-app';
  final old = now.subtract(const Duration(days: 30));
  final older = now.subtract(const Duration(days: 40));

  await b.init(repo);
  b.write('$repo/README.md', '# demo-app\n\nA tiny app used by the worktree-shelve sandbox.\n');
  b.write('$repo/src/app.txt', 'print("hello")\n');
  b.write('$repo/.gitignore', 'node_modules/\ndist/\n.env\n.env.*\n');
  await b.commitAll(repo, 'initial commit', older);

  // 워크트리 5개 — 각각 브랜치를 만들고 30일 전 커밋 하나씩.
  final names = ['old-clean', 'old-dirty', 'recent-edit', 'agent-run', 'gone'];
  for (final name in names) {
    final wt = '$dir/worktrees/$name';
    await b.addWorktree(repo, wt, branch: 'feature/$name');
    b.write('$wt/src/$name.txt', 'work on $name\n');
    await b.commitAll(wt, 'work on $name', old);
  }

  // old-clean: 변경은 없고 산출물만 큼직하다(회수 예상 크기가 보이도록).
  b.writeBytes('$dir/worktrees/old-clean/node_modules/left-pad/index.js', List.filled(1536 * 1024, 0x61));
  b.writeBytes('$dir/worktrees/old-clean/dist/app.js', List.filled(256 * 1024, 0x62));

  // old-dirty: 미스테이지·스테이지 변경, 미추적 메모, 무시된 .env(git worktree remove 가 지우는 파일).
  final dirty = '$dir/worktrees/old-dirty';
  b.write('$dirty/src/app.txt', 'print("hello, unfinished change")\n');
  b.write('$dirty/README.md', '# demo-app\n\nStaged note that was never committed.\n');
  await b.git.run(['add', 'README.md'], cwd: dirty);
  b.write('$dirty/notes/todo.md', '- finish the parser\n');
  b.write('$dirty/.env', 'API_BASE_URL=http://127.0.0.1:8080\nFEATURE_FLAG=on\n');
  b.writeBytes('$dirty/node_modules/big-lib/lib.js', List.filled(768 * 1024, 0x63));

  // 모든 워크트리의 파일·폴더 시각을 30일 전으로.
  for (final name in names) {
    await b.age('$dir/worktrees/$name', old);
  }

  // recent-edit: 커밋은 오래됐지만 1시간 전에 파일을 고쳤다 → 보존해야 한다.
  final recent = File('$dir/worktrees/recent-edit/src/app.txt');
  recent.writeAsStringSync('print("still working on this")\n');
  recent.setLastModifiedSync(now.subtract(const Duration(hours: 1)));

  // agent-run: 에이전트가 쓰는 중이라는 잠금.
  await b._ok(
      git.run(['worktree', 'lock', '--reason', 'agent running', '$dir/worktrees/agent-run'],
          cwd: repo),
      'worktree lock');

  // gone: 폴더만 지워져 관리 기록이 남은 상태.
  Directory('$dir/worktrees/gone').deleteSync(recursive: true);
}
