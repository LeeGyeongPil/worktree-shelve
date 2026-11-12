/// `--log FILE`: 실행한 동작마다 JSON 한 줄을 파일 끝에 덧붙인다(JSON Lines).
///
/// 기존 줄은 절대 지우지 않는다(append 모드). 쓸 때마다 열고 닫아서 열린 파일을 남기지 않는다.
library;

import 'dart:convert';
import 'dart:io';

import 'errors.dart';

class ActionLog {
  ActionLog(this.path);

  final String path;

  /// 시작 전에 쓸 수 있는지 확인한다(부모 폴더가 없으면 만든다).
  void check() {
    try {
      final f = File(path);
      f.parent.createSync(recursive: true);
      f.openSync(mode: FileMode.append).closeSync();
    } on FileSystemException {
      throw ShelveError('err.log_unwritable', {'path': path});
    }
  }

  void append(Map<String, Object?> entry) {
    try {
      File(path).writeAsStringSync('${jsonEncode(entry)}\n', mode: FileMode.append, flush: true);
    } on FileSystemException {
      throw ShelveError('err.log_unwritable', {'path': path});
    }
  }
}
