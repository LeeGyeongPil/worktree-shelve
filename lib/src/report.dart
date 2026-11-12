/// 출력 모양: 표·크기 단위·경로 줄이기·JSON·오류 문장.
library;

import 'errors.dart';
import 'i18n.dart';
import 'verdict.dart';

/// 1024 단위 크기 표기(B, KB, MB, GB, TB).
String formatSize(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return unit == 0 ? '$bytes B' : '${value.toStringAsFixed(1)} ${units[unit]}';
}

/// 기간을 "3d" / "3일" 처럼 짧게.
String formatAge(Duration d, Messages m) {
  if (d.inDays >= 1) return m.t('age.d', {'n': d.inDays});
  if (d.inHours >= 1) return m.t('age.h', {'n': d.inHours});
  return m.t('age.m', {'n': d.inMinutes < 0 ? 0 : d.inMinutes});
}

/// 표에 보일 경로: --root 안이면 상대 경로, 홈 안이면 `~/…`, 아니면 그대로.
String displayPath(String path, {String? root, String? home}) {
  if (root != null) {
    if (path == root) return '.';
    final r = root.endsWith('/') ? root : '$root/';
    if (path.startsWith(r)) return path.substring(r.length);
  }
  if (home != null && home.isNotEmpty && home != '/') {
    if (path == home) return '~';
    if (path.startsWith('$home/')) return '~/${path.substring(home.length + 1)}';
  }
  return path;
}

/// 오류 문장. 매개변수 안에 또 다른 [ShelveError] 나 메시지 키가 있으면 같은 언어로 풀어 쓴다.
String describe(ShelveError e, Messages m) {
  final params = <String, Object?>{};
  e.params.forEach((k, v) {
    if (v is ShelveError) {
      params[k] = describe(v, m);
    } else if (v is String && (v.startsWith('restore.step.') || v.startsWith('fail.'))) {
      params[k] = m.t(v);
    } else {
      params[k] = v;
    }
  });
  // 한 줄 보장: 혹시 섞여 들어온 줄바꿈은 공백으로.
  return m.t(e.key, params).replaceAll(RegExp(r'[\r\n]+'), ' ');
}

/// `error: …` / `오류: …` 한 줄.
String errorLine(ShelveError e, Messages m) => '${m.t('err.prefix')}: ${describe(e, m)}';

/// 판정 이유 문장.
String reasonText(Assessment a, Messages m) {
  final p = a.reasonParams;
  switch (a.reason) {
    case 'locked':
      return p['why'] == null ? m.t('reason.locked_plain') : m.t('reason.locked', {'why': p['why']});
    case 'recent_commit':
    case 'recent_edit':
    case 'stale_clean':
    case 'stale_dirty':
      return m.t('reason.${a.reason}', {
        'age': formatAge(p['age'] as Duration, m),
        'n': p['n'],
      });
    case 'ignored_too_large':
      return m.t('reason.ignored_too_large',
          {'size': formatSize(p['size'] as int), 'cap': formatSize(p['cap'] as int)});
    default:
      return m.t('reason.${a.reason}', p);
  }
}

/// 터미널에서 한글·한자는 두 칸을 차지한다 — 열을 맞추려고 폭을 따로 센다.
int displayWidth(String s) {
  var w = 0;
  for (final r in s.runes) {
    final wide = (r >= 0x1100 && r <= 0x115F) ||
        (r >= 0x2E80 && r <= 0xA4CF) ||
        (r >= 0xAC00 && r <= 0xD7A3) ||
        (r >= 0xF900 && r <= 0xFAFF) ||
        (r >= 0xFF00 && r <= 0xFF60);
    w += wide ? 2 : 1;
  }
  return w;
}

/// 간단한 텍스트 표. 마지막 열은 오른쪽 정렬(크기).
String renderTable(List<String> headers, List<List<String>> rows, {bool alignLastRight = true}) {
  final widths = List<int>.generate(headers.length, (i) => displayWidth(headers[i]));
  for (final row in rows) {
    for (var i = 0; i < row.length; i++) {
      final w = displayWidth(row[i]);
      if (w > widths[i]) widths[i] = w;
    }
  }
  String line(List<String> cells) {
    final parts = <String>[];
    for (var i = 0; i < cells.length; i++) {
      final pad = ' ' * (widths[i] - displayWidth(cells[i]));
      final last = i == cells.length - 1;
      parts.add(last && alignLastRight ? '$pad${cells[i]}' : '${cells[i]}$pad');
    }
    return parts.join('  ').trimRight();
  }

  return [line(headers), ...rows.map(line)].join('\n');
}

/// scan 결과를 JSON 으로(경로는 절대 경로 — 기계용).
Map<String, Object?> assessmentJson(Assessment a, Messages m) => {
      'repo': a.repo,
      'path': a.path,
      'branch': a.record.shortBranch,
      'head': a.record.head,
      'detached': a.record.detached,
      'locked': a.record.locked,
      'verdict': a.verdict.name,
      'reason': a.reason,
      'reason_text': reasonText(a, m),
      'size_bytes': a.sizeBytes,
      'last_commit': a.lastCommit?.toUtc().toIso8601String(),
      'newest_edit': a.newestEdit?.toUtc().toIso8601String(),
      'changed_files': a.changedFiles,
      'ignored_bytes': a.ignoredBytes,
      'backup_id': a.backupId,
      'pinned_ref': a.pinnedRef,
      'result': a.result,
      'restore_command': a.restoreCommand,
      'error': a.failure == null ? null : describe(a.failure!, m),
    };
