// CI 전용: `dart test --file-reporter json:<파일>` 결과에서 실패한 테스트마다
// GitHub Actions 오류 주석(`::error title=<테스트 이름>,file=…,line=…::<오류 요약>`)을 한 줄씩 낸다.
//
// 왜 필요한가: Actions 에서 dart test 가 고르는 github 리포터는 실패한 테스트 이름과
// Expected/Actual 을 로그 안 묶음으로만 남기고, 주석에는 "N tests passed, 1 failed." 한 줄만 올린다.
// 로그는 로그인해야 읽을 수 있지만 주석은 공개 check-run API 로 누구나 읽을 수 있다.
//
// 사용: dart run tool/ci_annotate.dart <report.json>
// 새 의존성 없이 dart:convert·dart:io 만 쓴다. 보고서가 없어도 실패로 끝내지 않는다(주석만 하나 남긴다).
import 'dart:convert';
import 'dart:io';

/// 주석 한 건에 담을 오류 본문의 최대 줄 수·글자 수(긴 diff 는 앞부분만).
const maxLines = 30;
const maxChars = 4000;

/// 오류마다 덧붙일 스택 줄 수.
const stackLines = 8;

/// GitHub 은 한 단계에서 오류 주석을 10개까지만 보여 준다.
const maxAnnotations = 10;

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('usage: dart run tool/ci_annotate.dart <report.json>');
    exitCode = 64;
    return;
  }
  final file = File(args.single);
  if (!file.existsSync()) {
    // 테스트가 시작도 못 했으면(컴파일 오류 등) 보고서가 없다 — 그 사실만 알린다.
    stdout.writeln(workflowCommand('warning', 'no test report at ${file.path}',
        {'title': 'dart test report missing'}));
    return;
  }
  for (final line in annotations(file.readAsLinesSync())) {
    stdout.writeln(line);
  }
}

/// 한 실패의 요약.
class Failure {
  Failure(this.name, this.file, this.line, this.result);

  final String name;
  final String? file;
  final int? line;
  final String result; // failure | error
  final errors = <String>[];
}

/// JSON 리포터 줄들 → `::error …` 주석 줄들(실패한 테스트 순서대로).
List<String> annotations(Iterable<String> reportLines) {
  final suitePath = <int, String>{}; // suiteID → test/xxx_test.dart
  final started = <int, Map<String, Object?>>{}; // testID → testStart 의 test 객체
  final errors = <int, List<String>>{}; // testID → error 이벤트의 오류 문장들
  final failed = <Failure>[];

  for (final raw in reportLines) {
    if (raw.trim().isEmpty) continue;
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      continue; // 리포터 줄이 아니면 건너뛴다
    }
    if (decoded is! Map<String, Object?>) continue;
    final event = decoded;
    switch (event['type']) {
      case 'suite':
        final suite = event['suite'];
        if (suite is Map<String, Object?> && suite['id'] is int && suite['path'] is String) {
          suitePath[suite['id'] as int] = suite['path'] as String;
        }
      case 'testStart':
        final test = event['test'];
        if (test is Map<String, Object?> && test['id'] is int) started[test['id'] as int] = test;
      case 'error':
        final id = event['testID'];
        if (id is! int) continue;
        // 오류 문장 + 스택 앞 몇 줄(예외가 lib 의 어느 줄에서 났는지 보이게).
        final stack = '${event['stackTrace'] ?? ''}'.trim().split('\n').take(stackLines).join('\n');
        final message = '${event['error'] ?? ''}'.trimRight();
        (errors[id] ??= []).add(stack.isEmpty ? message : '$message\n$stack');
      case 'testDone':
        final id = event['testID'];
        final result = event['result'];
        // success 가 아닌 것(failure: expect 실패, error: 예외·시간 초과)만 모은다.
        if (id is! int || result == 'success' || event['skipped'] == true) continue;
        final test = started[id] ?? const <String, Object?>{};
        final suiteId = test['suiteID'];
        // 테스트를 정의한 줄: 헬퍼 안에서 정의됐으면 root_line 이 테스트 파일 쪽 줄이다.
        final line = (test['root_line'] ?? test['line']) as int?;
        final f = Failure('${test['name'] ?? 'test #$id'}', suitePath[suiteId], line, '$result');
        f.errors.addAll(errors[id] ?? const []);
        failed.add(f);
    }
  }

  final out = <String>[];
  for (final f in failed.take(maxAnnotations)) {
    final body = f.errors.isEmpty ? 'test ${f.result} without an error message' : f.errors.join('\n\n');
    out.add(workflowCommand('error', shorten(body), {
      'title': f.name,
      if (f.file != null) 'file': f.file!,
      if (f.file != null && f.line != null) 'line': '${f.line}',
    }));
  }
  if (failed.length > maxAnnotations) {
    out.add(workflowCommand('error', '${failed.length - maxAnnotations} more failing tests not shown',
        {'title': 'more failures'}));
  }
  return out;
}

/// 긴 오류는 앞쪽 [maxLines] 줄·[maxChars] 글자만 남긴다.
String shorten(String text) {
  var lines = text.trimRight().split('\n');
  var cut = false;
  if (lines.length > maxLines) {
    lines = lines.sublist(0, maxLines);
    cut = true;
  }
  var s = lines.join('\n');
  if (s.length > maxChars) {
    s = s.substring(0, maxChars);
    cut = true;
  }
  return cut ? '$s\n…(truncated)' : s;
}

/// `::<cmd> k=v,k=v::<message>` 한 줄. 값의 줄바꿈·%·쉼표·콜론은 GitHub 규칙대로 바꾼다.
String workflowCommand(String cmd, String message, Map<String, String> props) {
  String data(String s) => s.replaceAll('%', '%25').replaceAll('\r', '%0D').replaceAll('\n', '%0A');
  String prop(String s) => data(s).replaceAll(':', '%3A').replaceAll(',', '%2C');
  final p = props.entries.map((e) => '${e.key}=${prop(e.value)}').join(',');
  return '::$cmd${p.isEmpty ? '' : ' $p'}::${data(message)}';
}
