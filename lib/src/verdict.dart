/// 판정: 워크트리마다 keep·remove·shelve·prune 중 하나와 이유 코드를 정한다.
///
/// 규칙은 위에서부터 먼저 걸리는 것이 이긴다. 순서 자체가 "보존 쪽으로 기울게" 짜여 있다.
///   main → locked → cwd → outside_root → mounted → recent_commit
///   → (폴더 없음) has_submodules / missing_dir(prune) → gitdir_missing → recent_edit
///   → has_submodules → nested_repo → git_in_progress → ignored_too_large
///   → stale_clean(remove) / stale_dirty(shelve)
///
/// has_submodules·nested_repo·git_in_progress 는 "백업이 다 담지 못하는" 워크트리다.
/// `git diff` 는 서브모듈을 커밋 한 줄로만 적고, `ls-files --others` 는 서브모듈·안쪽 저장소 속으로
/// 들어가지 않으며, 진행 중인 merge·rebase 상태는 패치로 표현되지 않는다.
/// 그런데 `git worktree remove --force` 는 그 모두를 지운다.
/// 그래서 오래됐어도 손대지 않는다(보수적 판정 — 한 번 지우면 되돌릴 수 없다).
library;

import 'dart:io';

import 'activity.dart';
import 'backup.dart' show listIgnoredFiles;
import 'errors.dart';
import 'git.dart';
import 'mounts.dart';
import 'porcelain.dart';

enum Verdict { keep, remove, shelve, prune }

/// 오래됐지만 백업이 다 담지 못해 일부러 건너뛴 이유 코드(--apply 로그에 "skip" 으로 남긴다).
const backupBlindSpotReasons = {'has_submodules', 'nested_repo', 'git_in_progress'};

/// 워크트리 하나에 대한 조사 결과와 (--apply 뒤) 실행 결과.
class Assessment {
  Assessment({required this.repo, required this.record, required this.path});

  /// 메인 저장소 폴더(절대 경로).
  final String repo;
  final WorktreeRecord record;

  /// 워크트리 폴더(가능하면 심볼릭 링크를 푼 절대 경로).
  final String path;

  Verdict verdict = Verdict.keep;
  String reason = 'main';

  /// 이유 문구에 들어갈 값(잠금 사유, 나이, 바뀐 파일 수 …).
  Map<String, Object?> reasonParams = {};

  int? sizeBytes;
  DateTime? lastCommit;
  DateTime? newestEdit;
  int changedFiles = 0;
  int ignoredBytes = 0;

  // --apply 결과
  String? result; // ok | failed
  String? backupId;
  String? pinnedRef;
  String? restoreCommand;

  /// 실패 이유(문장은 출력할 때 고른 언어로 만든다).
  ShelveError? failure;

  bool get acts => verdict != Verdict.keep;
}

class ScanOptions {
  ScanOptions({
    required this.root,
    required this.cwd,
    required this.days,
    required this.ignoredCapBytes,
    required this.mountPoints,
    required this.now,
  });

  final String root;
  final String cwd;
  final int days;
  final int ignoredCapBytes;
  final List<String> mountPoints;
  final DateTime now;

  DateTime get cutoff => now.subtract(Duration(days: days));
}

/// 경로를 비교할 수 있게 심볼릭 링크를 푼다(macOS 의 /tmp 심볼릭 링크 같은 차이 제거).
/// 폴더가 없으면 부모만 풀어 이름을 붙인다.
String canonicalPath(String p) {
  try {
    return Directory(p).resolveSymbolicLinksSync();
  } on FileSystemException {
    final parent = File(p).parent;
    if (parent.path == p) return p;
    final name = p.substring(p.lastIndexOf('/') + 1);
    return '${canonicalPath(parent.path)}/$name';
  }
}

/// [path] 가 [dir] 와 같거나 그 안쪽이면 true.
bool isInside(String path, String dir) {
  if (dir == '/') return true;
  final d = dir.endsWith('/') ? dir.substring(0, dir.length - 1) : dir;
  return path == d || path.startsWith('$d/');
}

/// 저장소 하나의 모든 워크트리를 판정한다.
Future<List<Assessment>> assessRepo(Git git, String repo, ScanOptions opt) async {
  final listing = await git.text(['worktree', 'list', '--porcelain', '-z'], cwd: repo);
  final records = parsePorcelainZ(listing);
  final out = <Assessment>[];
  for (var i = 0; i < records.length; i++) {
    final rec = records[i];
    final a = Assessment(repo: repo, record: rec, path: canonicalPath(rec.path));
    out.add(a);
    try {
      await _judge(git, a, opt, isMain: i == 0 || rec.bare);
    } on ShelveError catch (e) {
      _keep(a, 'scan_error', {'why': e.params['why'] ?? e.key});
    } on FileSystemException catch (e) {
      _keep(a, 'scan_error', {'why': e.osError?.message ?? e.message});
    }
  }
  // git 은 .git/worktrees 를 readdir 순서로 나열하므로 OS 마다 다르다.
  // 메인 워크트리를 먼저, 나머지는 경로순으로 정렬해 출력 순서를 고정한다.
  final main = out.isEmpty ? <Assessment>[] : [out.first];
  final rest = out.skip(1).toList()..sort((x, y) => x.path.compareTo(y.path));
  return [...main, ...rest];
}

void _keep(Assessment a, String reason, [Map<String, Object?> params = const {}]) {
  a.verdict = Verdict.keep;
  a.reason = reason;
  a.reasonParams = params;
}

Future<void> _judge(Git git, Assessment a, ScanOptions opt, {required bool isMain}) async {
  final rec = a.record;
  // 1) 메인 워크트리는 git 도 지울 수 없고, 우리도 건드리지 않는다.
  if (isMain) return _keep(a, 'main');
  // 2) 잠금은 "사용 중" 표시 — 사유를 보여 주고 보존한다(-f -f 를 쓰지 않는다).
  if (rec.locked) return _keep(a, 'locked', {'why': rec.lockReason});
  // 3) 지금 이 명령을 실행한 위치가 그 안이면 보존.
  if (isInside(opt.cwd, a.path)) return _keep(a, 'cwd');
  // 4) --root 밖은 사용자가 고른 범위가 아니므로 보존.
  if (!isInside(a.path, opt.root)) return _keep(a, 'outside_root');
  // 5) 안에 다른 디스크가 붙어 있으면 보존.
  final mp = mountInside(a.path, opt.mountPoints) ?? mountInside(rec.path, opt.mountPoints);
  if (mp != null) return _keep(a, 'mounted', {'path': mp});

  // 6) 마지막 커밋 시각(폴더가 없어도 메인 저장소에서 읽을 수 있다).
  final ct = (await git.text(['show', '-s', '--format=%ct', rec.head], cwd: a.repo)).trim();
  a.lastCommit = DateTime.fromMillisecondsSinceEpoch(int.parse(ct) * 1000);
  final exists = Directory(a.path).existsSync();
  if (a.lastCommit!.isAfter(opt.cutoff)) {
    return _keep(a, 'recent_commit', {'age': opt.now.difference(a.lastCommit!)});
  }

  // 7) 폴더가 사라졌으면 관리 기록만 정리(prune). 지울 파일이 없다.
  //    단, 관리 폴더에 서브모듈 저장소(modules/)가 남아 있으면 push 안 한 서브모듈 커밋이
  //    거기에만 있을 수 있다 — 기록을 지우면 함께 사라지므로 보존한다.
  if (!exists) {
    final store = submoduleStore(await worktreeAdminDir(git, a));
    if (store != null) return _keep(a, 'has_submodules', {'path': store});
    a.verdict = Verdict.prune;
    a.reason = 'missing_dir';
    a.sizeBytes = 0;
    return;
  }
  // 폴더는 있는데 .git 연결 파일이 없으면 더 이상 워크트리가 아니다 — 손대지 않는다.
  if (FileSystemEntity.typeSync('${a.path}/.git', followLinks: false) ==
      FileSystemEntityType.notFound) {
    return _keep(a, 'gitdir_missing');
  }

  // 8) 파일 수정 시각(산출물·.git·링크 제외)과 크기.
  final activity = measureTree(a.path);
  a.sizeBytes = activity.sizeBytes;
  a.newestEdit = activity.newestEdit;
  if (activity.unreadable > 0) {
    return _keep(a, 'scan_error', {'why': 'unreadable folders: ${activity.unreadable}'});
  }
  if (a.newestEdit != null && a.newestEdit!.isAfter(opt.cutoff)) {
    // 미래 시각(시계 차이)도 여기서 "최근"으로 걸린다 — 보존 쪽.
    final age = opt.now.difference(a.newestEdit!);
    return _keep(a, 'recent_edit', {'age': age.isNegative ? Duration.zero : age});
  }

  // 9) 오래됐어도 백업이 다 담지 못하는 것이 있으면 보존 — 이런 워크트리는 --force 로 지울 일이 없다.
  final blind = await findBackupBlindSpot(git, a, activity);
  if (blind != null) return _keep(a, blind.reason, blind.params);

  // 10) 여기까지 왔으면 커밋도 파일도 오래됨. 변경 여부와 무시 파일 크기를 본다.
  final status = await git.run(
      ['status', '--porcelain=v1', '-z', '--untracked-files=all'], cwd: a.path);
  if (status.exitCode != 0) {
    throw ShelveError('err.git_failed', {'cmd': 'status', 'why': status.firstErrorLine});
  }
  a.changedFiles = countStatusEntries(status.stdoutText);
  final ignored = await listIgnoredFiles(git, a.path);
  a.ignoredBytes = ignored.bytes;
  final idle = opt.now.difference(
      [a.lastCommit!, if (a.newestEdit != null) a.newestEdit!].reduce((x, y) => x.isAfter(y) ? x : y));

  if (a.ignoredBytes > opt.ignoredCapBytes) {
    return _keep(a, 'ignored_too_large', {'size': a.ignoredBytes, 'cap': opt.ignoredCapBytes});
  }
  if (a.changedFiles == 0) {
    a.verdict = Verdict.remove;
    a.reason = 'stale_clean';
    a.reasonParams = {'age': idle};
  } else {
    a.verdict = Verdict.shelve;
    a.reason = 'stale_dirty';
    a.reasonParams = {'age': idle, 'n': a.changedFiles};
  }
}

/// `status --porcelain=v1 -z` 항목 수. 이름 바꾸기·복사(R·C)는 원래 이름 필드가 하나 더 붙는다.
int countStatusEntries(String z) {
  final fields = z.split('\x00');
  var count = 0;
  for (var i = 0; i < fields.length; i++) {
    final f = fields[i];
    if (f.length < 3) continue;
    count++;
    if (f[0] == 'R' || f[0] == 'C' || f[1] == 'R' || f[1] == 'C') i++;
  }
  return count;
}

/// 백업 묶음(changes.patch·staged.patch·untracked.tar·ignored.tar)이 다 담지 못하는 것.
/// [reason] 은 판정 이유 코드, [params] 는 이유 문구에 들어갈 값.
typedef BlindSpot = ({String reason, Map<String, Object?> params});

/// 워크트리에 "백업이 다 담지 못하는 것"이 있는지 본다. 판정(9단계)과 --apply 의 제거 직전 확인이
/// 같은 함수를 쓴다 — 기준이 한 곳에만 있다. [tree] 는 그 워크트리의 [measureTree] 결과.
///   has_submodules   인덱스의 gitlink(모드 160000, 받아 두지 않은 서브모듈 포함) 또는 관리 폴더의
///                    modules/(서브모듈 커밋 저장소). diff 는 서브모듈을 커밋 한 줄로만 적는다.
///   nested_repo      안쪽 폴더의 `.git`(직접 clone, 산출물 폴더 안 저장소). ls-files 가 들어가지 않는다.
///   git_in_progress  끝나지 않은 merge·rebase·cherry-pick·revert·bisect, 또는 충돌 중인(unmerged) 파일.
///                    그 상태 파일은 관리 폴더에 있어 제거와 함께 사라지고 패치로 되살릴 수 없다.
/// git 이 실패하면 [ShelveError] — 판정에서는 보존(scan_error), --apply 에서는 항목 실패가 된다.
Future<BlindSpot?> findBackupBlindSpot(Git git, Assessment a, TreeActivity tree) async {
  final admin = await worktreeAdminDir(git, a);
  final r = await git.run(['ls-files', '--stage', '-z'], cwd: a.path);
  if (r.exitCode != 0) {
    throw ShelveError('err.git_failed', {'cmd': 'ls-files', 'why': r.firstErrorLine});
  }
  String? unmerged;
  for (final entry in r.stdoutText.split('\x00')) {
    // 형식: "<모드> <해시> <단계>\t<경로>". 경로순으로 나오므로 첫 항목이 이름순 첫 번째.
    final tab = entry.indexOf('\t');
    if (tab < 0) continue;
    final fields = entry.substring(0, tab).split(' ');
    final path = entry.substring(tab + 1);
    if (fields[0] == '160000') return (reason: 'has_submodules', params: {'path': path});
    if (fields.length > 2 && fields[2] != '0') unmerged ??= path; // 단계 1~3 = 충돌 중
  }
  final store = submoduleStore(admin);
  if (store != null) return (reason: 'has_submodules', params: {'path': store});
  if (tree.nestedRepo != null) return (reason: 'nested_repo', params: {'path': tree.nestedRepo});
  final op = gitOperationInProgress(admin) ?? (unmerged != null ? 'merge' : null);
  if (op != null) return (reason: 'git_in_progress', params: {'op': op});
  return null;
}

/// 관리 폴더에 남은 "진행 중인 git 작업" 표시 파일 → 작업 이름(없으면 null).
String? gitOperationInProgress(String adminDir) {
  const markers = {
    'MERGE_HEAD': 'merge',
    'rebase-merge': 'rebase',
    'rebase-apply': 'rebase',
    'CHERRY_PICK_HEAD': 'cherry-pick',
    'REVERT_HEAD': 'revert',
    'sequencer': 'cherry-pick',
    'BISECT_LOG': 'bisect',
  };
  for (final file in markers.keys) {
    if (FileSystemEntity.typeSync('$adminDir/$file', followLinks: false) !=
        FileSystemEntityType.notFound) {
      return markers[file];
    }
  }
  return null;
}

/// 관리 폴더(`<공통 .git>/worktrees/<id>`) 안 modules/ 에 있는 서브모듈 저장소 이름(없으면 null).
/// git 도 이 폴더가 있으면 --force 없는 제거를 거부한다. 폴더가 사라진 워크트리도 여기서 본다.
String? submoduleStore(String adminDir) {
  final modules = '$adminDir/modules';
  if (FileSystemEntity.typeSync(modules, followLinks: false) == FileSystemEntityType.notFound) {
    return null;
  }
  if (!FileSystemEntity.isDirectorySync(modules)) return 'modules';
  final names = [
    for (final e in Directory(modules).listSync(followLinks: false))
      e.uri.pathSegments.where((s) => s.isNotEmpty).last
  ]..sort();
  return names.isEmpty ? 'modules' : names.first;
}

/// 연결 워크트리의 관리 폴더를 찾는다. 각 `worktrees/<id>/gitdir` 파일이 "<워크트리>/.git" 을
/// 가리키므로(절대 경로, 또는 관리 폴더 기준 상대 경로) 그 값을 이 워크트리 경로와 맞춰 본다.
/// 못 찾으면 [ShelveError] — 확인할 수 없으면 보존한다.
Future<String> worktreeAdminDir(Git git, Assessment a) async {
  final common =
      (await git.text(['rev-parse', '--path-format=absolute', '--git-common-dir'], cwd: a.repo))
          .trim();
  final dir = Directory('$common/worktrees');
  final candidates = dir.existsSync() ? dir.listSync(followLinks: false) : <FileSystemEntity>[];
  for (final admin in candidates) {
    final gitdirFile = File('${admin.path}/gitdir');
    if (admin is! Directory || !gitdirFile.existsSync()) continue;
    var target = gitdirFile.readAsStringSync().trim();
    if (!target.startsWith('/')) target = '${admin.path}/$target';
    if (target.endsWith('/.git')) target = target.substring(0, target.length - '/.git'.length);
    if (target == a.record.path || canonicalPath(target) == a.path) return admin.path;
  }
  throw ShelveError('err.git_failed', {'cmd': 'worktree', 'why': 'admin folder not found for ${a.path}'});
}
