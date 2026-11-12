/// `restore <id>`: 백업 묶음으로 워크트리를 다시 만든다.
///
/// 순서: 사전 점검 → `git worktree add`(같은 브랜치 또는 분리된 커밋) → changes.patch 적용
///       → staged.patch 를 인덱스에만 적용 → untracked.tar·ignored.tar 풀기 → 해시 대조.
/// 결과적으로 `git status` 가 제거 전과 같아지고 미추적·무시 파일 바이트가 같아진다.
library;

import 'dart:convert';
import 'dart:io';

import 'backup.dart';
import 'errors.dart';
import 'git.dart';
import 'porcelain.dart';
import 'verdict.dart' show canonicalPath;

class RestoreOutcome {
  RestoreOutcome({
    required this.path,
    required this.branch,
    required this.detachedBecauseMoved,
    required this.head,
    required this.patchApplied,
    required this.untracked,
    required this.ignored,
  });

  final String path;
  final String? branch;
  final bool detachedBecauseMoved;
  final String head;
  final bool patchApplied;
  final int untracked;
  final int ignored;
}

/// 백업 폴더에서 manifest 를 읽는다(없거나 망가졌으면 한 줄 오류).
Map<String, Object?> readManifest(String backupRoot, String id) {
  if (!isValidBackupId(id)) throw ShelveError('err.backup_bad_id', {'id': id});
  final dir = '$backupRoot/$id';
  final file = File('$dir/manifest.json');
  if (!file.existsSync()) throw ShelveError('err.backup_not_found', {'id': id, 'dir': backupRoot});
  try {
    final data = jsonDecode(file.readAsStringSync());
    if (data is! Map<String, Object?> || data['head'] is! String || data['repo'] is! String) {
      throw const FormatException('fields');
    }
    return data;
  } on FormatException {
    throw ShelveError('err.backup_damaged', {'id': id, 'why': 'manifest.json', 'dir': dir});
  }
}

Future<RestoreOutcome> restoreBackup({
  required Git git,
  required Tar tar,
  required String backupRoot,
  required String id,
  required String? to,
}) async {
  final m = readManifest(backupRoot, id);
  final dir = '$backupRoot/$id';
  final repo = m['repo'] as String;
  final head = m['head'] as String;
  final branchRef = m['branch'] as String?;
  final target = canonicalPath(to ?? (m['worktree'] as String));

  // 사전 점검: 저장소가 있고, 되살릴 자리가 비어 있어야 한다.
  if (!Directory(repo).existsSync()) throw ShelveError('err.restore_repo_missing', {'path': repo});
  if (FileSystemEntity.typeSync(target, followLinks: false) != FileSystemEntityType.notFound) {
    throw ShelveError('err.restore_target_exists', {'path': target});
  }

  // why 는 git 이 준 한 줄 또는 번역할 ShelveError.
  Never stop(String step, Object why) => throw ShelveError(
      'err.restore_failed', {'id': id, 'step': step, 'why': why, 'path': target});

  // 1) 워크트리 다시 만들기.
  var moved = false;
  List<String> addArgs;
  final short = branchRef?.startsWith('refs/heads/') == true ? branchRef!.substring(11) : null;
  if (short == null) {
    addArgs = ['worktree', 'add', '--detach', target, head];
  } else {
    final tip = await git.run(['rev-parse', '-q', '--verify', 'refs/heads/$short^{commit}'], cwd: repo);
    if (tip.exitCode != 0) {
      // 브랜치가 지워졌으면 백업 당시 커밋에서 새로 만든다.
      addArgs = ['worktree', 'add', '-b', short, target, head];
    } else if (tip.stdoutText.trim() != head) {
      // 브랜치가 그 뒤로 움직였으면 패치가 맞지 않을 수 있어, 백업 당시 커밋에 분리 상태로 되살린다.
      moved = true;
      addArgs = ['worktree', 'add', '--detach', target, head];
    } else {
      final list = parsePorcelainZ(
          await git.text(['worktree', 'list', '--porcelain', '-z'], cwd: repo));
      for (final w in list) {
        if (w.branch == 'refs/heads/$short' && !w.prunable) {
          throw ShelveError('err.restore_branch_busy', {'branch': short, 'path': w.path});
        }
      }
      addArgs = ['worktree', 'add', target, short];
    }
  }
  final add = await git.run(addArgs, cwd: repo);
  if (add.exitCode != 0) stop('restore.step.add', add.firstErrorLine);

  // 2) 추적 파일 변경: 작업 트리에 전체 변경, 인덱스에는 스테이지된 변경만.
  final changes = File('$dir/changes.patch');
  final staged = File('$dir/staged.patch');
  final patchApplied = changes.existsSync() && changes.lengthSync() > 0;
  if (patchApplied) {
    final r = await git.run(['apply', '--binary', '--whitespace=nowarn', changes.path], cwd: target);
    if (r.exitCode != 0) stop('restore.step.patch', r.firstErrorLine);
  }
  if (staged.existsSync() && staged.lengthSync() > 0) {
    final r = await git.run(
        ['apply', '--cached', '--binary', '--whitespace=nowarn', staged.path], cwd: target);
    if (r.exitCode != 0) stop('restore.step.staged', r.firstErrorLine);
  }

  // 3) 미추적·무시 파일 풀기.
  for (final (name, step) in [
    ('untracked.tar', 'restore.step.untracked'),
    ('ignored.tar', 'restore.step.ignored')
  ]) {
    final f = File('$dir/$name');
    if (!f.existsSync()) continue;
    final r = await tar.extract(f.path, target);
    if (r.exitCode != 0) stop(step, r.firstErrorLine);
  }

  // 4) 해시 대조: 풀린 파일이 백업할 때와 같은 바이트인지.
  final entries = [
    ...((m['untracked'] as List<Object?>?) ?? const []),
    ...((m['ignored'] as List<Object?>?) ?? const []),
  ].whereType<Map<String, Object?>>().where((e) => e['hash'] is String).toList();
  if (entries.isNotEmpty) {
    final paths = entries.map((e) => e['path'] as String).toList();
    final r = await git.run(['hash-object', '--no-filters', '--stdin-paths'],
        cwd: target, stdinBytes: utf8.encode('${paths.join('\n')}\n'));
    if (r.exitCode != 0) stop('restore.step.check', r.firstErrorLine);
    final got = r.stdoutText.trim().split('\n');
    var bad = 0;
    for (var i = 0; i < entries.length; i++) {
      if (i >= got.length || got[i] != entries[i]['hash']) bad++;
    }
    if (bad > 0) stop('restore.step.check', ShelveError('restore.check_bad', {'n': bad}));
  }

  return RestoreOutcome(
    path: target,
    branch: short,
    detachedBecauseMoved: moved,
    head: head,
    patchApplied: patchApplied,
    untracked: ((m['untracked'] as List<Object?>?) ?? const []).length,
    ignored: ((m['ignored'] as List<Object?>?) ?? const []).length,
  );
}
