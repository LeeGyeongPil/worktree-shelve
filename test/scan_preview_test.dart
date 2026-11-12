// AC-1: 기본 scan 은 미리보기만 한다. 판정 6개가 맞고, 실행 전후 git 기록과 폴더가 같다.
import 'package:test/test.dart';
import 'package:worktree_shelve/worktree_shelve.dart';

import 'support/fixture.dart';

void main() {
  late Fixture fx;
  setUp(() async => fx = await Fixture.create());
  tearDown(() => fx.dispose());

  test('preview gives the six expected verdicts and changes nothing', () async {
    final sb = '${fx.base}/sb';
    await buildSandbox(sb, fx.git, fx.now);
    final repo = '$sb/demo-app';

    final porcelainBefore = await fx.porcelain(repo);
    final filesBefore = fx.listing(sb);

    final run = await fx.cli(['scan', '--root', sb, '--json']);
    expect(run.code, 0, reason: run.err);
    final json = run.json;
    expect(json['applied'], false);

    String verdict(String suffix) {
      final w = Fixture.item(json, suffix);
      return '${w['verdict']}(${w['reason']})';
    }

    expect(verdict('/demo-app'), 'keep(main)');
    expect(verdict('/worktrees/old-clean'), 'remove(stale_clean)');
    expect(verdict('/worktrees/old-dirty'), 'shelve(stale_dirty)');
    expect(verdict('/worktrees/recent-edit'), 'keep(recent_edit)');
    expect(verdict('/worktrees/agent-run'), 'keep(locked)');
    expect(verdict('/worktrees/gone'), 'prune(missing_dir)');
    expect((json['worktrees'] as List).length, 6);

    // 출력 순서는 OS 와 무관하다: 메인 먼저, 나머지는 경로순(git 의 나열 순서에 기대지 않는다).
    final paths = (json['worktrees'] as List<Object?>)
        .cast<Map<String, Object?>>()
        .map((w) => w['path'] as String)
        .toList();
    expect(paths.first, endsWith('/demo-app'));
    expect(paths.skip(1).toList(), [...paths.skip(1)]..sort());

    // 미리보기 표도 한 번 더 돌려 본다(역시 아무것도 바꾸지 않아야 한다).
    final table = await fx.cli(['scan', '--root', sb]);
    expect(table.code, 0);
    expect(table.out, contains('Would reclaim'));
    expect(table.out, contains('Preview only'));

    expect(await fx.porcelain(repo), porcelainBefore);
    expect(fx.listing(sb), filesBefore);
  });
}
