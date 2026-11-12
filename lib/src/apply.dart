/// `--apply`: 판정대로 실행한다. 순서는 항상 백업 → 검증 → (필요하면 커밋 고정) → 제거.
///
/// 한 워크트리가 실패해도 다른 워크트리는 계속 처리한다(항목별 실패 격리). 최종 종료 코드는 1.
/// 실패는 두 갈래다.
///   - git 을 부르기 전 실패(백업·검증·권한 확인 등): 아무것도 지우지 않았다. 워크트리는 그대로.
///   - `git worktree remove` 실패: git 이 일부를 지웠을 수 있다. 백업을 남기고 백업 ID·복원 명령을 알린다
///     (git 이 기록까지 지웠으면 'fail.remove_partial').
library;

import 'dart:io';

import 'activity.dart';
import 'backup.dart';
import 'errors.dart';
import 'git.dart';
import 'log.dart';
import 'porcelain.dart';
import 'verdict.dart';

class ApplyContext {
  ApplyContext({
    required this.git,
    required this.tar,
    required this.removal,
    required this.backupRoot,
    required this.toolVersion,
    required this.now,
    required this.restoreCommand,
    required this.describeError,
    required this.describeReason,
    this.newPathPlaceholder = 'NEW_PATH',
    this.log,
    this.beforeVerify,
    this.beforeRemove,
  });

  final Git git;
  final Tar tar;

  /// 지우기 전 "끝까지 지울 수 있는가" 확인.
  final RemovalCheck removal;
  final String backupRoot;
  final String toolVersion;
  final DateTime now;

  /// 백업 ID → 사용자에게 보여 줄 복원 명령.
  final String Function(String id) restoreCommand;

  /// `--to` 뒤에 붙일 "새 경로" 자리 표시(화면 언어). git 이 도중에 실패해 원래 자리가 막혔을 때 쓴다.
  final String newPathPlaceholder;

  /// 실패 이유를 화면 언어 문장으로 바꾼다(로그에 남길 때).
  final String Function(ShelveError e) describeError;

  /// 판정 이유를 화면 언어 문장으로 바꾼다(로그에 남길 때).
  final String Function(Assessment a) describeReason;
  final ActionLog? log;

  /// 테스트용: 묶음을 다 쓴 뒤 검증 직전에 불린다(검증 실패 재현).
  final void Function(String stagingDir)? beforeVerify;

  /// 테스트용: 마지막 확인이 끝난 뒤 `git worktree remove` 직전에 불린다(제거 도중 실패 재현).
  final void Function(String worktreePath)? beforeRemove;
}

/// 판정이 keep 이 아닌 항목을 차례로 실행한다.
Future<void> applyAll(List<Assessment> items, ApplyContext c) async {
  for (final a in items) {
    if (!a.acts) {
      // 오래됐지만 백업이 다 담지 못해 일부러 건너뛴 워크트리는 로그에 "skip" 으로 남긴다
      // (cron 으로 돌릴 때 "왜 안 지워졌나"를 나중에 알 수 있게). 다른 보존 항목은 남기지 않는다.
      if (backupBlindSpotReasons.contains(a.reason)) _log(c, a, 'skip', 'skipped');
      continue;
    }
    try {
      await _applyOne(a, c);
      a.result = 'ok';
    } on ShelveError catch (e) {
      a.result = 'failed';
      a.failure = e;
    }
    _log(c, a, a.verdict.name, a.result);
  }
}

void _log(ApplyContext c, Assessment a, String action, String? result) {
  c.log?.append({
    'time': DateTime.now().toUtc().toIso8601String(),
    'action': action,
    'repo': a.repo,
    'path': a.path,
    'branch': a.record.shortBranch,
    'head': a.record.head,
    'reason': a.reason,
    'reason_text': c.describeReason(a),
    'result': result,
    'backup_id': a.backupId,
    'pinned_ref': a.pinnedRef,
    'restore_command': a.restoreCommand,
    'error': a.failure == null ? null : c.describeError(a.failure!),
  });
}

Future<void> _applyOne(Assessment a, ApplyContext c) async {
  final git = c.git;
  final rec = a.record;

  // 분리(detached) HEAD 의 커밋이 어떤 브랜치·태그에도 없으면, 지운 뒤 gc 로 사라질 수 있다.
  // 그래서 제거 전에 refs/worktree-shelve/<id> 참조로 고정한다.
  final needsPin = rec.detached && !(await _reachable(git, a.repo, rec.head));

  if (a.verdict == Verdict.prune) {
    final id = newBackupId(c.backupRoot, a.path, c.now);
    if (needsPin) await _pin(git, a, 'refs/worktree-shelve/$id');
    // 폴더가 없는 워크트리는 `git worktree remove` 가 관리 기록만 지운다(이 항목만, 다른 항목은 그대로).
    final r = await git.run(['worktree', 'remove', rec.path], cwd: a.repo);
    if (r.exitCode != 0) throw ShelveError('fail.remove', {'why': r.firstErrorLine}, 1);
    return;
  }

  // 백업하기 전에: 끝까지 지울 수 없는 폴더(읽기 전용·다른 사용자 소유)가 있으면 손대지 않는다.
  // git 은 그런 폴더에서 멈추면서 관리 기록을 지워 버리므로, 시작하지 않는 것이 유일하게 안전한 길이다.
  await _ensureRemovable(c, a);

  // remove(깨끗함)·shelve(변경 있음) 둘 다 먼저 백업한다 — 깨끗해도 무시된 .env 가 지워지기 때문.
  final id = newBackupId(c.backupRoot, a.path, c.now);
  final ref = needsPin ? 'refs/worktree-shelve/$id' : null;
  await createBackup(
    git: git,
    tar: c.tar,
    a: a,
    backupRoot: c.backupRoot,
    id: id,
    toolVersion: c.toolVersion,
    now: c.now,
    pinnedRef: ref,
    beforeVerify: c.beforeVerify,
  );

  // 지우기 직전에 한 번 더: 스캔 뒤(백업하는 동안 포함)에 서브모듈·안쪽 저장소·진행 중인 merge 등
  // "백업이 다 담지 못하는 것"이 생겼으면 멈춘다(무시 폴더 안처럼 git status 에 안 보이는 곳까지).
  // 이 확인이 --force 앞을 지키는 마지막 관문이다. 확인 자체가 실패해도 지우지 않는다.
  // 멈출 때는 아무것도 지우지 않았으니 방금 만든 백업도 치운다(쓰지 않는 백업이 남지 않게).
  ShelveError? stop;
  try {
    final tree = measureTree(a.path);
    if (tree.unreadable > 0) throw ShelveError('fail.changed', const {}, 1);
    final blind = await findBackupBlindSpot(git, a, tree);
    if (blind != null) {
      // 이유 문구를 그대로 끼워 넣는다(출력할 때 고른 언어로 풀린다).
      stop = ShelveError('fail.blind_spot', {'why': ShelveError('reason.${blind.reason}', blind.params)}, 1);
    } else {
      // 백업하는 동안 권한이 바뀌었을 수도 있으니 지울 수 있는지도 한 번 더 본다.
      await _ensureRemovable(c, a);
    }
  } on ShelveError catch (e) {
    stop = e;
  } on FileSystemException catch (e) {
    stop = ShelveError('err.fs', {'path': a.path, 'why': e.osError?.message ?? e.message}, 1);
  }
  if (stop != null) {
    _discard('${c.backupRoot}/$id');
    throw stop;
  }
  a.backupId = id;
  a.restoreCommand = c.restoreCommand(id);
  if (ref != null) await _pin(git, a, ref);
  c.beforeRemove?.call(a.path);

  // shelve 는 변경이 있으니 --force 한 번(잠긴 워크트리는 git 이 거부한다 — -f -f 는 쓰지 않는다).
  // --force 는 "변경 있음"과 "서브모듈 있음" 두 거부를 함께 넘는다. 변경은 위에서 백업·검증했고,
  // 서브모듈·안쪽 저장소·진행 중인 작업은 판정(has_submodules·nested_repo·git_in_progress)과
  // 바로 위 확인이 막았다.
  // remove 는 --force 없이: 그 사이 새 파일이 생겼으면 git 이 거부해 안전하다.
  final r = await git.run(
      ['worktree', 'remove', if (a.verdict == Verdict.shelve) '--force', rec.path], cwd: a.repo);
  if (r.exitCode == 0 && !Directory(a.path).existsSync()) return;

  // 여기부터는 git 이 실패했다. git 은 폴더를 지우다 멈춰도 관리 기록(.git/worktrees/<id>)은 지운다
  // — 그러면 폴더 일부만 남고 `worktree list` 에서도 사라져 다음 scan 이 찾지 못한다.
  // 그래서 "그대로 남겼다"고 가정하지 않고, git 이 아직 이 워크트리를 아는지 직접 확인해 사실대로 알린다.
  // 검증된 백업은 어느 경우든 지우지 않는다(파일이 지워졌을 수 있으니 되살릴 수단을 남긴다).
  final why = r.exitCode != 0 ? r.firstErrorLine : 'folder still exists';
  // 원래 자리에는 (남은) 폴더가 있어 그대로 되살릴 수 없다 — 복원 명령에 --to 를 붙여 둔다(화면·로그·JSON 공통).
  a.restoreCommand = '${c.restoreCommand(id)} --to ${c.newPathPlaceholder}';
  if (await _stillListed(git, a)) {
    throw ShelveError('fail.remove', {'why': why}, 1);
  }
  throw ShelveError('fail.remove_partial', {'why': why}, 1);
}

/// git 이 아직 이 워크트리를 기록에 갖고 있으면 true. 확인 자체가 실패하면 "모름" — 더 나쁜 쪽(기록 없음)으로 본다.
Future<bool> _stillListed(Git git, Assessment a) async {
  final r = await git.run(['worktree', 'list', '--porcelain', '-z'], cwd: a.repo);
  if (r.exitCode != 0) return false;
  return parsePorcelainZ(r.stdoutText)
      .any((w) => w.path == a.record.path || canonicalPath(w.path) == a.path);
}

/// "이 워크트리를 끝까지 지울 수 있는가"를 지우기 전에 확인한다(읽기 전용 폴더 때문에 반쯤 지워지는 일을 막는다).
///
/// 폴더 안의 항목을 지우려면 그 폴더에 쓰기(w)·통과(x) 권한이 있어야 하고,
/// 워크트리 폴더 자체를 지우려면 부모 폴더에도 같은 권한이 있어야 한다.
/// dart:io 는 파일 소유자를 알려 주지 않으므로 POSIX `find` 로 본다(macOS·Linux 공통 옵션만).
///   - 워크트리 안: 내 것이 아니거나(-user) 소유자 w·x 비트가 없는(-perm -0300) 폴더 → 막힘.
///     (예: chmod 555 한 캐시 폴더, 컨테이너가 root 로 만든 폴더)
///   - 부모 폴더: 내 것이면서 소유자 w·x 가 있거나, 누구나 쓸 수 있으면(/tmp 같은 곳) 통과.
/// 그룹 쓰기 권한만으로 쓸 수 있는 폴더도 "막힘"으로 본다 — 확실하지 않으면 지우지 않는 쪽.
/// root 로 실행하면 권한과 상관없이 지울 수 있으므로 확인하지 않는다.
class RemovalCheck {
  RemovalCheck._(this.find, this.uid, this.env);

  final String find;
  final String uid;
  final Map<String, String> env;

  /// PATH 에서 find·id 를 찾고 현재 사용자 번호를 읽는다. 없으면 [ShelveError](종료 코드 2).
  static Future<RemovalCheck> locate(Map<String, String> env) async {
    final find = findExecutable('find', env);
    if (find == null) throw ShelveError('err.tool_missing', {'tool': 'find'});
    final id = findExecutable('id', env);
    if (id == null) throw ShelveError('err.tool_missing', {'tool': 'id'});
    final r = await runProcess(id, ['-u'], env: env);
    final uid = r.stdoutText.trim();
    if (r.exitCode != 0 || int.tryParse(uid) == null) {
      throw ShelveError('err.tool_missing', {'tool': 'id'});
    }
    return RemovalCheck._(find, uid, env);
  }

  /// 지우지 못하게 막는 첫 폴더(절대 경로, 이름순). 다 지울 수 있으면 null.
  /// `find` 가 실패하면(확인할 수 없으면) [ShelveError] — 지우지 않는다.
  Future<String?> firstBlocker(String worktree) async {
    if (uid == '0') return null;

    // 1) 부모 폴더: 조건에 맞으면 경로가 한 줄 나온다. 아무것도 안 나오면 막힘.
    final parent = File(worktree).parent.path;
    final p = await runProcess(
        find,
        [
          parent, '-maxdepth', '0', //
          '(', '(', '-user', uid, '-perm', '-0300', ')', '-o', '-perm', '-0003', ')', '-print',
        ],
        env: env);
    if (p.exitCode != 0) throw ShelveError('err.fs', {'path': parent, 'why': p.firstErrorLine}, 1);
    if (p.stdoutText.trim().isEmpty) return parent;

    // 2) 워크트리 안(맨 위 폴더 포함): 막는 폴더를 찾으면 그 아래로는 더 내려가지 않는다(-prune).
    final w = await runProcess(
        find,
        [
          worktree, '-type', 'd', //
          '(', '!', '-user', uid, '-o', '!', '-perm', '-0300', ')', '-print0', '-prune',
        ],
        env: env);
    if (w.exitCode != 0) throw ShelveError('err.fs', {'path': worktree, 'why': w.firstErrorLine}, 1);
    final found = w.stdoutText.split('\x00').where((s) => s.isNotEmpty).toList()..sort();
    return found.isEmpty ? null : found.first;
  }
}

/// 지우지 못하게 막는 폴더가 있으면 'fail.not_removable' 로 멈춘다(아무것도 지우지 않은 상태).
Future<void> _ensureRemovable(ApplyContext c, Assessment a) async {
  final blocker = await c.removal.firstBlocker(a.path);
  if (blocker != null) throw ShelveError('fail.not_removable', {'path': blocker}, 1);
}

/// 커밋이 브랜치·태그·원격 브랜치 중 하나에서 닿으면 true.
Future<bool> _reachable(Git git, String repo, String sha) async {
  final r = await git.run([
    'for-each-ref',
    '--count=1',
    '--contains',
    sha,
    '--format=%(refname)',
    'refs/heads',
    'refs/tags',
    'refs/remotes',
  ], cwd: repo);
  return r.exitCode == 0 && r.stdoutText.trim().isNotEmpty;
}

/// 쓰지 않게 된 백업 폴더를 지운다(실패해도 무시 — 남아 있어도 해롭지 않은 온전한 백업이다).
void _discard(String dir) {
  try {
    Directory(dir).deleteSync(recursive: true);
  } on FileSystemException {
    // 그대로 둔다.
  }
}

Future<void> _pin(Git git, Assessment a, String ref) async {
  final r = await git.run(['update-ref', ref, a.record.head], cwd: a.repo);
  if (r.exitCode != 0) throw ShelveError('fail.pin', {'why': r.firstErrorLine}, 1);
  a.pinnedRef = ref;
}
