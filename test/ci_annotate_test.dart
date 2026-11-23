// CI 주석 스크립트(tool/ci_annotate.dart): 실패한 테스트마다 이름·위치·Expected/Actual 이 담긴
// `::error` 줄이 하나씩 나오는지 본다. 입력은 `dart test --file-reporter json:…` 의 실제 이벤트 꼴.
import 'dart:convert';

import 'package:test/test.dart';

import '../tool/ci_annotate.dart';

const _url = 'file:///work/repo/test/x_test.dart';

String _e(Map<String, Object?> event) => jsonEncode(event);

List<String> _report() => [
      _e({'type': 'start', 'protocolVersion': '0.1.1'}),
      _e({
        'type': 'suite',
        'suite': {'id': 0, 'platform': 'vm', 'path': 'test/x_test.dart'}
      }),
      // 숨은 "loading" 테스트는 성공이면 무시된다.
      _e({
        'type': 'testStart',
        'test': {'id': 1, 'name': 'loading test/x_test.dart', 'suiteID': 0, 'line': null}
      }),
      _e({'type': 'testDone', 'testID': 1, 'result': 'success', 'skipped': false, 'hidden': true}),
      // expect 실패(failure).
      _e({
        'type': 'testStart',
        'test': {'id': 5, 'name': 'restore hint (en), with: comma', 'suiteID': 0, 'line': 5, 'url': _url}
      }),
      _e({
        'type': 'error',
        'testID': 5,
        'error': "Expected: contains 'x'\n  Actual: 'y'\n100% sure\n",
        'stackTrace': 'package:matcher  expect\ntest/x_test.dart 6:5  main.<fn>\n',
        'isFailure': true
      }),
      _e({'type': 'testDone', 'testID': 5, 'result': 'failure', 'skipped': false, 'hidden': false}),
      // 예외(error). 헬퍼 안에서 정의된 테스트는 root_line 이 테스트 파일 쪽 줄이다.
      _e({
        'type': 'testStart',
        'test': {'id': 7, 'name': 'grp throws', 'suiteID': 0, 'line': 3, 'root_line': 12, 'url': _url}
      }),
      _e({
        'type': 'error',
        'testID': 7,
        'error': 'Bad state: no worktree ending with /wt/en',
        'stackTrace': 'test/x_test.dart 13:7  main.<fn>.<fn>\n',
        'isFailure': false
      }),
      _e({'type': 'testDone', 'testID': 7, 'result': 'error', 'skipped': false, 'hidden': false}),
      // 통과·건너뜀은 주석을 내지 않는다.
      _e({
        'type': 'testStart',
        'test': {'id': 8, 'name': 'passes', 'suiteID': 0, 'line': 20, 'url': _url}
      }),
      _e({'type': 'testDone', 'testID': 8, 'result': 'success', 'skipped': false, 'hidden': false}),
      _e({
        'type': 'testStart',
        'test': {'id': 9, 'name': 'skipped', 'suiteID': 0, 'line': 22, 'url': _url}
      }),
      _e({'type': 'testDone', 'testID': 9, 'result': 'success', 'skipped': true, 'hidden': false}),
      'not json at all',
      _e({'type': 'done', 'success': false}),
    ];

void main() {
  test('one ::error line per failing test with name, file, line and message', () {
    final lines = annotations(_report());
    expect(lines, hasLength(2));
    // 쉼표·콜론은 속성 값 안에서, 줄바꿈·% 는 본문에서 GitHub 규칙대로 바뀐다.
    expect(
        lines[0],
        "::error title=restore hint (en)%2C with%3A comma,file=test/x_test.dart,line=5::"
        "Expected: contains 'x'%0A  Actual: 'y'%0A100%25 sure%0A"
        'package:matcher  expect%0Atest/x_test.dart 6:5  main.<fn>');
    expect(
        lines[1],
        '::error title=grp throws,file=test/x_test.dart,line=12::'
        'Bad state: no worktree ending with /wt/en%0Atest/x_test.dart 13:7  main.<fn>.<fn>');
    // 한 줄짜리 명령이어야 GitHub 이 주석으로 받는다.
    for (final l in lines) {
      expect(l, isNot(contains('\n')));
    }
  });

  test('a clean report gives no annotations', () {
    final ok = _report().where((l) => !l.contains('"testID":5') && !l.contains('"testID":7'));
    expect(annotations(ok), isEmpty);
  });

  test('long messages are cut and extra failures are summed up', () {
    final long = List.generate(100, (i) => 'line $i').join('\n');
    expect(shorten(long).split('\n'), hasLength(maxLines + 1));
    expect(shorten(long), endsWith('(truncated)'));

    final many = <String>[
      for (var i = 0; i < maxAnnotations + 3; i++) ...[
        _e({
          'type': 'testStart',
          'test': {'id': i, 'name': 't$i', 'suiteID': 0, 'line': i + 1}
        }),
        _e({'type': 'testDone', 'testID': i, 'result': 'error', 'skipped': false, 'hidden': false}),
      ]
    ];
    final lines = annotations(many);
    expect(lines, hasLength(maxAnnotations + 1));
    expect(lines.last, contains('3 more failing tests not shown'));
    // 파일을 모르면 file·line 없이 이름만 붙인다.
    expect(lines.first, '::error title=t0::test error without an error message');
  });
}
