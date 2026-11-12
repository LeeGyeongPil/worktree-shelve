/// 워크트리 폴더의 "최근 손댄 흔적"과 크기를 잰다.
///
/// - 최신 수정 시각: 파일과 폴더의 mtime 중 가장 늦은 것.
///   산출물 폴더(node_modules 등) 안쪽과 맨 위 `.git` 은 빼고 본다.
///   (`npm install`·`git status` 가 시각을 바꿔도 "사람이 작업했다"로 보지 않게)
/// - 크기: 워크트리를 지우면 실제로 돌아오는 바이트. 산출물 폴더도 포함한다.
/// - 심볼릭 링크는 수정 시각에도 크기에도 넣지 않는다(밖을 가리키는 링크를 따라가지 않는다).
/// - 안쪽 git 저장소: 맨 위가 아닌 곳의 `.git`(폴더·파일·링크 모두)을 찾아 둔다.
///   서브모듈·직접 clone 한 저장소·산출물 폴더 안의 저장소까지 — 백업이 그 안을 다 담지 못한다.
library;

import 'dart:io';

import 'artifacts.dart';

class TreeActivity {
  TreeActivity(this.newestEdit, this.sizeBytes, this.unreadable, this.nestedRepo);

  /// 가장 늦은 mtime(없으면 null).
  final DateTime? newestEdit;
  final int sizeBytes;

  /// 권한 때문에 읽지 못한 폴더 수(0 이 아니면 판정을 보수적으로 "보존").
  final int unreadable;

  /// 안쪽 git 저장소(`.git` 을 가진 폴더) 중 이름순 첫 번째의 상대 경로. 없으면 null.
  final String? nestedRepo;
}

TreeActivity measureTree(String root) {
  DateTime? newest;
  var size = 0;
  var unreadable = 0;
  String? nested;

  void consider(DateTime t) {
    if (newest == null || t.isAfter(newest!)) newest = t;
  }

  // (경로, 산출물 안쪽인가) 를 쌓아 두고 하나씩 꺼내는 반복 탐색 — 깊은 트리에서도 재귀 한도에 안 걸린다.
  final stack = <(String, bool)>[(root, false)];
  var isTop = true;
  while (stack.isNotEmpty) {
    final (dir, inArtifact) = stack.removeLast();
    if (!inArtifact) {
      final stat = FileStat.statSync(dir);
      // 맨 위 폴더 시각도 포함한다(파일을 지우거나 이름을 바꿔도 바뀐다).
      if (stat.type == FileSystemEntityType.directory) consider(stat.modified);
    }
    List<FileSystemEntity> children;
    try {
      children = Directory(dir).listSync(followLinks: false);
    } on FileSystemException {
      unreadable++;
      continue;
    }
    for (final entity in children) {
      final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (name == '.git') {
        if (isTop) continue; // 연결 워크트리 자신의 .git 파일
        // 더 안쪽의 .git = 다른 저장소가 들어 있다(서브모듈이든 직접 clone 이든).
        final rel = dir.substring(root.length + 1);
        if (nested == null || rel.compareTo(nested) < 0) nested = rel;
      }
      if (entity is Link) continue; // 링크는 세지 않는다
      final artifact = inArtifact || artifactNames.contains(name);
      if (entity is Directory) {
        stack.add((entity.path, artifact));
      } else if (entity is File) {
        final stat = entity.statSync();
        size += stat.size;
        if (!artifact) consider(stat.modified);
      }
    }
    isTop = false;
  }
  return TreeActivity(newest, size, unreadable, nested);
}
