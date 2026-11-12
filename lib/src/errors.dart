/// 사용자에게 한 줄로 보여 줄 오류.
///
/// 메시지 문구는 여기 두지 않고 [key] 와 [params] 만 들고 다닌다.
/// 실제 문장은 출력 직전에 i18n.dart 의 메시지 표에서 고른 언어로 만든다.
class ShelveError implements Exception {
  ShelveError(this.key, [this.params = const {}, this.exitCode = 2]);

  /// i18n 메시지 키 (예: `err.root_missing`).
  final String key;

  /// 메시지 안 `{name}` 자리에 들어갈 값.
  final Map<String, Object?> params;

  /// 0 정상, 1 일부 항목 실패, 2 사용법·환경 오류.
  final int exitCode;

  @override
  String toString() => 'ShelveError($key, $params)';
}
