/// 명령줄: 인자 해석 → 하위 명령(scan·restore·backups·sandbox) 실행 → 종료 코드.
///
/// [runCli] 는 모든 오류를 잡아 `error: …` 한 줄로 바꾼다(트레이스백 없음).
/// 테스트는 [CliContext] 로 환경 변수·현재 폴더·출력·마운트 표를 바꿔 끼워 같은 함수를 부른다.
library;

import 'dart:convert';
import 'dart:io';

import 'apply.dart';
import 'backup.dart' show isGeneratedBackupId, isValidBackupId;
import 'discover.dart';
import 'errors.dart';
import 'git.dart';
import 'i18n.dart';
import 'log.dart';
import 'mounts.dart';
import 'report.dart';
import 'restore.dart';
import 'sandbox.dart';
import 'verdict.dart';

const toolVersion = '0.2.0';

class CliContext {
  CliContext({
    required this.env,
    required this.cwd,
    required this.out,
    required this.err,
    this.mountPoints,
    DateTime Function()? now,
    this.beforeVerify,
    this.beforeRemove,
  }) : now = now ?? DateTime.now;

  /// 실제 프로그램용(현재 프로세스의 환경·폴더·표준 출력).
  factory CliContext.fromPlatform() => CliContext(
        env: Map.of(Platform.environment),
        cwd: Directory.current.path,
        out: stdout,
        err: stderr,
      );

  final Map<String, String> env;
  final String cwd;
  final StringSink out;
  final StringSink err;

  /// null 이면 시스템에서 읽는다. 테스트는 직접 넣는다.
  final List<String>? mountPoints;
  final DateTime Function() now;

  /// 테스트용: 백업 묶음 검증 직전에 불린다.
  final void Function(String stagingDir)? beforeVerify;

  /// 테스트용: 마지막 확인이 끝난 뒤 `git worktree remove` 직전에 불린다(제거 도중 실패 재현).
  final void Function(String worktreePath)? beforeRemove;
}

/// 프로그램 본체. 무슨 일이 있어도 예외를 밖으로 던지지 않고 종료 코드를 돌려준다.
Future<int> runCli(List<String> args, CliContext ctx) async {
  final m = Messages(resolveLang(_peekLang(args), ctx.env));
  try {
    return await _dispatch(args, ctx, m);
  } on ShelveError catch (e) {
    ctx.err.writeln(errorLine(e, m));
    return e.exitCode;
  } on FileSystemException catch (e) {
    ctx.err.writeln(errorLine(
        ShelveError('err.fs', {'path': e.path ?? '-', 'why': e.osError?.message ?? e.message}), m));
    return 2;
  } on ProcessException catch (e) {
    ctx.err.writeln(errorLine(ShelveError('err.unexpected', {'why': e.message}), m));
    return 2;
  } catch (e) {
    ctx.err.writeln(errorLine(ShelveError('err.unexpected', {'why': e.toString()}), m));
    return 2;
  }
}

/// 언어는 인자 해석보다 먼저 정해야 한다(인자 오류도 그 언어로 보여 주려고).
String? _peekLang(List<String> args) {
  for (var i = 0; i < args.length; i++) {
    String? v;
    if (args[i] == '--lang' && i + 1 < args.length) v = args[i + 1];
    if (args[i].startsWith('--lang=')) v = args[i].substring(7);
    if (v == 'en' || v == 'ko') return v;
  }
  return null;
}

/// 손으로 쓴 작은 인자 파서.
class _Args {
  final Map<String, String> values = {};
  final Set<String> flags = {};
  final List<String> positional = [];
}

_Args _parse(String cmd, List<String> args,
    {Set<String> valueOpts = const {}, Set<String> flagOpts = const {}}) {
  final valid = {...valueOpts, '--lang'};
  final parsed = _Args();
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a.startsWith('--')) {
      final eq = a.indexOf('=');
      final name = eq < 0 ? a : a.substring(0, eq);
      if (flagOpts.contains(name) && eq < 0) {
        parsed.flags.add(name);
      } else if (valid.contains(name)) {
        String value;
        if (eq >= 0) {
          value = a.substring(eq + 1);
        } else {
          if (i + 1 >= args.length) throw ShelveError('err.missing_value', {'opt': name});
          value = args[++i];
        }
        if (value.isEmpty) throw ShelveError('err.missing_value', {'opt': name});
        parsed.values[name] = value;
      } else {
        throw ShelveError('err.unknown_option', {'cmd': cmd, 'opt': name});
      }
    } else if (a.startsWith('-') && a.length > 1) {
      throw ShelveError('err.unknown_option', {'cmd': cmd, 'opt': a});
    } else {
      parsed.positional.add(a);
    }
  }
  final lang = parsed.values['--lang'];
  if (lang != null && lang != 'en' && lang != 'ko') {
    throw ShelveError('err.bad_lang', {'value': lang});
  }
  return parsed;
}

int _int(_Args p, String opt, int fallback, int min) {
  final raw = p.values[opt];
  if (raw == null) return fallback;
  final v = int.tryParse(raw);
  if (v == null || v < min) throw ShelveError('err.bad_number', {'opt': opt, 'min': min, 'value': raw});
  return v;
}

/// 상대 경로는 실행 위치 기준 절대 경로로.
String _abs(String path, CliContext ctx) {
  var p = path;
  final home = ctx.env['HOME'];
  if (home != null && (p == '~' || p.startsWith('~/'))) p = home + p.substring(1);
  if (!p.startsWith('/')) p = '${ctx.cwd}/$p';
  // 끝의 / 와 ./ 정리.
  final parts = <String>[];
  for (final s in p.split('/')) {
    if (s.isEmpty || s == '.') continue;
    if (s == '..') {
      if (parts.isNotEmpty) parts.removeLast();
      continue;
    }
    parts.add(s);
  }
  return '/${parts.join('/')}';
}

Future<int> _dispatch(List<String> args, CliContext ctx, Messages m) async {
  if (args.isEmpty || args.contains('--help') || args.contains('-h') || args.first == 'help') {
    ctx.out.writeln(m.t('help'));
    return 0;
  }
  if (args.contains('--version')) {
    ctx.out.writeln('worktree-shelve $toolVersion');
    return 0;
  }
  // 첫 인자가 옵션이면 scan 으로 본다(`worktree-shelve --root ~/code`).
  final cmd = args.first.startsWith('-') ? 'scan' : args.first;
  final rest = args.first.startsWith('-') ? args : args.sublist(1);
  switch (cmd) {
    case 'scan':
      return _scan(rest, ctx, m);
    case 'restore':
      return _restore(rest, ctx, m);
    case 'backups':
      return _backups(rest, ctx, m);
    case 'sandbox':
      return _sandbox(rest, ctx, m);
    default:
      throw ShelveError('err.unknown_command', {'cmd': cmd});
  }
}

// ---------------------------------------------------------------- 백업 폴더

/// 백업 위치: --backup-dir > WORKTREE_SHELVE_BACKUP_DIR > $XDG_STATE_HOME/… > ~/.local/state/…
String _backupRoot(_Args p, CliContext ctx) {
  final flag = p.values['--backup-dir'];
  if (flag != null) return _abs(flag, ctx);
  final env = ctx.env['WORKTREE_SHELVE_BACKUP_DIR'];
  if (env != null && env.isNotEmpty) return _abs(env, ctx);
  final xdg = ctx.env['XDG_STATE_HOME'];
  if (xdg != null && xdg.isNotEmpty) return '${_abs(xdg, ctx)}/worktree-shelve/backups';
  final home = ctx.env['HOME'];
  if (home == null || home.isEmpty) throw ShelveError('err.backup_dir_no_home');
  return '$home/.local/state/worktree-shelve/backups';
}

/// --apply 시작 전에 백업 폴더를 만들고 실제로 써 본다. 안 되면 아무것도 하지 않고 종료 코드 2.
void _ensureWritable(String dir) {
  try {
    Directory(dir).createSync(recursive: true);
    final probe = File('$dir/.write-check-$pid');
    probe.writeAsStringSync('ok', flush: true);
    probe.deleteSync();
  } on FileSystemException {
    throw ShelveError('err.backup_dir_unwritable', {'path': dir});
  }
}

String _restoreHint(String id, _Args p, CliContext ctx) {
  final custom = p.values['--backup-dir'];
  return custom == null
      ? 'worktree-shelve restore $id'
      : 'worktree-shelve restore $id --backup-dir ${_abs(custom, ctx)}';
}

// ---------------------------------------------------------------- scan

Future<int> _scan(List<String> args, CliContext ctx, Messages m,
    {String? forcedRoot, bool sandboxNote = false}) async {
  final p = _parse('scan', args,
      valueOpts: {'--root', '--days', '--log', '--backup-dir', '--ignored-cap'},
      flagOpts: {'--apply', '--json'});
  if (p.positional.isNotEmpty) {
    throw ShelveError('err.extra_arg', {'cmd': 'scan', 'arg': p.positional.first});
  }
  final days = _int(p, '--days', 7, 1);
  final capMb = _int(p, '--ignored-cap', 100, 0);
  final apply = p.flags.contains('--apply');
  final asJson = p.flags.contains('--json');

  // --root 확인(없거나 파일이면 한 줄 오류).
  final rootArg = forcedRoot ?? _abs(p.values['--root'] ?? ctx.cwd, ctx);
  final rootType = FileSystemEntity.typeSync(rootArg);
  if (rootType == FileSystemEntityType.notFound) {
    throw ShelveError('err.root_missing', {'path': p.values['--root'] ?? rootArg});
  }
  if (rootType != FileSystemEntityType.directory) {
    throw ShelveError('err.root_not_dir', {'path': p.values['--root'] ?? rootArg});
  }
  final root = canonicalPath(rootArg);
  final git = await Git.locate(ctx.env);

  // 실행 모드면 시작 전에 백업 폴더·tar·로그를 점검한다 — 중간에 실패해 반쯤 지우는 일이 없게.
  String? backupRoot;
  Tar? tar;
  RemovalCheck? removal;
  ActionLog? log;
  if (apply) {
    backupRoot = _backupRoot(p, ctx);
    _ensureWritable(backupRoot);
    tar = Tar.locate(ctx.env);
    removal = await RemovalCheck.locate(ctx.env);
    final logPath = p.values['--log'];
    if (logPath != null) log = ActionLog(_abs(logPath, ctx))..check();
  }

  final now = ctx.now();
  final opt = ScanOptions(
    root: root,
    cwd: canonicalPath(ctx.cwd),
    days: days,
    ignoredCapBytes: capMb * 1024 * 1024,
    mountPoints: ctx.mountPoints ?? readMountPoints(),
    now: now,
  );
  final items = <Assessment>[];
  for (final repo in discoverRepos(root)) {
    items.addAll(await assessRepo(git, canonicalPath(repo), opt));
  }

  if (apply) {
    await applyAll(
        items,
        ApplyContext(
          git: git,
          tar: tar!,
          removal: removal!,
          backupRoot: backupRoot!,
          toolVersion: toolVersion,
          now: now,
          restoreCommand: (id) => _restoreHint(id, p, ctx),
          newPathPlaceholder: m.t('hint.new_path'),
          describeError: (e) => describe(e, m),
          describeReason: (a) => reasonText(a, m),
          log: log,
          beforeVerify: ctx.beforeVerify,
          beforeRemove: ctx.beforeRemove,
        ));
  }

  final failed = items.where((a) => a.result == 'failed').toList();
  final home = ctx.env['HOME'];

  // 실패한 항목은 stderr 에 한 줄씩. 무엇이 남았는지를 사실대로 적는다.
  for (final a in failed) {
    final failure = a.failure!;
    final shown = displayPath(a.path, root: root, home: home);
    // 원인에 맞는 다음 행동을 고른다(제거 실패에 "권한·--backup-dir" 안내를 붙이지 않게).
    final fix = switch (failure.key) {
      'fail.changed' || 'fail.blind_spot' || 'fail.not_removable' || 'fail.parent_not_removable' => 'fix.retry',
      'fail.remove' => 'fix.remove',
      _ => 'fix.permissions',
    };
    final ShelveError line;
    if (failure.key == 'fail.remove_partial') {
      // git 이 기록을 지웠고 폴더 일부가 지워졌을 수 있다 — 다음 scan 에는 안 보이므로 여기서 복원 방법을 다 알려 준다.
      line = ShelveError('item.partial', {
        'path': shown,
        'why': failure,
        'id': a.backupId,
        'cmd': a.restoreCommand,
        'abs': displayPath(a.path, home: home),
      });
    } else if (failure.key == 'fail.remove' && a.backupId != null) {
      // git 이 실패했지만 아직 기록이 있다 — 대개 아무것도 안 지웠지만 장담할 수 없어 백업을 남겨 두었다.
      line = ShelveError('item.remove_failed', {
        'path': shown,
        'why': failure,
        'id': a.backupId,
        'cmd': a.restoreCommand,
        'fix': m.t(fix),
      });
    } else {
      // git 을 부르기 전에 멈췄다 — 아무것도 지우지 않았다.
      line = ShelveError('item.failed', {'path': shown, 'why': failure, 'fix': m.t(fix)});
    }
    ctx.err.writeln(errorLine(line, m));
  }

  if (asJson) {
    _printScanJson(items, ctx, m, root: root, days: days, applied: apply);
  } else {
    _printScanTable(items, ctx, m,
        root: root, apply: apply, backupRoot: backupRoot, sandboxNote: sandboxNote);
  }
  return failed.isEmpty ? 0 : 1;
}

int _reclaim(Iterable<Assessment> items) => items
    .where((a) => a.verdict == Verdict.remove || a.verdict == Verdict.shelve)
    .fold(0, (sum, a) => sum + (a.sizeBytes ?? 0));

void _printScanJson(List<Assessment> items, CliContext ctx, Messages m,
    {required String root, required int days, required bool applied}) {
  final done = applied ? items.where((a) => a.result == 'ok') : items;
  int count(Verdict v) => items.where((a) => a.verdict == v).length;
  final data = {
    'tool': 'worktree-shelve',
    'version': toolVersion,
    'root': root,
    'days': days,
    'applied': applied,
    'worktrees': [for (final a in items) assessmentJson(a, m)],
    'totals': {
      'reclaim_bytes': _reclaim(done),
      'keep': count(Verdict.keep),
      'remove': count(Verdict.remove),
      'shelve': count(Verdict.shelve),
      'prune': count(Verdict.prune),
      'failed': items.where((a) => a.result == 'failed').length,
    },
  };
  ctx.out.writeln(const JsonEncoder.withIndent('  ').convert(data));
}

void _printScanTable(List<Assessment> items, CliContext ctx, Messages m,
    {required String root, required bool apply, String? backupRoot, bool sandboxNote = false}) {
  final home = ctx.env['HOME'];
  if (sandboxNote) ctx.out.writeln(m.t('scan.sandbox_note'));
  if (items.isEmpty) {
    ctx.out.writeln(m.t('scan.no_repos', {'root': displayPath(root, home: home)}));
    return;
  }
  final rows = [
    for (final a in items)
      [
        displayPath(a.repo, root: root, home: home),
        displayPath(a.path, root: root, home: home),
        a.record.shortBranch ?? m.t('branch.detached'),
        m.t('verdict.${a.verdict.name}'),
        reasonText(a, m),
        a.sizeBytes == null ? '-' : formatSize(a.sizeBytes!),
      ]
  ];
  ctx.out.writeln(renderTable([
    m.t('col.repo'),
    m.t('col.worktree'),
    m.t('col.branch'),
    m.t('col.verdict'),
    m.t('col.why'),
    m.t('col.size'),
  ], rows));
  ctx.out.writeln();

  if (!apply) {
    final acting = items.where((a) => a.verdict == Verdict.remove || a.verdict == Verdict.shelve);
    ctx.out.writeln(m.t('scan.summary', {
      'size': formatSize(_reclaim(items)),
      'n': acting.length,
      'p': items.where((a) => a.verdict == Verdict.prune).length,
    }));
    return;
  }

  // 실행 결과: 줄마다 무엇을 했고, 어떻게 되살리는지.
  for (final a in items.where((a) => a.acts)) {
    final path = displayPath(a.path, root: root, home: home);
    if (a.result != 'ok') {
      ctx.out.writeln(m.t('apply.failed', {'path': path}));
      // git 이 도중에 실패한 항목만 복원 명령이 있다(백업이 남아 있다).
      if (a.restoreCommand != null) ctx.out.writeln(m.t('apply.restore', {'cmd': a.restoreCommand}));
      continue;
    }
    final key = switch (a.verdict) {
      Verdict.shelve => 'apply.shelved',
      Verdict.remove => 'apply.removed',
      _ => 'apply.pruned',
    };
    ctx.out.writeln(m.t(key, {'path': path, 'id': a.backupId}));
    if (a.pinnedRef != null) {
      ctx.out.writeln(m.t('apply.pinned', {'sha': a.record.head.substring(0, 12), 'ref': a.pinnedRef}));
    }
    if (a.restoreCommand != null) ctx.out.writeln(m.t('apply.restore', {'cmd': a.restoreCommand}));
  }
  final ok = items.where((a) => a.result == 'ok');
  ctx.out.writeln(m.t(items.any((a) => a.backupId != null) ? 'apply.summary' : 'apply.summary_no_backup', {
    'size': formatSize(_reclaim(ok)),
    'n': ok.where((a) => a.verdict != Verdict.prune).length,
    'p': ok.where((a) => a.verdict == Verdict.prune).length,
    'f': items.where((a) => a.result == 'failed').length,
    'dir': displayPath(backupRoot ?? '-', home: home),
  }));
}

// ---------------------------------------------------------------- restore

Future<int> _restore(List<String> args, CliContext ctx, Messages m) async {
  final p = _parse('restore', args, valueOpts: {'--to', '--backup-dir'});
  if (p.positional.isEmpty) throw ShelveError('err.missing_id');
  if (p.positional.length > 1) {
    throw ShelveError('err.extra_arg', {'cmd': 'restore', 'arg': p.positional[1]});
  }
  final id = p.positional.first;
  final backupRoot = _backupRoot(p, ctx);
  // ID·백업 존재는 git 을 찾기 전에 확인한다(가장 흔한 실수를 먼저 알려 준다).
  try {
    readManifest(backupRoot, id);
  } on ShelveError catch (e) {
    throw ShelveError(e.key, {...e.params, 'list': _listHint(p, ctx)}, e.exitCode);
  }
  final git = await Git.locate(ctx.env);
  final tar = Tar.locate(ctx.env);
  final to = p.values['--to'];
  final r = await restoreBackup(
      git: git, tar: tar, backupRoot: backupRoot, id: id, to: to == null ? null : _abs(to, ctx));
  final home = ctx.env['HOME'];
  // 실행 위치 안이면 상대 경로로 짧게 보여 준다.
  final shown = displayPath(r.path, root: canonicalPath(ctx.cwd), home: home);
  ctx.out.writeln(m.t('restore.done', {
    'path': shown,
    'branch': r.detachedBecauseMoved || r.branch == null ? m.t('branch.detached') : r.branch,
    'patch': m.t(r.patchApplied ? 'restore.patch_yes' : 'restore.patch_no'),
    'u': r.untracked,
    'i': r.ignored,
  }));
  if (r.detachedBecauseMoved) {
    ctx.out.writeln(m.t('restore.moved',
        {'branch': r.branch, 'sha': r.head.substring(0, 12), 'path': shown}));
  }
  ctx.out.writeln(m.t('restore.kept', {'dir': displayPath('$backupRoot/$id', home: home), 'id': id}));
  return 0;
}

// ---------------------------------------------------------------- backups

Future<int> _backups(List<String> args, CliContext ctx, Messages m) async {
  final p = _parse('backups', args,
      valueOpts: {'--backup-dir', '--delete', '--prune-older-than'},
      flagOpts: {'--json', '--apply'});
  if (p.positional.isNotEmpty) {
    throw ShelveError('err.extra_arg', {'cmd': 'backups', 'arg': p.positional.first});
  }
  final deleteId = p.values['--delete'];
  final pruneRaw = p.values['--prune-older-than'];
  if (deleteId != null && pruneRaw != null) {
    throw ShelveError('err.backups_conflict');
  }
  if (p.flags.contains('--apply') && pruneRaw == null) {
    throw ShelveError('err.apply_needs_prune');
  }
  final root = _backupRoot(p, ctx);
  if (deleteId != null) return _deleteBackup(root, deleteId, p, ctx, m);
  if (pruneRaw != null) return _pruneBackups(root, _int(p, '--prune-older-than', 0, 0), p, ctx, m);

  final home = ctx.env['HOME'];
  final entries = _listBackups(root);
  final partial = _listPartials(root);

  if (p.flags.contains('--json')) {
    ctx.out.writeln(const JsonEncoder.withIndent('  ').convert({
      'backup_dir': root,
      'backups': [for (final e in entries) _entryJson(e, p, ctx)],
      // 기존 출력과 같게: 미완성 폴더가 있을 때만 키를 더한다.
      if (partial.isNotEmpty) 'partial': _partialJson(partial),
    }));
    return 0;
  }
  if (entries.isEmpty) {
    ctx.out.writeln(m.t('backups.none', {'dir': displayPath(root, home: home)}));
  } else {
    ctx.out.writeln(m.t('backups.header', {'dir': displayPath(root, home: home)}));
    final rows = [
      for (final e in entries)
        [
          e.id,
          e.branch ?? m.t('branch.detached'),
          _shortTime(e.createdAt),
          displayPath(e.worktree, root: canonicalPath(ctx.cwd), home: home),
          '${e.files}',
          formatSize(e.sizeBytes),
        ]
    ];
    ctx.out.writeln(renderTable([
      m.t('col.id'),
      m.t('col.branch'),
      m.t('col.created'),
      m.t('col.worktree'),
      m.t('col.files'),
      m.t('col.size'),
    ], rows));
  }
  _printPartials(partial, ctx, m);
  return 0;
}

/// 백업 한 건의 요약(목록·정리 공용).
class _Entry {
  _Entry(this.id, this.mf, this.sizeBytes);
  final String id;
  final Map<String, Object?> mf;
  final int sizeBytes;

  String? get createdAt => mf['created_at'] as String?;
  String get worktree => (mf['worktree'] as String?) ?? '-';
  String? get branch {
    final b = mf['branch'] as String?;
    return b?.startsWith('refs/heads/') == true ? b!.substring(11) : b;
  }

  int get files =>
      ((mf['untracked'] as List<Object?>?) ?? const []).length +
      ((mf['ignored'] as List<Object?>?) ?? const []).length;
}

/// 폴더 안 파일 크기 합(링크는 따라가지 않는다).
int _dirSize(String path) {
  var size = 0;
  try {
    for (final f in Directory(path).listSync(recursive: true, followLinks: false).whereType<File>()) {
      size += f.lengthSync();
    }
  } on FileSystemException {
    // 읽을 수 없는 부분은 크기에서 뺀다.
  }
  return size;
}

/// 백업 루트 바로 아래의 진짜 폴더 이름들(심볼릭 링크 제외).
List<String> _childDirNames(String root) {
  final dir = Directory(root);
  if (!dir.existsSync()) return [];
  return dir
      .listSync(followLinks: false)
      .whereType<Directory>()
      .map((d) => d.path.substring(d.path.lastIndexOf('/') + 1))
      .toList()
    ..sort();
}

/// manifest 가 읽히는 유효 백업만(깨진 것·이름 규칙에 안 맞는 것은 뺀다).
List<_Entry> _listBackups(String root) {
  final out = <_Entry>[];
  for (final id in _childDirNames(root).where(isValidBackupId)) {
    try {
      out.add(_Entry(id, readManifest(root, id), _dirSize('$root/$id')));
    } on ShelveError {
      continue;
    }
  }
  return out;
}

/// 만들다 만 `<id>.partial` 폴더.
List<({String name, String path, int sizeBytes})> _listPartials(String root) => [
      for (final n in _childDirNames(root))
        if (n.endsWith('.partial') && isValidBackupId(n.substring(0, n.length - 8)))
          (name: n, path: '$root/$n', sizeBytes: _dirSize('$root/$n')),
    ];

Map<String, Object?> _entryJson(_Entry e, _Args p, CliContext ctx) => {
      'id': e.id,
      'branch': e.branch,
      'head': e.mf['head'],
      'repo': e.mf['repo'],
      'worktree': e.mf['worktree'],
      'created_at': e.createdAt,
      'files': e.files,
      'size_bytes': e.sizeBytes,
      'pinned_ref': e.mf['pinned_ref'],
      'restore_command': _restoreHint(e.id, p, ctx),
    };

List<Map<String, Object?>> _partialJson(List<({String name, String path, int sizeBytes})> partial) =>
    [for (final x in partial) {'name': x.name, 'path': x.path, 'size_bytes': x.sizeBytes}];

void _printPartials(List<({String name, String path, int sizeBytes})> partial, CliContext ctx, Messages m) {
  if (partial.isEmpty) return;
  final home = ctx.env['HOME'];
  ctx.out.writeln();
  ctx.out.writeln(m.t('backups.partial_header'));
  for (final x in partial) {
    ctx.out.writeln(m.t('backups.partial_item',
        {'path': displayPath(x.path, home: home), 'size': formatSize(x.sizeBytes)}));
  }
}

/// 정리·삭제 공통 검사: 이 도구가 만든 이름 꼴이고 manifest 의 id 가 폴더 이름과 같아야 지운다.
bool _isOwnBackup(String id, Map<String, Object?> mf) => isGeneratedBackupId(id) && mf['id'] == id;

/// 안내 문구의 `{list}` 에 쓸 목록 명령(--backup-dir 를 줬으면 그대로 붙인다).
String _listHint(_Args p, CliContext ctx) {
  final custom = p.values['--backup-dir'];
  return custom == null ? 'worktree-shelve backups' : 'worktree-shelve backups --backup-dir ${_abs(custom, ctx)}';
}

/// 백업 폴더 하나를 지운다. manifest 는 맨 마지막에 지워서, 중간에 실패해도 목록·--delete 로 다시 다룰 수 있다.
/// 지우기 전에 백업 루트에 쓸 수 있는지 먼저 확인해 부분 삭제를 피한다.
void _removeBackup(String root, String id, int done) {
  ShelveError failure(Object why) => ShelveError('err.backup_delete_failed', {
        'id': id,
        'dir': root,
        'why': why is FileSystemException ? (why.osError?.message ?? why.message) : '$why',
        'done': done,
      });
  try {
    final probe = File('$root/.delete-check-$pid');
    probe.writeAsStringSync('ok', flush: true);
    probe.deleteSync();
    final dir = Directory('$root/$id');
    for (final e in dir.listSync(followLinks: false)) {
      if (e.path.endsWith('/manifest.json')) continue;
      e.deleteSync(recursive: true);
    }
    File('$root/$id/manifest.json').deleteSync();
    dir.deleteSync();
  } on FileSystemException catch (e) {
    throw failure(e);
  }
}

/// `backups --delete <id>`: 단일 ID 지정이 곧 확인이다. 검증을 모두 통과한 폴더만 지운다.
int _deleteBackup(String root, String id, _Args p, CliContext ctx, Messages m) {
  try {
    return _deleteBackupChecked(root, id, p, ctx, m);
  } on ShelveError catch (e) {
    if (e.params.containsKey('list')) rethrow;
    throw ShelveError(e.key, {...e.params, 'list': _listHint(p, ctx)}, e.exitCode);
  }
}

int _deleteBackupChecked(String root, String id, _Args p, CliContext ctx, Messages m) {
  if (!isValidBackupId(id)) throw ShelveError('err.backup_bad_id', {'id': id});
  final path = '$root/$id';
  // 링크는 따라가지 않는다: 루트 바로 아래의 진짜 폴더여야 한다.
  switch (FileSystemEntity.typeSync(path, followLinks: false)) {
    case FileSystemEntityType.directory:
      break;
    case FileSystemEntityType.notFound:
      throw ShelveError('err.backup_not_found', {'id': id, 'dir': root});
    default:
      throw ShelveError('err.backup_not_dir', {'id': id, 'dir': root});
  }
  if (!File('$path/manifest.json').existsSync()) {
    throw ShelveError('err.backup_no_manifest', {'id': id, 'dir': path});
  }
  final Map<String, Object?> mf;
  try {
    mf = readManifest(root, id); // 깨진 manifest 면 종료 코드 2
  } on ShelveError catch (e) {
    if (e.key != 'err.backup_damaged') rethrow;
    throw ShelveError('err.backup_damaged_delete', e.params, e.exitCode);
  }
  if (!_isOwnBackup(id, mf)) throw ShelveError('err.backup_bad_name', {'id': id, 'dir': root});
  final size = _dirSize(path);
  _removeBackup(root, id, 0);
  if (p.flags.contains('--json')) {
    ctx.out.writeln(const JsonEncoder.withIndent('  ').convert({
      'backup_dir': root,
      'deleted': {'id': id, 'size_bytes': size},
    }));
  } else {
    ctx.out.writeln(m.t('backups.deleted', {'id': id, 'size': formatSize(size)}));
  }
  return 0;
}

/// `backups --prune-older-than N [--apply]`: 기본은 미리보기. created_at 이 N일보다 오래된 백업만 대상.
int _pruneBackups(String root, int days, _Args p, CliContext ctx, Messages m) {
  final apply = p.flags.contains('--apply');
  final cutoff = ctx.now().toUtc().subtract(Duration(days: days));
  final targets = <_Entry>[];
  for (final e in _listBackups(root)) {
    final created = DateTime.tryParse(e.createdAt ?? '');
    if (!_isOwnBackup(e.id, e.mf)) continue; // 이름 꼴·manifest id 가 안 맞으면 지우지 않는다
    if (created == null) continue; // 날짜를 못 읽으면 지우지 않는다
    if (created.isBefore(cutoff)) targets.add(e);
  }
  final partial = _listPartials(root);
  final deleted = <String>{};
  if (apply) {
    for (final e in targets) {
      _removeBackup(root, e.id, deleted.length);
      deleted.add(e.id);
    }
  }
  final total = targets.fold<int>(0, (s, e) => s + e.sizeBytes);

  if (p.flags.contains('--json')) {
    ctx.out.writeln(const JsonEncoder.withIndent('  ').convert({
      'backup_dir': root,
      'older_than_days': days,
      'applied': apply,
      'backups': [
        for (final e in targets)
          {
            'id': e.id,
            'created_at': e.createdAt,
            'size_bytes': e.sizeBytes,
            'deleted': deleted.contains(e.id),
          }
      ],
      'partial': _partialJson(partial),
      'totals': {'count': targets.length, 'size_bytes': total},
    }));
    return 0;
  }

  final home = ctx.env['HOME'];
  if (targets.isEmpty) {
    ctx.out.writeln(m.t('prune.none', {'days': days, 'dir': displayPath(root, home: home)}));
  } else {
    ctx.out.writeln(m.t('prune.header', {'n': targets.length, 'days': days}));
    ctx.out.writeln(renderTable([
      m.t('col.id'),
      m.t('col.created'),
      m.t('col.size'),
    ], [
      for (final e in targets) [e.id, _shortTime(e.createdAt), formatSize(e.sizeBytes)]
    ]));
    ctx.out.writeln();
    ctx.out.writeln(m.t(apply ? 'prune.done' : 'prune.preview',
        {'n': targets.length, 'size': formatSize(total), 'dir': displayPath(root, home: home)}));
  }
  _printPartials(partial, ctx, m);
  return 0;
}

String _shortTime(String? iso) {
  final t = iso == null ? null : DateTime.tryParse(iso)?.toLocal();
  if (t == null) return '-';
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

// ---------------------------------------------------------------- sandbox

Future<int> _sandbox(List<String> args, CliContext ctx, Messages m) async {
  final p = _parse('sandbox', args);
  if (p.positional.length > 1) {
    throw ShelveError('err.extra_arg', {'cmd': 'sandbox', 'arg': p.positional[1]});
  }
  final dir = _abs(p.positional.isEmpty ? 'shelve-sandbox' : p.positional.first, ctx);
  final git = await Git.locate(ctx.env);
  await buildSandbox(dir, git, ctx.now());
  final home = ctx.env['HOME'];
  final shown = displayPath(dir, root: ctx.cwd, home: home);
  ctx.out.writeln(m.t('sandbox.made', {'path': shown}));
  ctx.out.writeln();
  // 만든 직후 미리보기(아무것도 지우지 않는다).
  final code = await _scan([if (p.values['--lang'] != null) ...['--lang', p.values['--lang']!]],
      ctx, m,
      forcedRoot: dir, sandboxNote: true);
  ctx.out.writeln(m.t('sandbox.next', {'path': shown == '.' ? dir : shown}));
  return code;
}
