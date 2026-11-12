/// worktree-shelve: 오래된 git 워크트리를 백업한 뒤 제거하고 되살리는 CLI.
///
/// 테스트와 재사용을 위해 최소한의 API 만 내보낸다.
library;

export 'src/backup.dart' show isValidBackupId, listIgnoredFiles, FileSet;
export 'src/cli.dart' show runCli, CliContext, toolVersion;
export 'src/errors.dart' show ShelveError;
export 'src/git.dart' show Git, findExecutable, runProcess, ProcResult;
export 'src/i18n.dart' show resolveLang, Messages, messageKeys;
export 'src/mounts.dart' show parseMountOutput, parseProcMounts, mountInside;
export 'src/porcelain.dart' show parsePorcelainZ, WorktreeRecord;
export 'src/sandbox.dart' show RepoBuilder, buildSandbox, sandboxMarker;
export 'src/activity.dart' show measureTree, TreeActivity;
export 'src/verdict.dart' show Verdict, Assessment, canonicalPath;
