// worktree-shelve 진입점.
//
// runCli 가 오류를 한 줄로 바꿔 주지만, 출력 파이프가 끊기는 등 바깥에서 터지는 예외까지
// 트레이스백 없이 끝나도록 한 번 더 감싼다.
import 'dart:async';
import 'dart:io';

import 'package:worktree_shelve/worktree_shelve.dart';

Future<void> main(List<String> args) async {
  // `worktree-shelve scan | head` 처럼 읽는 쪽이 먼저 닫혀도 조용히 끝낸다.
  unawaited(stdout.done.catchError((Object _) {}));
  var code = 2;
  await runZonedGuarded(() async {
    code = await runCli(args, CliContext.fromPlatform());
  }, (error, _) {
    stderr.writeln('error: $error'.split('\n').first);
    code = 2;
  });
  try {
    await stdout.flush();
  } on Object {
    // 출력이 이미 닫힌 경우
  }
  exit(code);
}
