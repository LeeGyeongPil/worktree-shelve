// AC-8: 화면 언어(영어·한국어). 우선순위 --lang > WORKTREE_SHELVE_LANG > LC_ALL > LC_MESSAGES > LANG.
import 'package:test/test.dart';
import 'package:worktree_shelve/worktree_shelve.dart';

import 'support/fixture.dart';

final _hangul = RegExp(r'[가-힣]');

void main() {
  test('en and ko message key sets are identical', () {
    expect(messageKeys('ko'), messageKeys('en'));
  });

  test('every Korean message is written in Korean', () {
    final m = Messages('ko');
    for (final key in messageKeys('ko')) {
      expect(m.t(key), matches(_hangul), reason: key);
    }
    // 한국어 도움말에 영어 머리말이 섞이지 않는다.
    final help = m.t('help');
    for (final word in ['Usage', 'Commands', 'Options', 'Exit codes']) {
      expect(help, isNot(contains(word)));
    }
  });

  test('precedence of language sources', () {
    expect(resolveLang('ko', {'WORKTREE_SHELVE_LANG': 'en'}), 'ko');
    expect(resolveLang('en', {'WORKTREE_SHELVE_LANG': 'ko'}), 'en');
    expect(resolveLang(null, {'WORKTREE_SHELVE_LANG': 'ko', 'LC_ALL': 'en_US.UTF-8'}), 'ko');
    expect(resolveLang(null, {'LC_ALL': 'ko_KR.UTF-8', 'LC_MESSAGES': 'en_US', 'LANG': 'en_US'}), 'ko');
    expect(resolveLang(null, {'LC_ALL': 'C', 'LANG': 'ko_KR.UTF-8'}), 'en');
    expect(resolveLang(null, {'LC_MESSAGES': 'ko_KR.UTF-8', 'LANG': 'en_US.UTF-8'}), 'ko');
    expect(resolveLang(null, {'LANG': 'ko_KR.UTF-8'}), 'ko');
    expect(resolveLang(null, {'LANG': 'fr_FR.UTF-8'}), 'en');
    expect(resolveLang(null, {'LANG': 'C.UTF-8'}), 'en');
    expect(resolveLang(null, {}), 'en');
    expect(resolveLang(null, {'WORKTREE_SHELVE_LANG': '', 'LANG': 'ko_KR.UTF-8'}), 'ko');
  });

  group('through the CLI', () {
    late Fixture fx;
    setUp(() async => fx = await Fixture.create());
    tearDown(() => fx.dispose());

    Map<String, String> envWith(Map<String, String> lang) {
      final e = Map.of(fx.env)..remove('WORKTREE_SHELVE_LANG')..remove('LANG');
      return {...e, ...lang};
    }

    test('help, table headers and errors follow --lang', () async {
      final helpKo = await fx.cli(['--help', '--lang', 'ko']);
      expect(helpKo.out, contains('사용법'));
      final helpEn = await fx.cli(['--help', '--lang', 'en'], envOverride: envWith({'LANG': 'ko_KR.UTF-8'}));
      expect(helpEn.out, contains('Usage'));
      expect(helpEn.out, isNot(matches(_hangul)));

      final repo = await fx.makeRepo('root/repo');
      await fx.addWorktree(repo, 'root/wt/a', branch: 'a');
      final tableKo = await fx.cli(['scan', '--root', '${fx.base}/root', '--lang', 'ko']);
      expect(tableKo.out, contains('판정'));
      expect(tableKo.out, contains('회수 예상'));
      expect(tableKo.out, isNot(contains('VERDICT')));
      final tableEn = await fx.cli(['scan', '--root', '${fx.base}/root', '--lang', 'en']);
      expect(tableEn.out, contains('VERDICT'));
      expect(tableEn.out, contains('Would reclaim'));
      expect(tableEn.out, isNot(matches(_hangul)));

      final errKo = await fx.cli(['scan', '--nope', '--lang', 'ko']);
      expect(errKo.err, startsWith('오류: '));
      expect(errKo.err, contains('--nope'));
      final errEn = await fx.cli(['scan', '--nope', '--lang', 'en']);
      expect(errEn.err, startsWith('error: '));
    });

    test('environment variables pick the language when --lang is absent', () async {
      Future<String> helpWith(Map<String, String> lang) async =>
          (await fx.cli(['--help'], envOverride: envWith(lang))).out;
      expect(await helpWith({'WORKTREE_SHELVE_LANG': 'ko', 'LANG': 'en_US.UTF-8'}), contains('사용법'));
      expect(await helpWith({'LC_ALL': 'ko_KR.UTF-8'}), contains('사용법'));
      expect(await helpWith({'LC_MESSAGES': 'ko_KR.UTF-8', 'LANG': 'en_US.UTF-8'}), contains('사용법'));
      expect(await helpWith({'LANG': 'ko_KR.UTF-8'}), contains('사용법'));
      expect(await helpWith({'LANG': 'fr_FR.UTF-8'}), contains('Usage'));
      expect(await helpWith({'LANG': 'C.UTF-8'}), contains('Usage'));
      expect(await helpWith({}), contains('Usage'));
    });

    test('a bad --lang value is reported, not treated as an unknown option', () async {
      final r = await fx.cli(['scan', '--lang', 'fr']);
      expect(r.code, 2);
      expect(r.err, contains('--lang'));
      expect(r.err, contains('"fr"'));
      expect(r.err, isNot(contains('unknown option')));
    });
  });
}
