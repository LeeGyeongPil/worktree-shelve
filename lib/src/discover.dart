/// `--root` 아래에서 메인 저장소(`.git` 이 "폴더"인 곳)를 찾는다.
///
/// - 심볼릭 링크는 따라가지 않는다(공유 폴더를 두 번 세거나 밖으로 나가지 않게).
/// - 산출물 폴더(node_modules 등)와 `.git` 안으로는 내려가지 않는다.
/// - `.git` 이 "파일"인 폴더는 연결 워크트리·서브모듈이라 그 메인에서 찾으므로 내려가지 않는다.
/// - 깊이 상한(기본 6)을 둔다.
library;

import 'dart:io';

import 'artifacts.dart';

List<String> discoverRepos(String root, {int maxDepth = 6}) {
  final found = <String>[];

  void walk(String dir, int depth) {
    final dotGit = FileSystemEntity.typeSync('$dir/.git', followLinks: false);
    if (dotGit == FileSystemEntityType.directory) found.add(dir);
    if (dotGit == FileSystemEntityType.file) return; // 연결 워크트리·서브모듈
    if (depth >= maxDepth) return;

    List<FileSystemEntity> children;
    try {
      children = Directory(dir).listSync(followLinks: false);
    } on FileSystemException {
      return; // 읽을 수 없는 폴더는 건너뛴다
    }
    children.sort((a, b) => a.path.compareTo(b.path));
    for (final child in children) {
      if (child is! Directory) continue;
      final name = child.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (name == '.git' || artifactNames.contains(name)) continue;
      walk(child.path, depth + 1);
    }
  }

  walk(root, 0);
  return found;
}
