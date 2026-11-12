/// git·tar 같은 외부 프로그램을 부르는 얇은 래퍼.
///
/// - 실행 파일은 우리가 받은 환경 변수의 PATH 에서 직접 찾는다(테스트가 PATH 를 바꿔 끼울 수 있게).
/// - 출력은 바이트로 받는다(패치에는 바이너리가 섞일 수 있다).
/// - 실패는 [ShelveError] 로 바꿔 한 줄 오류로 보여 줄 수 있게 한다.
library;

import 'dart:convert';
import 'dart:io';

import 'errors.dart';

/// 프로세스 실행 결과(바이트 그대로).
class ProcResult {
  ProcResult(this.exitCode, this.stdoutBytes, this.stderrBytes);
  final int exitCode;
  final List<int> stdoutBytes;
  final List<int> stderrBytes;

  String get stdoutText => utf8.decode(stdoutBytes, allowMalformed: true);
  String get stderrText => utf8.decode(stderrBytes, allowMalformed: true);

  /// 오류 메시지에 넣을 stderr 첫 줄(없으면 종료 코드).
  String get firstErrorLine {
    final lines = stderrText.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty);
    return lines.isEmpty ? 'exit $exitCode' : lines.first;
  }
}

/// PATH 에서 실행 파일을 찾는다. 없으면 null.
String? findExecutable(String name, Map<String, String> env) {
  final path = env['PATH'] ?? '';
  for (final dir in path.split(':')) {
    if (dir.isEmpty) continue;
    final candidate = '$dir/$name';
    final stat = FileStat.statSync(candidate);
    // 일반 파일이고 실행 권한 비트(사용자·그룹·기타 중 하나)가 있으면 쓴다.
    if (stat.type == FileSystemEntityType.file && (stat.mode & 0x49) != 0) {
      return candidate;
    }
  }
  return null;
}

/// 프로세스를 띄워 stdin 을 넣고 stdout·stderr 를 끝까지 읽은 뒤 결과를 돌려준다.
/// 세 스트림을 동시에 비워야 큰 출력에서 멈추지 않는다.
Future<ProcResult> runProcess(
  String executable,
  List<String> args, {
  required Map<String, String> env,
  String? cwd,
  List<int>? stdinBytes,
}) async {
  final process = await Process.start(
    executable,
    args,
    workingDirectory: cwd,
    environment: env,
    includeParentEnvironment: false,
  );
  final out = <int>[];
  final err = <int>[];
  final outDone = process.stdout.forEach(out.addAll);
  final errDone = process.stderr.forEach(err.addAll);
  if (stdinBytes != null) process.stdin.add(stdinBytes);
  await process.stdin.close();
  final code = await process.exitCode;
  await outDone;
  await errDone;
  return ProcResult(code, out, err);
}

/// git 호출 도우미. 저장소 위치는 매번 `-C` 로 넘긴다.
class Git {
  Git._(this.executable, this.env);

  final String executable;
  final Map<String, String> env;

  /// PATH 에서 git 을 찾고 버전(2.36 이상)을 확인한다.
  static Future<Git> locate(Map<String, String> baseEnv) async {
    final exe = findExecutable('git', baseEnv);
    if (exe == null) throw ShelveError('err.git_missing');

    // 사용자가 git 훅 안에서 실행해도 -C 가 엉뚱한 저장소를 보지 않도록 위치 변수를 뺀다.
    final env = Map<String, String>.from(baseEnv)
      ..remove('GIT_DIR')
      ..remove('GIT_WORK_TREE')
      ..remove('GIT_INDEX_FILE')
      ..remove('GIT_COMMON_DIR')
      // 읽기 전용 명령(status)이 인덱스를 다시 쓰지 않게 한다 — 미리보기는 아무것도 바꾸지 않는다.
      ..['GIT_OPTIONAL_LOCKS'] = '0'
      ..['GIT_TERMINAL_PROMPT'] = '0';
    final git = Git._(exe, env);

    final r = await git.run(['--version']);
    final match = RegExp(r'(\d+)\.(\d+)(?:\.(\d+))?').firstMatch(r.stdoutText);
    if (r.exitCode != 0 || match == null) throw ShelveError('err.git_missing');
    final major = int.parse(match.group(1)!);
    final minor = int.parse(match.group(2)!);
    if (major < 2 || (major == 2 && minor < 36)) {
      throw ShelveError('err.git_too_old', {'version': match.group(0)});
    }
    return git;
  }

  /// 환경 변수를 덧붙인 복사본(연습 저장소의 커밋 날짜·작성자 지정용).
  Git withEnv(Map<String, String> extra) => Git._(executable, {...env, ...extra});

  /// git 실행(실패해도 예외 없이 결과만 돌려준다).
  Future<ProcResult> run(List<String> args, {String? cwd, List<int>? stdinBytes}) {
    final full = cwd == null ? args : ['-C', cwd, ...args];
    return runProcess(executable, full, env: env, stdinBytes: stdinBytes);
  }

  /// git 실행 후 stdout 문자열. 실패하면 [ShelveError].
  Future<String> text(List<String> args, {String? cwd}) async {
    final r = await run(args, cwd: cwd);
    if (r.exitCode != 0) {
      throw ShelveError('err.git_failed', {'cmd': args.first, 'why': r.firstErrorLine});
    }
    return r.stdoutText;
  }
}

/// tar 실행 도우미(BSD·GNU 공통 옵션만 쓴다: -c -f -t -x -C --null -T -).
class Tar {
  Tar._(this.executable, this.env);

  final String executable;
  final Map<String, String> env;

  static Tar locate(Map<String, String> baseEnv) {
    final exe = findExecutable('tar', baseEnv);
    if (exe == null) throw ShelveError('err.tool_missing', {'tool': 'tar'});
    // macOS tar 가 ._ 파일(확장 속성)을 끼워 넣지 않게 한다.
    final env = Map<String, String>.from(baseEnv)..['COPYFILE_DISABLE'] = '1';
    return Tar._(exe, env);
  }

  /// [cwd] 기준 상대 경로 [paths] 를 [archive] 로 묶는다.
  Future<ProcResult> create(String archive, String cwd, List<String> paths) {
    final list = <int>[];
    for (final p in paths) {
      list
        ..addAll(utf8.encode(p))
        ..add(0);
    }
    return runProcess(executable, ['-c', '-f', archive, '--null', '-T', '-'],
        env: env, cwd: cwd, stdinBytes: list);
  }

  /// 묶음 안의 항목 이름(폴더 항목 제외).
  Future<List<String>?> list(String archive) async {
    final r = await runProcess(executable, ['-t', '-f', archive], env: env);
    if (r.exitCode != 0) return null;
    return r.stdoutText.split('\n').where((l) => l.isNotEmpty && !l.endsWith('/')).toList();
  }

  Future<ProcResult> extract(String archive, String dest) =>
      runProcess(executable, ['-x', '-f', archive, '-C', dest], env: env);
}
