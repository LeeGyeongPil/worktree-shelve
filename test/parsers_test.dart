// 파서 단위 테스트: porcelain -z, 마운트 표, 버전 상수.
import 'dart:io';

import 'package:test/test.dart';
import 'package:worktree_shelve/worktree_shelve.dart';

void main() {
  test('porcelain -z records with labels', () {
    const z = 'worktree /r/main\x00HEAD aaa\x00branch refs/heads/main\x00\x00'
        'worktree /r/wt-a\x00HEAD bbb\x00detached\x00locked agent\nrunning\x00\x00'
        'worktree /r/wt-gone\x00HEAD ccc\x00branch refs/heads/g\x00prunable gitdir file points to non-existent location\x00\x00';
    final list = parsePorcelainZ(z);
    expect(list, hasLength(3));
    expect(list[0].shortBranch, 'main');
    expect(list[1].detached, isTrue);
    expect(list[1].locked, isTrue);
    expect(list[1].lockReason, 'agent\nrunning');
    expect(list[2].prunable, isTrue);
  });

  test('mount tables from macOS, Linux and /proc/mounts', () {
    const mac = '/dev/disk3s1s1 on / (apfs, sealed, local, read-only, journaled)\n'
        '/dev/disk5s1 on /mnt/backup-disk (apfs, local, nodev, nosuid)\n';
    expect(parseMountOutput(mac), ['/', '/mnt/backup-disk']);
    const linux = '/dev/sda1 on / type ext4 (rw,relatime)\ntmpfs on /run/a b type tmpfs (rw)\n';
    expect(parseMountOutput(linux), ['/', '/run/a b']);
    const proc = '/dev/sda1 / ext4 rw 0 0\nfuse /srv/my\\040disk fuse rw 0 0\n';
    expect(parseProcMounts(proc), ['/', '/srv/my disk']);
    expect(mountInside('/srv/wt', ['/', '/srv/wt/disk']), '/srv/wt/disk');
    expect(mountInside('/srv/wt', ['/', '/srv/wt2']), isNull);
  });

  test('toolVersion matches pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('version: $toolVersion'));
  });

  test('backup ids cannot escape the backup folder', () {
    expect(isValidBackupId('20261112-101500-feat-a'), isTrue);
    expect(isValidBackupId('../x'), isFalse);
    expect(isValidBackupId('a/b'), isFalse);
    expect(isValidBackupId('x.partial'), isFalse);
  });
}
