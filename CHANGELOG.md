# Changelog

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
