// backups --delete / --prune-older-than: 단일 삭제, 오래된 백업 정리(미리보기 기본), .partial 표시.
// 백업 폴더는 손으로 만든다(git 이 필요 없다). 경로는 전부 임시 폴더 기준이다.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:worktree_shelve/worktree_shelve.dart';

import 'support/fixture.dart';

void main() {
  late Fixture fx;
  setUp(() async => fx = await Fixture.create());
  tearDown(() => fx.dispose());

  /// 유효한 백업 폴더 하나(manifest + 파일). created_at 은 [ageDays] 일 전 UTC.
  void makeBackup(String id, {required int ageDays, int bytes = 1000, bool manifest = true}) {
    final dir = Directory('${fx.backups}/$id')..createSync(recursive: true);
    File('${dir.path}/untracked.tar').writeAsBytesSync(List.filled(bytes, 1));
    if (manifest) {
      File('${dir.path}/manifest.json').writeAsStringSync(jsonEncode({
        'id': id,
        'head': 'a' * 40,
        'repo': '${fx.base}/repo',
        'worktree': '${fx.base}/wt-$id',
        'branch': 'refs/heads/feat',
        'created_at': fx.now.toUtc().subtract(Duration(days: ageDays)).toIso8601String(),
        'untracked': <Object?>[],
        'ignored': <Object?>[],
      }));
    }
  }

  bool exists(String id) => Directory('${fx.backups}/$id').existsSync();
  List<String> bk(List<String> a) => [...a, '--backup-dir', fx.backups];

  group('--delete', () {
    test('deletes one valid backup and says so', () async {
      makeBackup('20260101-000000-old', ageDays: 90);
      makeBackup('20260102-000000-keep', ageDays: 90);
      final run = await fx.cli(bk(['backups', '--delete', '20260101-000000-old']));
      expect(run.code, 0);
      expect(run.out, contains('Deleted backup 20260101-000000-old'));
      expect(exists('20260101-000000-old'), isFalse);
      expect(exists('20260102-000000-keep'), isTrue);
    });

    test('unknown id exits 2 and deletes nothing', () async {
      makeBackup('20260101-000000-old', ageDays: 90);
      final run = await fx.cli(bk(['backups', '--delete', 'nope']));
      expect(run.code, 2);
      expect(run.err, contains('no backup named nope'));
      expect(exists('20260101-000000-old'), isTrue);
    });

    test('malformed id with ../ exits 2 and touches nothing outside', () async {
      makeBackup('20260101-000000-old', ageDays: 90);
      Directory('${fx.base}/outside').createSync();
      final run = await fx.cli(bk(['backups', '--delete', '../outside']));
      expect(run.code, 2);
      expect(run.err, contains('not a valid backup id'));
      expect(Directory('${fx.base}/outside').existsSync(), isTrue);
      expect(exists('20260101-000000-old'), isTrue);
    });

    test('folder without manifest.json is refused', () async {
      makeBackup('20260101-000000-nomf', ageDays: 90, manifest: false);
      final run = await fx.cli(bk(['backups', '--delete', '20260101-000000-nomf']));
      expect(run.code, 2);
      expect(run.err, contains('no manifest.json'));
      expect(exists('20260101-000000-nomf'), isTrue);
    });

    test('damaged manifest is refused', () async {
      makeBackup('20260101-000000-bad', ageDays: 90, manifest: false);
      File('${fx.backups}/20260101-000000-bad/manifest.json').writeAsStringSync('{not json');
      final run = await fx.cli(bk(['backups', '--delete', '20260101-000000-bad']));
      expect(run.code, 2);
      expect(run.err, contains('damaged'));
      expect(exists('20260101-000000-bad'), isTrue);
    });

    test('a symlink is never followed or deleted', () async {
      makeBackup('20260101-000000-real', ageDays: 90);
      Link('${fx.backups}/20260102-000000-link').createSync('${fx.backups}/20260101-000000-real');
      final run = await fx.cli(bk(['backups', '--delete', '20260102-000000-link']));
      expect(run.code, 2);
      expect(run.err, contains('not a regular backup folder'));
      expect(exists('20260101-000000-real'), isTrue);
      expect(File('${fx.backups}/20260101-000000-real/manifest.json').existsSync(), isTrue);
    });

    test('--json prints the deleted id and size', () async {
      makeBackup('20260101-000000-old', ageDays: 90, bytes: 500);
      final run = await fx.cli(bk(['backups', '--delete', '20260101-000000-old', '--json']));
      expect(run.code, 0);
      final deleted = run.json['deleted'] as Map<String, Object?>;
      expect(deleted['id'], '20260101-000000-old');
      expect(deleted['size_bytes'], greaterThanOrEqualTo(500));
    });

    test('Korean output', () async {
      makeBackup('20260101-000000-old', ageDays: 90);
      final run = await fx.cli(bk(['backups', '--delete', '20260101-000000-old', '--lang', 'ko']));
      expect(run.code, 0);
      expect(run.out, contains('백업 20260101-000000-old 를 지웠습니다'));
      final bad = await fx.cli(bk(['backups', '--delete', 'nope', '--lang', 'ko']));
      expect(bad.code, 2);
      expect(bad.err, contains('백업이 없습니다'));
    });
  });

  group('--prune-older-than', () {
    test('preview lists old backups and deletes nothing', () async {
      makeBackup('20260101-000000-old', ageDays: 60);
      makeBackup('20260102-000000-new', ageDays: 5);
      final run = await fx.cli(bk(['backups', '--prune-older-than', '30']));
      expect(run.code, 0);
      expect(run.out, contains('20260101-000000-old'));
      expect(run.out, isNot(contains('20260102-000000-new')));
      expect(run.out, contains('Preview only: nothing was changed. Add --apply to delete.'));
      expect(exists('20260101-000000-old'), isTrue);
      expect(exists('20260102-000000-new'), isTrue);
    });

    test('--apply deletes only the old ones and reports count and size', () async {
      makeBackup('20260101-000000-old', ageDays: 60);
      makeBackup('20260102-000000-old2', ageDays: 31);
      makeBackup('20260103-000000-new', ageDays: 5);
      final run = await fx.cli(bk(['backups', '--prune-older-than', '30', '--apply']));
      expect(run.code, 0);
      expect(run.out, contains('Deleted 2 backup(s)'));
      expect(exists('20260101-000000-old'), isFalse);
      expect(exists('20260102-000000-old2'), isFalse);
      expect(exists('20260103-000000-new'), isTrue);
    });

    test('folders without manifest, bad names and .partial stay, and .partial is shown', () async {
      makeBackup('20260101-000000-nomf', ageDays: 90, manifest: false);
      makeBackup('20260102-000000-old', ageDays: 90);
      Directory('${fx.backups}/not a backup').createSync(recursive: true);
      makeBackup('20260103-000000-half.partial', ageDays: 90);
      final run = await fx.cli(bk(['backups', '--prune-older-than', '0', '--apply']));
      expect(run.code, 0);
      expect(exists('20260102-000000-old'), isFalse);
      expect(exists('20260101-000000-nomf'), isTrue);
      expect(exists('not a backup'), isTrue);
      expect(exists('20260103-000000-half.partial'), isTrue);
      expect(run.out, contains('Leftover unfinished folders'));
      expect(run.out, contains('20260103-000000-half.partial'));
    });

    test('plain backups list also shows leftover .partial folders', () async {
      makeBackup('20260103-000000-half.partial', ageDays: 1);
      final run = await fx.cli(bk(['backups']));
      expect(run.code, 0);
      expect(run.out, contains('Leftover unfinished folders'));
      expect(run.out, contains('20260103-000000-half.partial'));
    });

    test('symlinked folder is not followed or deleted', () async {
      makeBackup('20260101-000000-real', ageDays: 90);
      final outside = Directory('${fx.base}/outside')..createSync();
      File('${outside.path}/keep.txt').writeAsStringSync('x');
      Link('${fx.backups}/20260102-000000-link').createSync(outside.path);
      final run = await fx.cli(bk(['backups', '--prune-older-than', '1', '--apply']));
      expect(run.code, 0);
      expect(exists('20260101-000000-real'), isFalse);
      expect(File('${outside.path}/keep.txt').existsSync(), isTrue);
      expect(Link('${fx.backups}/20260102-000000-link').existsSync(), isTrue);
    });

    test('English and Korean output', () async {
      makeBackup('20260101-000000-old', ageDays: 60);
      final en = await fx.cli(bk(['backups', '--prune-older-than', '30']));
      expect(en.out, contains('1 backup(s) older than 30 day(s)'));
      final ko = await fx.cli(bk(['backups', '--prune-older-than', '30', '--lang', 'ko']));
      expect(ko.out, contains('30일보다 오래된 백업 1개'));
      expect(ko.out, contains('--apply 를 붙이세요'));
      final none = await fx.cli(bk(['backups', '--prune-older-than', '365', '--lang', 'ko']));
      expect(none.out, contains('365일보다 오래된 백업이 없습니다'));
    });

    test('--json output for preview and apply', () async {
      makeBackup('20260101-000000-old', ageDays: 60);
      Directory('${fx.backups}/20260105-000000-half.partial').createSync();
      final pre = await fx.cli(bk(['backups', '--prune-older-than', '30', '--json']));
      expect(pre.code, 0);
      expect(pre.json['applied'], false);
      expect(pre.json['older_than_days'], 30);
      expect((pre.json['backups'] as List).single, containsPair('deleted', false));
      expect((pre.json['partial'] as List).single, containsPair('name', '20260105-000000-half.partial'));
      expect(exists('20260101-000000-old'), isTrue);
      final done = await fx.cli(bk(['backups', '--prune-older-than', '30', '--apply', '--json']));
      expect(done.json['applied'], true);
      expect((done.json['backups'] as List).single, containsPair('deleted', true));
      expect(exists('20260101-000000-old'), isFalse);
    });

    test('invalid N exits 2', () async {
      makeBackup('20260101-000000-old', ageDays: 60);
      for (final bad in ['-1', 'abc', '1.5']) {
        final run = await fx.cli(bk(['backups', '--prune-older-than', bad]));
        expect(run.code, 2, reason: bad);
        expect(run.err, contains('--prune-older-than'));
      }
      final ko = await fx.cli(bk(['backups', '--prune-older-than', 'x', '--lang', 'ko']));
      expect(ko.code, 2);
      expect(ko.err, contains('정수'));
      expect(exists('20260101-000000-old'), isTrue);
    });
  });

  group('option combinations', () {
    test('--delete with --prune-older-than exits 2 in both languages', () async {
      makeBackup('20260101-000000-old', ageDays: 60);
      final en = await fx.cli(bk(['backups', '--delete', '20260101-000000-old', '--prune-older-than', '1']));
      expect(en.code, 2);
      expect(en.err, contains('either --delete or --prune-older-than'));
      final ko = await fx.cli(
          bk(['backups', '--delete', '20260101-000000-old', '--prune-older-than', '1', '--lang', 'ko']));
      expect(ko.code, 2);
      expect(ko.err, contains('함께 쓸 수 없습니다'));
      expect(exists('20260101-000000-old'), isTrue);
    });

    test('--apply without --prune-older-than exits 2 in both languages', () async {
      final en = await fx.cli(bk(['backups', '--apply']));
      expect(en.code, 2);
      expect(en.err, contains('--apply only works together with --prune-older-than'));
      final ko = await fx.cli(bk(['backups', '--apply', '--lang', 'ko']));
      expect(ko.code, 2);
      expect(ko.err, contains('--prune-older-than N 과 함께'));
    });

    test('plain backups list and --json are unchanged without leftovers', () async {
      makeBackup('20260101-000000-old', ageDays: 60);
      final run = await fx.cli(bk(['backups', '--json']));
      expect(run.code, 0);
      expect(run.json.keys, ['backup_dir', 'backups']);
      expect((run.json['backups'] as List).single, containsPair('id', '20260101-000000-old'));
    });
  });

  group('only backups made by this tool are deleted', () {
    /// 유효한 백업을 만든 뒤 폴더 이름만 바꾼다(manifest 의 id 는 그대로).
    void makeRenamed(String from, String to) {
      makeBackup(from, ageDays: 90);
      Directory('${fx.backups}/$from').renameSync('${fx.backups}/$to');
    }

    test('prune preview and --apply both leave a renamed manifest folder alone', () async {
      makeRenamed('20260101-000000-old', 'notabackup');
      makeBackup('20260102-000000-real', ageDays: 90);
      final preview = await fx.cli(bk(['backups', '--prune-older-than', '30']));
      expect(preview.out, isNot(contains('notabackup')));
      expect(preview.out, contains('20260102-000000-real'));
      final run = await fx.cli(bk(['backups', '--prune-older-than', '30', '--apply']));
      expect(run.code, 0);
      expect(exists('notabackup'), isTrue);
      expect(exists('20260102-000000-real'), isFalse);
    });

    test('a name that only passes the character check is not deleted either', () async {
      makeRenamed('20260101-000000-old', '20260101-000000-moved'); // 꼴은 맞지만 manifest id 가 다르다
      final run = await fx.cli(bk(['backups', '--prune-older-than', '30', '--apply']));
      expect(run.code, 0);
      expect(exists('20260101-000000-moved'), isTrue);
    });

    test('--delete refuses a renamed folder (en and ko) and keeps it', () async {
      makeRenamed('20260101-000000-old', 'notabackup');
      final en = await fx.cli(bk(['backups', '--delete', 'notabackup']));
      expect(en.code, 2);
      expect(en.err, contains('not named like a backup made by this tool'));
      final ko = await fx.cli(bk(['backups', '--delete', 'notabackup', '--lang', 'ko']));
      expect(ko.code, 2);
      expect(ko.err, contains('백업 이름'));
      expect(exists('notabackup'), isTrue);
    });
  });

  group('error guidance', () {
    test('not-found and bad-id hints keep --backup-dir (en and ko)', () async {
      final en = await fx.cli(bk(['backups', '--delete', 'nope']));
      expect(en.err, contains('list backups with: worktree-shelve backups --backup-dir'));
      final bad = await fx.cli(bk(['backups', '--delete', '../x', '--lang', 'ko']));
      expect(bad.err, contains('목록 보기: worktree-shelve backups --backup-dir'));
      final restore = await fx.cli(bk(['restore', 'nope']));
      expect(restore.err, contains('worktree-shelve backups --backup-dir'));
    });

    test('without --backup-dir the hint stays the short command', () async {
      final run = await fx.cli(['backups', '--delete', 'nope'], envOverride: {'WORKTREE_SHELVE_BACKUP_DIR': fx.backups});
      expect(run.err, contains('list backups with: worktree-shelve backups'));
      expect(run.err, isNot(contains('--backup-dir')));
    });

    test('a damaged manifest refuses --delete and says what to do next (en and ko)', () async {
      makeBackup('20260101-000000-old', ageDays: 90);
      File('${fx.backups}/20260101-000000-old/manifest.json').writeAsStringSync('{not json');
      final en = await fx.cli(bk(['backups', '--delete', '20260101-000000-old']));
      expect(en.code, 2);
      expect(en.err, contains('nothing was deleted'));
      expect(en.err, contains('remove that folder yourself'));
      final ko = await fx.cli(bk(['backups', '--delete', '20260101-000000-old', '--lang', 'ko']));
      expect(ko.err, contains('직접 지우세요'));
      expect(exists('20260101-000000-old'), isTrue);
    });
  });

  group('delete failure', () {
    /// 백업 루트를 읽기 전용으로 만든다. 권한이 안 먹는 환경(root)이면 false.
    bool lockRoot() {
      Process.runSync('chmod', ['555', fx.backups]);
      try {
        File('${fx.backups}/.probe').writeAsStringSync('x');
        File('${fx.backups}/.probe').deleteSync();
        Process.runSync('chmod', ['755', fx.backups]);
        return false;
      } on FileSystemException {
        return true;
      }
    }

    tearDown(() => Process.runSync('chmod', ['755', fx.backups]));

    for (final lang in ['en', 'ko']) {
      test('read-only backup folder: exit 2, message ($lang), backup stays listed and deletable', () async {
        makeBackup('20260101-000000-a', ageDays: 90);
        makeBackup('20260101-000001-b', ageDays: 90);
        if (!lockRoot()) return; // 권한이 적용되지 않는 환경에서는 확인만 건너뛴다
        final del = await fx.cli(bk(['backups', '--delete', '20260101-000000-a', '--lang', lang]));
        expect(del.code, 2);
        expect(del.err, contains(lang == 'en' ? 'could not delete backup' : '지우지 못했습니다'));
        final prune = await fx.cli(bk(['backups', '--prune-older-than', '30', '--apply', '--lang', lang]));
        expect(prune.code, 2);
        expect(prune.err, contains('chmod -R u+w'));
        // 아무것도 부분 삭제되지 않았다: manifest 가 남아 목록에 그대로 나온다.
        expect(File('${fx.backups}/20260101-000000-a/manifest.json').existsSync(), isTrue);
        expect(File('${fx.backups}/20260101-000000-a/untracked.tar').existsSync(), isTrue);
        final list = await fx.cli(bk(['backups', '--json']));
        expect((list.json['backups'] as List), hasLength(2));
        Process.runSync('chmod', ['755', fx.backups]);
        final again = await fx.cli(bk(['backups', '--delete', '20260101-000000-a']));
        expect(again.code, 0);
        expect(exists('20260101-000000-a'), isFalse);
      });
    }
  });

  test('help and restore hint mention the new options in both languages', () {
    for (final lang in ['en', 'ko']) {
      final m = Messages(lang);
      expect(m.t('help'), contains('--delete'));
      expect(m.t('help'), contains('--prune-older-than'));
      expect(m.t('restore.kept', {'dir': 'd', 'id': 'ID1'}), contains('worktree-shelve backups --delete ID1'));
    }
  });
}
