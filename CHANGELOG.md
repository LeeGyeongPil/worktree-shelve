# Changelog

## 0.2.0 (2026-11-14)

- Added: `worktree-shelve backups --delete <id>` deletes one backup. Naming the id is the
  confirmation. Only a real folder directly inside the backup folder with a readable
  `manifest.json` is deleted; links are not followed; anything else exits with code 2 and deletes
  nothing.
- Added: `worktree-shelve backups --prune-older-than N [--apply] [--json]` lists backups whose
  manifest `created_at` is more than `N` days old. It is a preview unless `--apply` is given.
  Folders without a readable manifest, with a non-backup name, or ending in `.partial` are never
  deleted. Only folders named like backups this tool makes (`YYYYMMDD-HHMMSS-name`) whose
  manifest `id` matches the folder name are deleted by `--delete` and `--prune-older-than`.
- Added: deleting removes `manifest.json` last and checks write permission first, so a failed
  delete leaves the backup listed and deletable; the error (exit 2) says how to fix permissions.
- Changed: "list backups with" hints include `--backup-dir` when you passed it; a damaged
  backup refused by `--delete` says what to do next.
- Added: leftover `<id>.partial` folders from interrupted backups are shown separately in
  `backups` and `--prune-older-than` output (display only; nothing deletes them).
- Changed: the `restore` closing line now mentions `worktree-shelve backups --delete <id>`.
- All new messages and help text exist in English and Korean.
- Full changes: https://github.com/LeeGyeongPil/worktree-shelve/compare/v0.1.3...v0.2.0

### Known issues

- The closing hint of `restore` does not include `--backup-dir` when you passed it.
- `backups --prune-older-than --apply` can print `Deleted before this: 0` in a message where the count is not meaningful.
- The backup list display has small wording and layout rough edges.
- `--prune-older-than` without a value gives a generic error instead of a specific one.

## 0.1.3 (2026-11-13)

- Fixed: when the folder that blocks removal is the worktree's parent folder, the error (and the
  log `error` field) now says `chmod u+w <parent>` (or `chown <parent>`) without `-R`, since only
  the parent folder itself needs write permission. Folders inside the worktree still get
  `chmod -R u+w`. Detection, exit code 1, and the "no backup" behavior are unchanged (English and
  Korean).
- Full changes: https://github.com/LeeGyeongPil/worktree-shelve/compare/v0.1.2...v0.1.3

## 0.1.2 (2026-11-13)

- Fixed: when a worktree stopped before any backup was made (for example the pre-removal
  permission check), the error line no longer ends with `(backup folder: ...)`; it now says
  `no backup was made`. If no backup was kept in the whole run, the `--apply` summary line says
  `No backup was made.` instead of showing a backup folder (English and Korean).
- Full changes: https://github.com/LeeGyeongPil/worktree-shelve/compare/v0.1.1...v0.1.2

## 0.1.1 (2026-11-12)

- Fixed: tests no longer depend on the order in which git deletes files or lists worktrees
  (differs between macOS and Linux); the "git stopped midway" test now also covers a
  read-only top folder.
- Changed: `scan` output is deterministic everywhere: the main worktree first, the rest sorted by path.
- Changed: the "git stopped midway" message now says the folder "may have" been partly deleted
  (git may have deleted nothing).
- CI: prints tool versions before the tests; test timeout doubled (`dart_test.yaml`).
- Added a portability test (no OS-specific paths, no global git config assumptions).

### Known issues

- If stdout is closed early (`... | head -1`), the raw `FileSystemException ... Broken pipe`
  message and exit code 0 appear on every run, not only depending on timing (0.1.0 notes corrected).
- A file name with a newline makes the backup check fail; nothing is deleted, but the message
  does not name the newline as the reason.
- Run as root, the two "git stops midway" tests return early and show as passed, not skipped.

## 0.1.0 (2026-11-12)

- `scan`: find worktrees under `--root`, judge each one with a dual staleness check
  (last commit AND newest file edit older than `--days`), print a table or `--json`.
- `scan --apply`: back up (patches, untracked files, ignored non-build files such as `.env`),
  verify the backup, then remove stale worktrees; prune records whose folder is gone;
  pin detached commits that no branch or tag contains under `refs/worktree-shelve/`.
- Worktrees the backup cannot fully cover are always kept, never force-removed:
  submodules (`has_submodules`), another git repository inside (`nested_repo`), and an
  unfinished merge, rebase, cherry-pick, revert or bisect (`git_in_progress`). The same check
  runs again right before each removal.
- Before backing up, and again right before removing, `--apply` checks that every folder in the
  worktree (and its parent folder) can be deleted by you. A read-only folder or one owned by
  another user stops that worktree with nothing backed up or removed, and the error tells you
  to run `chmod -R u+w <folder>` (or `chown`).
- If `git worktree remove` still fails midway, the verified backup is kept and the error, the
  `FAILED` line and the `--log` entry give the backup id and `restore <id> --to <new path>`
  (git may already have dropped the worktree record, so the next scan would not show it).
- `restore`, `backups`, `sandbox` commands.
- `--log FILE` appends JSON Lines (with `reason` and `reason_text`); kept-for-safety worktrees
  are logged as `skip`. English and Korean screens (`--lang en|ko`).

### Known issues

- A worktree stopped by the pre-removal permission check still shows `(backup folder: <dir>)`
  in its error, although no backup was made in that case.
- When the blocking folder is the parent folder, the hint says `chmod -R u+w <parent>`;
  `chmod u+w <parent>` without `-R` is enough.
- If stdout is closed early (`... | head -1`), a raw `FileSystemException ... Broken pipe`
  message can appear and the exit code is 0.
- A folder with an incomplete `.git` (no `HEAD`) inside another repository can be resolved to
  that enclosing repository and shown as a misleading `keep  main worktree` row. Nothing is removed.
