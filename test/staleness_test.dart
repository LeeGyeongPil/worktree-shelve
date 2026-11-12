// AC-2: 오래됨 이중 판정(커밋 시각 + 파일 수정 시각).
import 'dart:io';

import 'package:test/test.dart';
import 'package:worktree_shelve/worktree_shelve.dart';

import 'support/fixture.dart';

void main() {
  late Fixture fx;
  setUp(() async => fx = await Fixture.create());
  tearDown(() => fx.dispose());

  test('old commit + edit 1h ago keeps (recent_edit); recent commit + old files keeps (recent_commit); both old is stale',
      () async {
    final repo = await fx.makeRepo('root/repo');
    // 커밋 30일 전 + 파일 1시간 전 수정
    final edited = await fx.addWorktree(repo, 'root/wt/edited', branch: 'edited');
    File('$edited/src/a.txt')
      ..writeAsStringSync('still editing\n')
      ..setLastModifiedSync(fx.now.subtract(const Duration(hours: 1)));
    // 커밋 1일 전 + 파일 30일 전
    await fx.addWorktree(repo, 'root/wt/committed', branch: 'committed', commitDaysAgo: 1);
    // 둘 다 30일 전
    await fx.addWorktree(repo, 'root/wt/old', branch: 'old');

    final run = await fx.cli(['scan', '--root', '${fx.base}/root', '--json']);
    expect(run.code, 0, reason: run.err);
    expect(Fixture.item(run.json, '/wt/edited')['reason'], 'recent_edit');
    expect(Fixture.item(run.json, '/wt/committed')['reason'], 'recent_commit');
    final old = Fixture.item(run.json, '/wt/old');
    expect(old['verdict'], 'remove');
    expect(old['reason'], 'stale_clean');
  });

  test('new files in node_modules or .git and outside symlinks do not count', () async {
    final repo = await fx.makeRepo('root/repo');
    final wt = await fx.addWorktree(repo, 'root/wt/deps', branch: 'deps');

    fx.b.write('$wt/node_modules/pkg/index.js', 'module.exports = 1;\n');

    // 저장소 밖 큰 파일·폴더를 가리키는 링크(무시 목록의 links/ 안) — 따라가지 않아야 한다.
    // 링크 대상은 방금 만든 것이라 시각이 "지금"이다.
    final outside = '${fx.base}/outside';
    fx.b.writeBytes('$outside/big.bin', List.filled(3 * 1024 * 1024, 7));
    Directory('$wt/links').createSync();
    Link('$wt/links/big-file').createSync('$outside/big.bin');
    Link('$wt/links/big-dir').createSync(outside);

    // 30일 전으로 돌린 뒤, 산출물 안에 새 파일을 만들고 .git 파일 시각을 지금으로 바꾼다.
    await fx.age(wt, 30);
    fx.b.write('$wt/node_modules/pkg/fresh.js', 'fresh\n');
    File('$wt/.git').setLastModifiedSync(fx.now);

    final activity = measureTree(wt);
    expect(activity.newestEdit!.isBefore(fx.daysAgo(29)), isTrue,
        reason: 'newest edit must ignore node_modules, .git and links');
    expect(activity.sizeBytes, lessThan(1024 * 1024), reason: 'links must not add the 3 MB target');
    // node_modules 는 지우면 돌아오는 용량이므로 크기에는 들어간다.
    expect(activity.sizeBytes, greaterThan(0));

    final run = await fx.cli(['scan', '--root', '${fx.base}/root', '--json']);
    final item = Fixture.item(run.json, '/wt/deps');
    expect(item['verdict'], 'remove', reason: '${item['reason']}');
    expect(item['size_bytes'] as int, lessThan(1024 * 1024));
  });

  test('a file with a future time counts as recent', () async {
    final repo = await fx.makeRepo('root/repo');
    final wt = await fx.addWorktree(repo, 'root/wt/future', branch: 'future');
    File('$wt/src/a.txt').setLastModifiedSync(fx.now.add(const Duration(days: 3)));
    final run = await fx.cli(['scan', '--root', '${fx.base}/root', '--json']);
    expect(Fixture.item(run.json, '/wt/future')['reason'], 'recent_edit');
  });
}
