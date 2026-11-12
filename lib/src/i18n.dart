/// 화면 언어(영어·한국어)와 메시지 표.
///
/// 사용자에게 보이는 문구는 전부 이 파일의 두 표([_en], [_ko])에만 있다.
/// 두 표의 키 집합이 같은지는 test/i18n_test.dart 가 확인한다.
library;

/// 언어 결정 규칙: `--lang` > WORKTREE_SHELVE_LANG > LC_ALL > LC_MESSAGES > LANG.
/// 처음으로 값이 있는 것을 보고, `ko` 로 시작하면 한국어, 아니면 영어.
String resolveLang(String? flag, Map<String, String> env) {
  final candidates = [
    flag,
    env['WORKTREE_SHELVE_LANG'],
    env['LC_ALL'],
    env['LC_MESSAGES'],
    env['LANG'],
  ];
  for (final value in candidates) {
    if (value == null || value.trim().isEmpty) continue;
    return value.trim().toLowerCase().startsWith('ko') ? 'ko' : 'en';
  }
  return 'en';
}

/// 고른 언어의 메시지를 꺼내는 작은 도우미.
class Messages {
  Messages(this.lang) : _table = lang == 'ko' ? _ko : _en;

  final String lang;
  final Map<String, String> _table;

  /// `{name}` 자리를 [params] 값으로 채운 문장을 돌려준다.
  String t(String key, [Map<String, Object?> params = const {}]) {
    var text = _table[key] ?? _en[key] ?? key;
    params.forEach((name, value) {
      text = text.replaceAll('{$name}', '${value ?? ''}');
    });
    return text;
  }
}

/// 테스트용: 두 언어의 키 집합.
Set<String> messageKeys(String lang) => (lang == 'ko' ? _ko : _en).keys.toSet();

const _helpEn = '''
worktree-shelve — back up and remove stale git worktrees, restore them later.

Usage:
  worktree-shelve scan    [--root DIR] [--days N] [--apply] [--json] [--log FILE]
                          [--backup-dir DIR] [--ignored-cap MB] [--lang en|ko]
  worktree-shelve restore <backup-id> [--to PATH] [--backup-dir DIR]
  worktree-shelve backups [--backup-dir DIR] [--json]
  worktree-shelve sandbox [DIR]
  worktree-shelve --help | --version

Commands:
  scan      Find worktrees and show what would happen. Nothing changes without --apply.
  restore   Recreate a removed worktree from its backup.
  backups   List backups.
  sandbox   Create a practice repository (default ./shelve-sandbox) and preview it.

Options:
  --root DIR         Folder to search for repositories (default: current folder).
  --days N           A worktree is stale when its last commit AND newest file edit
                     are both older than N days (default: 7).
  --apply            Back up, verify, then remove stale worktrees and prune gone ones.
  --json             Print machine-readable JSON instead of a table.
  --log FILE         Append one JSON line per action to FILE.
  --backup-dir DIR   Where backups go (default: \$WORKTREE_SHELVE_BACKUP_DIR,
                     \$XDG_STATE_HOME/worktree-shelve/backups or
                     ~/.local/state/worktree-shelve/backups).
  --ignored-cap MB   Keep a worktree whose ignored non-build files exceed MB (default: 100).
  --to PATH          Restore into PATH instead of the original location.
  --lang en|ko       Screen language (also WORKTREE_SHELVE_LANG, LC_ALL, LC_MESSAGES, LANG).

Exit codes: 0 ok, 1 some worktrees failed, 2 usage or setup error.
  A failed worktree is left untouched, unless git itself stopped midway while removing it;
  then the error names the backup id and the restore command.''';

const _helpKo = '''
worktree-shelve — 오래된 git 워크트리를 백업한 뒤 제거하고, 나중에 되살립니다.

사용법:
  worktree-shelve scan    [--root 폴더] [--days 일수] [--apply] [--json] [--log 파일]
                          [--backup-dir 폴더] [--ignored-cap MB] [--lang en|ko]
  worktree-shelve restore <백업-ID> [--to 경로] [--backup-dir 폴더]
  worktree-shelve backups [--backup-dir 폴더] [--json]
  worktree-shelve sandbox [폴더]
  worktree-shelve --help | --version

명령:
  scan      워크트리를 찾아 무엇을 할지 보여 줍니다. --apply 가 없으면 아무것도 바꾸지 않습니다.
  restore   제거한 워크트리를 백업에서 다시 만듭니다.
  backups   백업 목록을 보여 줍니다.
  sandbox   연습용 저장소(기본 ./shelve-sandbox)를 만들고 미리보기를 보여 줍니다.

옵션:
  --root 폴더         저장소를 찾을 폴더 (기본: 현재 폴더).
  --days 일수         마지막 커밋과 가장 최근 파일 수정이 둘 다 이 일수보다 오래되면
                      오래된 워크트리로 봅니다 (기본: 7).
  --apply             오래된 워크트리를 백업·검증한 뒤 제거하고, 폴더가 없어진 기록을 정리합니다.
  --json              표 대신 기계가 읽는 JSON 을 출력합니다.
  --log 파일          실행한 동작마다 JSON 한 줄을 파일 끝에 덧붙입니다.
  --backup-dir 폴더   백업 위치 (기본: \$WORKTREE_SHELVE_BACKUP_DIR,
                      \$XDG_STATE_HOME/worktree-shelve/backups 또는
                      ~/.local/state/worktree-shelve/backups).
  --ignored-cap MB    무시된 비산출물 파일 합계가 이 크기를 넘으면 지우지 않고 보존 (기본: 100).
  --to 경로           원래 위치 대신 이 경로에 되살립니다.
  --lang en|ko        화면 언어 (WORKTREE_SHELVE_LANG, LC_ALL, LC_MESSAGES, LANG 순으로도 정함).

종료 코드: 0 정상, 1 일부 워크트리 실패, 2 사용법·환경 오류.
  실패한 워크트리는 손대지 않고 그대로 둡니다. 단, 지우는 도중 git 자체가 멈춘 경우에는
  오류 메시지에 백업 ID 와 되살리기 명령을 알려 줍니다.''';

const Map<String, String> _en = {
  'help': _helpEn,
  'err.prefix': 'error',
  // 사용법 오류
  'err.unknown_option': 'unknown option for {cmd}: {opt} (see worktree-shelve --help)',
  'err.unknown_command':
      'unknown command: {cmd} (commands: scan, restore, backups, sandbox; see worktree-shelve --help)',
  'err.missing_value': 'option {opt} needs a value',
  'err.bad_number': 'option {opt} needs a whole number of at least {min}, got "{value}"',
  'err.bad_lang': 'option --lang accepts en or ko, got "{value}"',
  'err.extra_arg': 'unexpected argument for {cmd}: {arg}',
  'err.missing_id': 'restore needs a backup id (list them with: worktree-shelve backups)',
  // 환경 오류
  'err.root_missing': '--root folder does not exist: {path}',
  'err.root_not_dir': '--root is not a folder: {path}',
  'err.git_missing': 'git was not found on PATH; install git 2.36 or newer',
  'err.git_too_old': 'git {version} is too old; worktree-shelve needs git 2.36 or newer',
  'err.tool_missing': '{tool} was not found on PATH; it is needed to write and read backups',
  'err.backup_dir_unwritable':
      'cannot write to backup folder {path}; give it write permission or choose another with --backup-dir DIR',
  'err.backup_dir_no_home': 'cannot pick a backup folder because HOME is not set; pass --backup-dir DIR',
  'err.log_unwritable': 'cannot write log file {path}; check the folder permissions or choose another --log FILE',
  'err.backup_not_found': 'no backup named {id} in {dir}; list backups with: worktree-shelve backups',
  'err.backup_bad_id': '"{id}" is not a valid backup id; list backups with: worktree-shelve backups',
  'err.backup_damaged': 'backup {id} is damaged ({why}); its files are in {dir}',
  'err.restore_target_exists':
      'restore target already exists: {path}; remove it or choose another place with --to PATH',
  'err.restore_repo_missing': 'the repository of this backup no longer exists: {path}',
  'err.restore_branch_busy':
      'branch {branch} is already checked out in {path}; remove or switch that worktree first',
  'err.restore_failed': 'restore of {id} stopped while {step}: {why}; the partial worktree is at {path}',
  'err.git_failed': 'git {cmd} failed: {why}',
  'err.sandbox_not_empty': '{path} exists and is not a worktree-shelve sandbox; choose an empty folder',
  'err.fs': 'cannot access {path}: {why}',
  'err.unexpected': 'unexpected problem: {why}',
  // 항목 실패(종료 코드 1). item.failed 는 git 을 부르기 전에 멈춘 경우(아무것도 지우지 않음).
  'item.failed': '{path}: {why}; left in place (backup folder: {dir}). {fix}',
  // git worktree remove 가 실패한 경우 — 일부가 지워졌을 수 있어 백업 ID 와 복원 명령을 알린다.
  'item.partial':
      '{path}: {why}. Everything is in backup {id}; restore it with: {cmd} (or delete {abs} first and run it without --to)',
  'item.remove_failed':
      '{path}: {why}; git still lists the worktree. Backup {id} is kept in case files were deleted; restore with: {cmd}. {fix}',
  'hint.new_path': 'NEW_PATH',
  'fail.not_removable':
      'cannot delete everything: {path} is read-only or owned by another user (fix it with chmod -R u+w {path}, or chown if another user created it)',
  'fail.remove_partial':
      'git stopped midway ({why}); it dropped the worktree record and may have deleted part of the folder',
  'fail.backup_write': 'could not write the backup ({why})',
  'fail.verify': 'backup check failed ({what})',
  'fail.changed': 'the worktree changed while it was being backed up',
  'fail.newline_name': 'a file name contains a line break, which this tool does not back up',
  'fail.remove': 'git worktree remove failed ({why})',
  'fail.pin': 'could not pin the detached commit ({why})',
  'fail.blind_spot': 'it changed after the scan ({why})',
  'fix.permissions': 'Check the file and folder permissions, or use --backup-dir DIR.',
  'fix.retry': 'Nothing was removed; run the scan again.',
  'fix.remove': 'Fix what git reported, then run the scan again.',
  // 표
  'col.repo': 'REPO',
  'col.worktree': 'WORKTREE',
  'col.branch': 'BRANCH',
  'col.verdict': 'VERDICT',
  'col.why': 'WHY',
  'col.size': 'SIZE',
  'col.id': 'BACKUP ID',
  'col.created': 'CREATED',
  'col.files': 'FILES',
  'branch.detached': '(detached)',
  'verdict.keep': 'keep',
  'verdict.remove': 'remove',
  'verdict.shelve': 'shelve',
  'verdict.prune': 'prune',
  'reason.main': 'main worktree',
  'reason.locked': 'locked: {why}',
  'reason.locked_plain': 'locked',
  'reason.cwd': 'you are inside it',
  'reason.outside_root': 'outside --root',
  'reason.mounted': 'contains a mount point ({path})',
  'reason.recent_commit': 'last commit {age} ago',
  'reason.recent_edit': 'file edited {age} ago',
  'reason.missing_dir': 'folder is gone',
  'reason.gitdir_missing': 'folder lost its .git link',
  'reason.ignored_too_large': 'ignored files {size} over the {cap} cap',
  'reason.has_submodules': 'has submodule {path}; backups cannot cover it',
  'reason.nested_repo': 'has another git repo at {path}; backups cannot cover it',
  'reason.git_in_progress': 'unfinished git {op}; backups cannot cover it',
  'reason.stale_clean': 'idle {age}, no changes',
  'reason.stale_dirty': 'idle {age}, {n} changed file(s)',
  'reason.scan_error': 'could not inspect it ({why})',
  'age.d': '{n}d',
  'age.h': '{n}h',
  'age.m': '{n}m',
  // scan 요약
  'scan.no_repos': 'No git repositories found under {root}.',
  'scan.summary':
      'Would reclaim {size} from {n} worktree(s) and prune {p} stale record(s). Preview only: nothing was changed. Add --apply to do it.',
  'scan.sandbox_note':
      'Practice sandbox: its commit and file dates were back-dated on purpose.',
  // --apply
  'apply.shelved': 'shelved  {path}  backup {id}',
  'apply.removed': 'removed  {path}  backup {id}',
  'apply.pruned': 'pruned   {path}',
  'apply.failed': 'FAILED   {path}',
  'apply.restore': '         restore: {cmd}',
  'apply.pinned': '         pinned detached commit {sha} as {ref}',
  'apply.summary': 'Reclaimed {size} from {n} worktree(s), pruned {p}, failed {f}. Backups: {dir}',
  // backups
  'backups.none': 'No backups in {dir}.',
  'backups.header': 'Backups in {dir}:',
  // restore
  'restore.done':
      'Restored {path} on {branch}: changes {patch}, {u} untracked and {i} ignored file(s) put back.',
  'restore.patch_yes': 'applied',
  'restore.patch_no': 'none',
  'restore.moved':
      'Branch {branch} has moved since the backup, so the worktree was restored at {sha} (detached). Switch with: git -C {path} switch {branch}',
  'restore.kept': 'The backup stays in {dir}; delete it when you no longer need it.',
  'restore.step.add': 'creating the worktree',
  'restore.step.patch': 'applying changes.patch',
  'restore.step.staged': 'restoring staged changes',
  'restore.step.untracked': 'unpacking untracked.tar',
  'restore.step.ignored': 'unpacking ignored.tar',
  'restore.step.check': 'checking restored files',
  'restore.check_bad': '{n} file(s) differ from the backup',
  // sandbox
  'sandbox.made': 'Created practice sandbox: {path}',
  'sandbox.next': 'Next: worktree-shelve scan --root {path} --apply',
};

const Map<String, String> _ko = {
  'help': _helpKo,
  'err.prefix': '오류',
  'err.unknown_option': '{cmd} 명령에 없는 옵션입니다: {opt} (도움말: worktree-shelve --help)',
  'err.unknown_command':
      '알 수 없는 명령입니다: {cmd} (명령: scan, restore, backups, sandbox / 도움말: worktree-shelve --help)',
  'err.missing_value': '{opt} 옵션에 값이 필요합니다',
  'err.bad_number': '{opt} 옵션은 {min} 이상의 정수여야 합니다. 받은 값: "{value}"',
  'err.bad_lang': '--lang 옵션은 en 또는 ko 만 받습니다. 받은 값: "{value}"',
  'err.extra_arg': '{cmd} 명령에 필요 없는 인자입니다: {arg}',
  'err.missing_id': 'restore 에는 백업 ID 가 필요합니다 (목록 보기: worktree-shelve backups)',
  'err.root_missing': '--root 폴더가 없습니다: {path}',
  'err.root_not_dir': '--root 가 폴더가 아닙니다: {path}',
  'err.git_missing': 'PATH 에서 git 을 찾지 못했습니다. git 2.36 이상을 설치하세요',
  'err.git_too_old': 'git {version} 은 너무 오래되었습니다. worktree-shelve 는 git 2.36 이상이 필요합니다',
  'err.tool_missing': 'PATH 에서 {tool} 을 찾지 못했습니다. 백업을 쓰고 읽는 데 필요합니다',
  'err.backup_dir_unwritable':
      '백업 폴더에 쓸 수 없습니다: {path} — 쓰기 권한을 주거나 --backup-dir 폴더 로 다른 곳을 지정하세요',
  'err.backup_dir_no_home': 'HOME 이 설정되지 않아 백업 폴더를 정할 수 없습니다. --backup-dir 폴더 를 지정하세요',
  'err.log_unwritable': '로그 파일에 쓸 수 없습니다: {path} — 폴더 권한을 확인하거나 다른 --log 파일 을 지정하세요',
  'err.backup_not_found': '{dir} 에 {id} 백업이 없습니다. 목록 보기: worktree-shelve backups',
  'err.backup_bad_id': '"{id}" 는 올바른 백업 ID 가 아닙니다. 목록 보기: worktree-shelve backups',
  'err.backup_damaged': '{id} 백업이 손상되었습니다({why}). 파일 위치: {dir}',
  'err.restore_target_exists':
      '되살릴 위치가 이미 있습니다: {path} — 지우거나 --to 경로 로 다른 곳을 지정하세요',
  'err.restore_repo_missing': '이 백업의 저장소가 더 이상 없습니다: {path}',
  'err.restore_branch_busy':
      '{branch} 브랜치가 이미 {path} 에 체크아웃되어 있습니다. 그 워크트리를 먼저 지우거나 다른 브랜치로 바꾸세요',
  'err.restore_failed': '{id} 되살리기가 "{step}" 단계에서 멈췄습니다: {why} — 만들다 만 워크트리 위치: {path}',
  'err.git_failed': 'git {cmd} 실행 실패: {why}',
  'err.sandbox_not_empty': '{path} 가 이미 있고 worktree-shelve 연습 폴더가 아닙니다. 빈 폴더를 지정하세요',
  'err.fs': '{path} 에 접근할 수 없습니다: {why}',
  'err.unexpected': '예상하지 못한 문제: {why}',
  'item.failed': '{path}: {why} — 지우지 않고 그대로 두었습니다(백업 폴더: {dir}). {fix}',
  'item.partial':
      '{path}: {why}. 모든 내용은 백업 {id} 에 있습니다. 되살리기: {cmd} (또는 {abs} 를 먼저 지운 뒤 --to 없이 실행)',
  'item.remove_failed':
      '{path}: {why} — git 기록에는 워크트리가 남아 있습니다. 파일이 지워졌을 수 있어 백업 {id} 를 남겨 두었습니다. 되살리기: {cmd}. {fix}',
  'hint.new_path': '새-경로',
  'fail.not_removable':
      '끝까지 지울 수 없습니다: {path} 가 읽기 전용이거나 다른 사용자 소유입니다(chmod -R u+w {path} 로 고치거나, 다른 사용자가 만든 폴더면 chown)',
  'fail.remove_partial': 'git 이 도중에 멈췄습니다({why}). 워크트리 기록을 지웠고 폴더 일부가 지워졌을 수 있습니다',
  'fail.backup_write': '백업을 쓰지 못했습니다({why})',
  'fail.verify': '백업 검증에 실패했습니다({what})',
  'fail.changed': '백업하는 동안 워크트리가 바뀌었습니다',
  'fail.newline_name': '파일 이름에 줄바꿈이 있어 백업하지 않습니다',
  'fail.remove': 'git worktree remove 가 실패했습니다({why})',
  'fail.pin': '분리된(detached) 커밋을 고정하지 못했습니다({why})',
  'fail.blind_spot': '스캔 뒤에 바뀌었습니다({why})',
  'fix.permissions': '파일·폴더 권한을 확인하거나 --backup-dir 폴더 를 지정하세요.',
  'fix.retry': '아무것도 지우지 않았습니다. 다시 scan 하세요.',
  'fix.remove': 'git 이 알려 준 원인을 고친 뒤 다시 scan 하세요.',
  'col.repo': '저장소',
  'col.worktree': '워크트리',
  'col.branch': '브랜치',
  'col.verdict': '판정',
  'col.why': '이유',
  'col.size': '크기',
  'col.id': '백업 ID',
  'col.created': '만든 때',
  'col.files': '파일 수',
  'branch.detached': '(분리됨)',
  'verdict.keep': '보존',
  'verdict.remove': '제거',
  'verdict.shelve': '백업 후 제거',
  'verdict.prune': '기록 정리',
  'reason.main': '메인 워크트리',
  'reason.locked': '잠김: {why}',
  'reason.locked_plain': '잠김',
  'reason.cwd': '지금 그 안에서 실행 중',
  'reason.outside_root': '--root 밖',
  'reason.mounted': '마운트 지점 포함({path})',
  'reason.recent_commit': '마지막 커밋 {age} 전',
  'reason.recent_edit': '파일 수정 {age} 전',
  'reason.missing_dir': '폴더가 사라짐',
  'reason.gitdir_missing': '폴더의 .git 연결이 끊김',
  'reason.ignored_too_large': '무시 파일 {size}, 상한 {cap} 초과',
  'reason.has_submodules': '서브모듈 {path} 있음, 백업이 그 안을 담지 못함',
  'reason.nested_repo': '안에 다른 git 저장소({path}) 있음, 백업이 그 안을 담지 못함',
  'reason.git_in_progress': '끝나지 않은 git {op} 있음, 백업이 그 상태를 담지 못함',
  'reason.stale_clean': '{age} 동안 쓰지 않음, 변경 없음',
  'reason.stale_dirty': '{age} 동안 쓰지 않음, 바뀐 파일 {n}개',
  'reason.scan_error': '확인하지 못함({why})',
  'age.d': '{n}일',
  'age.h': '{n}시간',
  'age.m': '{n}분',
  'scan.no_repos': '{root} 아래에서 git 저장소를 찾지 못했습니다.',
  'scan.summary':
      '회수 예상: {size} (워크트리 {n}개), 기록 정리 {p}개. 미리보기라서 아무것도 바꾸지 않았습니다. 실행하려면 --apply 를 붙이세요.',
  'scan.sandbox_note': '연습용 샌드박스입니다. 커밋 날짜와 파일 수정 시각을 일부러 과거로 돌려 두었습니다.',
  'apply.shelved': '백업 후 제거  {path}  백업 {id}',
  'apply.removed': '제거          {path}  백업 {id}',
  'apply.pruned': '기록 정리     {path}',
  'apply.failed': '실패          {path}',
  'apply.restore': '              되살리기: {cmd}',
  'apply.pinned': '              분리된 커밋 {sha} 를 {ref} 로 고정함',
  'apply.summary': '회수: {size} (워크트리 {n}개), 기록 정리 {p}개, 실패 {f}개. 백업 위치: {dir}',
  'backups.none': '{dir} 에 백업이 없습니다.',
  'backups.header': '백업 위치 {dir}:',
  'restore.done':
      '{path} 를 {branch} 에 되살렸습니다. 변경 내용 {patch}, 미추적 파일 {u}개, 무시 파일 {i}개를 되돌렸습니다.',
  'restore.patch_yes': '적용함',
  'restore.patch_no': '없음',
  'restore.moved':
      '백업 뒤에 {branch} 브랜치가 움직여서 커밋 {sha} 에 분리된 상태로 되살렸습니다. 브랜치로 옮기기: git -C {path} switch {branch}',
  'restore.kept': '백업은 {dir} 에 그대로 있습니다. 필요 없으면 지우세요.',
  'restore.step.add': '워크트리 만들기',
  'restore.step.patch': 'changes.patch 적용',
  'restore.step.staged': '스테이지 변경 되돌리기',
  'restore.step.untracked': 'untracked.tar 풀기',
  'restore.step.ignored': 'ignored.tar 풀기',
  'restore.step.check': '되살린 파일 확인',
  'restore.check_bad': '백업과 다른 파일 {n}개',
  'sandbox.made': '연습용 샌드박스를 만들었습니다: {path}',
  'sandbox.next': '다음 단계: worktree-shelve scan --root {path} --apply',
};
