// 테스트 픽스처: 시스템 임시 폴더 안에 실제 git 저장소를 만든다.
//
// - HOME 을 임시 폴더로, 전역·시스템 git 설정을 끈다(GIT_CONFIG_GLOBAL=/dev/null, GIT_CONFIG_NOSYSTEM=1).
// - 화면 언어는 WORKTREE_SHELVE_LANG=en 으로 고정한다(LANG 이 무엇이든 같은 결과).
// - 만든 경로가 임시 폴더 밖이면 즉시 실패한다 — 실제 사용자 저장소를 절대 건드리지 않는다.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:worktree_shelve/worktree_shelve.dart';

class CliRun {
  CliRun(this.code, this.out, this.err);
  final int code;
  final String out;
  final String err;

  List<String> get errLines => err.split('\n').where((l) => l.isNotEmpty).toList();
  Map<String, Object?> get json => jsonDecode(out) as Map<String, Object?>;
}

class Fixture {
  Fixture._(this.base, this.env, this.git) : b = RepoBuilder(git);

  /// 심볼릭 링크를 푼 임시 폴더(예: /tmp/…/wts_XXXX).
  final String base;
  final Map<String, String> env;
  final Git git;
  final RepoBuilder b;
  final DateTime now = DateTime.now();

  String get backups => '$base/backups';

  static Future<Fixture> create() async {
    final tmpRoot = Directory.systemTemp.resolveSymbolicLinksSync();
    final base = Directory.systemTemp.createTempSync('wts_').resolveSymbolicLinksSync();
    if (!base.startsWith('$tmpRoot/')) {
      fail('fixture path escaped the temp folder: $base');
    }
    Directory('$base/home').createSync();
    final env = <String, String>{
      'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin',
      'HOME': '$base/home',
      'GIT_CONFIG_GLOBAL': '/dev/null',
      'GIT_CONFIG_NOSYSTEM': '1',
      'GIT_AUTHOR_NAME': 'fixture',
      'GIT_AUTHOR_EMAIL': 'fixture@example.invalid',
      'GIT_COMMITTER_NAME': 'fixture',
      'GIT_COMMITTER_EMAIL': 'fixture@example.invalid',
      'LANG': 'C.UTF-8',
      'WORKTREE_SHELVE_LANG': 'en',
    };
    final git = await Git.locate(env);
    return Fixture._(base, env, git);
  }

  /// 권한을 되돌린 뒤 임시 폴더를 지운다.
  void dispose() {
    final d = Directory(base);
    if (!d.existsSync()) return;
    Process.runSync('chmod', ['-R', 'u+rwx', base]);
    d.deleteSync(recursive: true);
  }

  DateTime daysAgo(int d) => now.subtract(Duration(days: d));

  /// 메인 저장소 하나(첫 커밋은 40일 전).
  Future<String> makeRepo(String rel) async {
    final repo = '$base/$rel';
    await b.init(repo);
    b.write('$repo/README.md', '# fixture\n');
    b.write('$repo/src/a.txt', 'alpha\n');
    b.write('$repo/.gitignore', 'node_modules/\ndist/\n.env\n.env.*\n*.local.json\nlinks/\n');
    await b.commitAll(repo, 'initial', daysAgo(40));
    return repo;
  }

  /// 연결 워크트리 하나. 커밋은 [commitDaysAgo] 일 전, 파일 시각은 [ageDays] 일 전.
  Future<String> addWorktree(String repo, String rel,
      {String? branch, int commitDaysAgo = 30, int? ageDays = 30}) async {
    final path = '$base/$rel';
    await b.addWorktree(repo, path, branch: branch);
    final name = path.substring(path.lastIndexOf('/') + 1);
    b.write('$path/src/$name.txt', 'work on $name\n');
    await b.commitAll(path, 'work on $name', daysAgo(commitDaysAgo));
    if (ageDays != null) await age(path, ageDays);
    return path;
  }

  Future<void> age(String path, int days) => b.age(path, daysAgo(days));

  Future<String> gitOut(String cwd, List<String> args) => git.text(args, cwd: cwd);

  Future<ProcResult> gitRun(String cwd, List<String> args) => git.run(args, cwd: cwd);

  Future<String> porcelain(String repo) => gitOut(repo, ['worktree', 'list', '--porcelain', '-z']);

  /// 폴더 아래 모든 항목의 (경로, 크기, 수정 시각) — 전후 비교용.
  List<String> listing(String dir) {
    final out = <String>[];
    for (final e in Directory(dir).listSync(recursive: true, followLinks: false)) {
      final st = e.statSync();
      out.add('${e.path}|${st.size}|${st.modified.millisecondsSinceEpoch}');
    }
    out.sort();
    return out;
  }

  /// CLI 를 같은 프로세스에서 실행한다.
  Future<CliRun> cli(
    List<String> args, {
    String? cwd,
    List<String> mounts = const [],
    Map<String, String>? envOverride,
    void Function(String stagingDir)? beforeVerify,
    void Function(String worktreePath)? beforeRemove,
  }) async {
    final out = StringBuffer();
    final err = StringBuffer();
    final code = await runCli(
      args,
      CliContext(
        env: envOverride ?? env,
        cwd: cwd ?? base,
        out: out,
        err: err,
        mountPoints: mounts,
        beforeVerify: beforeVerify,
        beforeRemove: beforeRemove,
      ),
    );
    return CliRun(code, out.toString(), err.toString());
  }

  /// JSON 출력에서 경로 끝부분으로 워크트리 항목을 찾는다.
  static Map<String, Object?> item(Map<String, Object?> json, String pathSuffix) {
    final list = (json['worktrees'] as List<Object?>).cast<Map<String, Object?>>();
    return list.firstWhere((w) => (w['path'] as String).endsWith(pathSuffix),
        orElse: () => throw StateError('no worktree ending with $pathSuffix'));
  }
}

/// root 로 실행 중이면 권한 검사가 의미 없다(그 확인만 건너뛴다).
bool get runningAsRoot {
  try {
    final r = Process.runSync('id', ['-u']);
    return (r.stdout as String).trim() == '0';
  } on Object {
    return false;
  }
}

/// 패키지 루트(dart test 는 패키지 루트에서 돈다).
final String packageRoot = Directory.current.path;
