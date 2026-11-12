/// `git worktree list --porcelain -z` 출력 파서.
///
/// -z 형식: 필드마다 NUL 로 끝나고, 레코드는 빈 필드(NUL 두 개 연속)로 끝난다.
/// 경로·잠금 사유에 줄바꿈이 있어도 안전하다(공식 문서 권장 형식).
library;

class WorktreeRecord {
  WorktreeRecord({
    required this.path,
    required this.head,
    this.branch,
    this.bare = false,
    this.detached = false,
    this.locked = false,
    this.lockReason,
    this.prunable = false,
    this.prunableReason,
  });

  final String path;
  final String head;

  /// `refs/heads/feat-a` 형태(분리 상태면 null).
  final String? branch;
  final bool bare;
  final bool detached;
  final bool locked;
  final String? lockReason;
  final bool prunable;
  final String? prunableReason;

  /// `feat-a` 처럼 짧은 브랜치 이름.
  String? get shortBranch =>
      branch == null ? null : branch!.startsWith('refs/heads/') ? branch!.substring(11) : branch;
}

List<WorktreeRecord> parsePorcelainZ(String output) {
  final records = <WorktreeRecord>[];
  var fields = <String, String?>{};

  void flush() {
    final path = fields['worktree'];
    if (path != null) {
      records.add(WorktreeRecord(
        path: path,
        head: fields['HEAD'] ?? '',
        branch: fields['branch'],
        bare: fields.containsKey('bare'),
        detached: fields.containsKey('detached'),
        locked: fields.containsKey('locked'),
        lockReason: _nonEmpty(fields['locked']),
        prunable: fields.containsKey('prunable'),
        prunableReason: _nonEmpty(fields['prunable']),
      ));
    }
    fields = {};
  }

  for (final field in output.split('\x00')) {
    if (field.isEmpty) {
      // 빈 필드 = 레코드 끝.
      flush();
      continue;
    }
    final space = field.indexOf(' ');
    if (space < 0) {
      fields[field] = null; // 값 없는 라벨(bare, detached, locked …)
    } else {
      fields[field.substring(0, space)] = field.substring(space + 1);
    }
  }
  flush();
  return records;
}

String? _nonEmpty(String? s) => (s == null || s.isEmpty) ? null : s;
