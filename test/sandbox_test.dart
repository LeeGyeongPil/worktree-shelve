// AC-10 보조: sandbox 명령이 연습 저장소를 만들고 미리보기를 보여 준다(실제 명령 검증은 build-report 참고).
import 'dart:io';

import 'package:test/test.dart';
import 'package:worktree_shelve/worktree_shelve.dart';

import 'support/fixture.dart';

void main() {
  late Fixture fx;
  setUp(() async => fx = await Fixture.create());
  tearDown(() => fx.dispose());

  test('sandbox prints the verdict table and the reclaim total', () async {
    final run = await fx.cli(['sandbox', 'practice']);
    expect(run.code, 0, reason: run.err);
    expect(run.out, contains('shelve'));
    expect(run.out, contains('prune'));
    expect(run.out, contains('Would reclaim'));
    expect(run.out, contains('back-dated'), reason: 'must say the dates are artificial');
    expect(File('${fx.base}/practice/$sandboxMarker').existsSync(), isTrue);

    // 다시 실행하면 표지 파일이 있으므로 새로 만든다.
    final again = await fx.cli(['sandbox', 'practice']);
    expect(again.code, 0, reason: again.err);
  });

  test('sandbox refuses a non-empty folder that is not a sandbox', () async {
    File('${fx.base}/mine/keep.txt')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('mine');
    final run = await fx.cli(['sandbox', 'mine']);
    expect(run.code, 2);
    expect(run.errLines, hasLength(1));
    expect(File('${fx.base}/mine/keep.txt').readAsStringSync(), 'mine');
  });

  test('sandbox speaks Korean with --lang ko', () async {
    final run = await fx.cli(['sandbox', 'practice-ko', '--lang', 'ko']);
    expect(run.code, 0, reason: run.err);
    expect(run.out, contains('회수 예상'));
    expect(run.out, contains('백업 후 제거'));
  });
}
