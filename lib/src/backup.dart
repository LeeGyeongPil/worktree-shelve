/// 백업 묶음 만들기·검증.
///
/// 백업 폴더 `<backup-dir>/<id>/` 안에 다음을 둔다.
///   manifest.json   저장소·워크트리·브랜치·HEAD·파일 목록(git hash-object 값)
///   changes.patch   `git diff HEAD --binary` — 추적 파일 변경 전체(스테이지 + 미스테이지)
///   staged.patch    `git diff --cached --binary` — 스테이지 상태까지 똑같이 되살리기 위한 것
///   untracked.tar   `git ls-files --others --exclude-standard` 파일들
///   ignored.tar     무시됐지만 산출물이 아닌 파일들(.env, 로컬 설정 …)
///
/// 먼저 `<id>.partial/` 에 쓰고 검증이 끝나야 `<id>/` 로 이름을 바꾼다(원자적 완성).
/// 검증이 하나라도 어긋나면 묶음을 지우고 예외를 던진다 — 그러면 워크트리는 지우지 않는다.
library;

import 'dart:convert';
import 'dart:io';

import 'artifacts.dart';
import 'errors.dart';
import 'git.dart';
import 'verdict.dart';

/// 무시 파일 중 백업할 것(산출물 제외)과 그 합계 크기.
class FileSet {
  FileSet(this.files, this.bytes);
  final List<String> files; // 워크트리 기준 상대 경로
  final int bytes;
}

/// 폴더 항목(`dir/`)을 파일 목록으로 펼친다. 링크는 항목 자체만 넣고 따라가지 않는다.
FileSet _expand(String wt, List<String> entries, {required bool skipArtifacts}) {
  final files = <String>[];
  var bytes = 0;
  for (var entry in entries) {
    if (entry.endsWith('/')) entry = entry.substring(0, entry.length - 1);
    if (entry.isEmpty || (skipArtifacts && isArtifactPath(entry))) continue;
    final full = '$wt/$entry';
    final type = FileSystemEntity.typeSync(full, followLinks: false);
    if (type == FileSystemEntityType.notFound) continue;
    if (type != FileSystemEntityType.directory) {
      files.add(entry);
      if (type == FileSystemEntityType.file) bytes += File(full).lengthSync();
      continue;
    }
    for (final e in Directory(full).listSync(recursive: true, followLinks: false)) {
      if (e is Directory) continue;
      final rel = e.path.substring(wt.length + 1);
      if (skipArtifacts && isArtifactPath(rel)) continue;
      files.add(rel);
      if (e is File) bytes += e.statSync().size;
    }
  }
  files.sort();
  return FileSet(files, bytes);
}

/// `git worktree remove` 가 함께 지워 버리는 "무시된 비산출물" 파일 목록.
Future<FileSet> listIgnoredFiles(Git git, String wt) async {
  final r = await git.run(
      ['ls-files', '--others', '--ignored', '--exclude-standard', '--directory', '-z'], cwd: wt);
  if (r.exitCode != 0) {
    throw ShelveError('err.git_failed', {'cmd': 'ls-files', 'why': r.firstErrorLine});
  }
  final entries = r.stdoutText.split('\x00').where((e) => e.isNotEmpty).toList();
  return _expand(wt, entries, skipArtifacts: true);
}

/// 추적되지 않은(무시되지 않은) 파일 목록.
Future<FileSet> listUntrackedFiles(Git git, String wt) async {
  final r = await git.run(['ls-files', '--others', '--exclude-standard', '-z'], cwd: wt);
  if (r.exitCode != 0) {
    throw ShelveError('err.git_failed', {'cmd': 'ls-files', 'why': r.firstErrorLine});
  }
  final entries = r.stdoutText.split('\x00').where((e) => e.isNotEmpty).toList();
  return _expand(wt, entries, skipArtifacts: false);
}

/// 사용자 설정(외부 diff, 색, 접두어 없음 등)에 흔들리지 않는 패치 옵션.
const _diffFlags = [
  '--binary',
  '--no-ext-diff',
  '--no-color',
  '--no-textconv',
  '--no-renames',
  '--src-prefix=a/',
  '--dst-prefix=b/',
];

/// 항목 실패(종료 코드 1)용 예외.
ShelveError _itemError(String key, [Map<String, Object?> params = const {}]) =>
    ShelveError(key, params, 1);

/// 파일 목록의 git blob 해시(링크는 해시 대신 링크 대상을 적는다).
Future<List<Map<String, Object?>>> _describe(Git git, String wt, List<String> files) async {
  final regular = <String>[];
  final entries = <Map<String, Object?>>[];
  for (final f in files) {
    if (f.contains('\n')) throw _itemError('fail.newline_name');
    final full = '$wt/$f';
    if (FileSystemEntity.isLinkSync(full)) {
      entries.add({'path': f, 'link': Link(full).targetSync()});
    } else {
      regular.add(f);
      entries.add({'path': f, 'size': File(full).lengthSync()});
    }
  }
  if (regular.isNotEmpty) {
    final r = await git.run(['hash-object', '--no-filters', '--stdin-paths'],
        cwd: wt, stdinBytes: utf8.encode('${regular.join('\n')}\n'));
    if (r.exitCode != 0) {
      throw _itemError('fail.backup_write', {'why': r.firstErrorLine});
    }
    final hashes = r.stdoutText.trim().split('\n');
    var i = 0;
    for (final e in entries) {
      if (!e.containsKey('link')) e['hash'] = hashes[i++];
    }
  }
  return entries;
}

/// 새 백업 ID: `20261112-101500-feat-a` 꼴. 이미 있으면 `-2`, `-3` … 을 붙인다.
String newBackupId(String backupRoot, String worktreePath, DateTime now) {
  String two(int n) => n.toString().padLeft(2, '0');
  final stamp = '${now.year}${two(now.month)}${two(now.day)}-'
      '${two(now.hour)}${two(now.minute)}${two(now.second)}';
  final base = worktreePath.substring(worktreePath.lastIndexOf('/') + 1);
  final safe = base.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
  var id = '$stamp-${safe.isEmpty ? 'worktree' : safe}';
  var n = 2;
  while (FileSystemEntity.typeSync('$backupRoot/$id', followLinks: false) !=
          FileSystemEntityType.notFound ||
      FileSystemEntity.typeSync('$backupRoot/$id.partial', followLinks: false) !=
          FileSystemEntityType.notFound) {
    id = '$stamp-${safe.isEmpty ? 'worktree' : safe}-${n++}';
  }
  return id;
}

/// 백업 ID 형식 검사(경로 조작 방지: 슬래시·점점 금지).
bool isValidBackupId(String id) => RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]*$').hasMatch(id);

/// 이 도구가 만든 ID 꼴(`20261112-101500-name`)인지. 정리·삭제는 이 꼴만 대상으로 한다.
bool isGeneratedBackupId(String id) =>
    isValidBackupId(id) && RegExp(r'^\d{8}-\d{6}-[A-Za-z0-9_-]+$').hasMatch(id);

/// 백업을 만들고 검증한다. 성공하면 manifest 를 돌려준다.
Future<Map<String, Object?>> createBackup({
  required Git git,
  required Tar tar,
  required Assessment a,
  required String backupRoot,
  required String id,
  required String toolVersion,
  required DateTime now,
  String? pinnedRef,
  void Function(String stagingDir)? beforeVerify,
}) async {
  final staging = Directory('$backupRoot/$id.partial');
  final finalDir = '$backupRoot/$id';
  try {
    staging.createSync();
    final wt = a.path;

    // 1) 지금 상태 스냅숏(검증 때 다시 떠서 비교한다 — 그 사이 누가 고쳤으면 중단).
    final statusBefore = await _statusBytes(git, wt);
    final changes = await _diff(git, wt, ['diff', 'HEAD', ..._diffFlags]);
    final staged = await _diff(git, wt, ['diff', '--cached', ..._diffFlags]);
    final untracked = await listUntrackedFiles(git, wt);
    final ignored = await listIgnoredFiles(git, wt);
    final untrackedInfo = await _describe(git, wt, untracked.files);
    final ignoredInfo = await _describe(git, wt, ignored.files);

    // 2) 묶음 파일 쓰기.
    File('${staging.path}/changes.patch').writeAsBytesSync(changes, flush: true);
    File('${staging.path}/staged.patch').writeAsBytesSync(staged, flush: true);
    for (final (name, set) in [('untracked.tar', untracked), ('ignored.tar', ignored)]) {
      if (set.files.isEmpty) continue;
      final r = await tar.create('${staging.path}/$name', wt, set.files);
      if (r.exitCode != 0) {
        throw _itemError('fail.backup_write', {'why': 'tar: ${r.firstErrorLine}'});
      }
    }
    final commonDir = (await git.text(
            ['rev-parse', '--path-format=absolute', '--git-common-dir'], cwd: a.repo))
        .trim();
    final manifest = <String, Object?>{
      'format': 1,
      'tool': 'worktree-shelve',
      'tool_version': toolVersion,
      'id': id,
      'created_at': now.toUtc().toIso8601String(),
      'repo': a.repo,
      'common_git_dir': commonDir,
      'worktree': wt,
      'branch': a.record.branch,
      'head': a.record.head,
      'detached': a.record.detached,
      'pinned_ref': pinnedRef,
      'verdict': a.verdict.name,
      'reason': a.reason,
      'changes_patch_bytes': changes.length,
      'staged_patch_bytes': staged.length,
      'untracked': untrackedInfo,
      'ignored': ignoredInfo,
    };
    File('${staging.path}/manifest.json')
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(manifest), flush: true);

    beforeVerify?.call(staging.path);

    // 3) 검증: 묶음을 다시 읽어 개수·크기를 대조하고, 워크트리가 그 사이 바뀌지 않았는지 본다.
    await _verify(tar, staging.path, manifest, untracked.files.length, ignored.files.length);
    final statusAfter = await _statusBytes(git, wt);
    final changesAfter = await _diff(git, wt, ['diff', 'HEAD', ..._diffFlags]);
    if (!_sameBytes(statusBefore, statusAfter) || !_sameBytes(changes, changesAfter)) {
      throw _itemError('fail.changed');
    }

    // 4) 완성: .partial → 최종 이름.
    staging.renameSync(finalDir);
    return manifest;
  } on FileSystemException catch (e) {
    _cleanup(staging);
    throw _itemError('fail.backup_write', {'why': e.osError?.message ?? e.message});
  } catch (_) {
    _cleanup(staging);
    rethrow;
  }
}

Future<void> _verify(Tar tar, String dir, Map<String, Object?> manifest, int untrackedCount,
    int ignoredCount) async {
  for (final (name, expected) in [('untracked.tar', untrackedCount), ('ignored.tar', ignoredCount)]) {
    final f = File('$dir/$name');
    if (expected == 0) continue;
    if (!f.existsSync()) throw _itemError('fail.verify', {'what': '$name missing'});
    final listed = await tar.list(f.path);
    if (listed == null || listed.length != expected) {
      throw _itemError('fail.verify', {'what': '$name: ${listed?.length ?? 0}/$expected'});
    }
  }
  for (final (name, key) in [
    ('changes.patch', 'changes_patch_bytes'),
    ('staged.patch', 'staged_patch_bytes')
  ]) {
    final f = File('$dir/$name');
    final want = manifest[key] as int;
    final got = f.existsSync() ? f.lengthSync() : -1;
    if (got != want) throw _itemError('fail.verify', {'what': '$name: $got/$want bytes'});
  }
  try {
    final back = jsonDecode(File('$dir/manifest.json').readAsStringSync()) as Map<String, Object?>;
    if (back['id'] != manifest['id']) throw const FormatException('id');
  } on FormatException {
    throw _itemError('fail.verify', {'what': 'manifest.json'});
  }
}

Future<List<int>> _statusBytes(Git git, String wt) async {
  final r = await git.run(['status', '--porcelain=v1', '-z', '--untracked-files=all'], cwd: wt);
  if (r.exitCode != 0) throw _itemError('fail.backup_write', {'why': r.firstErrorLine});
  return r.stdoutBytes;
}

Future<List<int>> _diff(Git git, String wt, List<String> args) async {
  final r = await git.run(args, cwd: wt);
  if (r.exitCode != 0) throw _itemError('fail.backup_write', {'why': r.firstErrorLine});
  return r.stdoutBytes;
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

void _cleanup(Directory d) {
  try {
    if (d.existsSync()) d.deleteSync(recursive: true);
  } on FileSystemException {
    // 정리 실패는 무시한다(다음 실행의 .partial 은 목록에 나오지 않는다).
  }
}
