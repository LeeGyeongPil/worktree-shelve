/// 마운트 지점 목록.
///
/// 워크트리 안에 다른 디스크(디스크 이미지·네트워크 폴더 등)가 붙어 있으면 지우면 안 된다.
/// Linux 는 /proc/mounts, macOS 는 `mount` 출력을 읽는다. 테스트는 목록을 직접 넣는다.
library;

import 'dart:io';

/// 현재 시스템의 마운트 지점. 읽지 못하면 빈 목록(판정은 다른 규칙으로 계속 보수적이다).
List<String> readMountPoints() {
  try {
    final proc = File('/proc/mounts');
    if (proc.existsSync()) return parseProcMounts(proc.readAsStringSync());
    final r = Process.runSync('mount', const []);
    if (r.exitCode == 0) return parseMountOutput(r.stdout as String);
  } on Object {
    // 샌드박스 등에서 막히면 마운트 규칙만 건너뛴다.
  }
  return const [];
}

/// /proc/mounts: `장치 마운트지점 형식 옵션 0 0`, 공백은 \040 으로 이스케이프.
List<String> parseProcMounts(String text) {
  final points = <String>[];
  for (final line in text.split('\n')) {
    final parts = line.split(' ');
    if (parts.length < 2) continue;
    points.add(parts[1].replaceAllMapped(
        RegExp(r'\\([0-7]{3})'), (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 8))));
  }
  return points;
}

/// `mount` 출력: macOS `장치 on 경로 (옵션)`, Linux `장치 on 경로 type 형식 (옵션)`.
List<String> parseMountOutput(String text) {
  final re = RegExp(r'^.*? on (.+?)(?: type \S+)? \([^()]*\)$');
  final points = <String>[];
  for (final line in text.split('\n')) {
    final m = re.firstMatch(line.trim());
    if (m != null) points.add(m.group(1)!);
  }
  return points;
}

/// [dir] 안쪽(자기 자신 포함)에 있는 첫 마운트 지점. 없으면 null.
String? mountInside(String dir, List<String> mountPoints) {
  for (final mp in mountPoints) {
    if (mp == dir || mp.startsWith('$dir/')) return mp;
  }
  return null;
}
