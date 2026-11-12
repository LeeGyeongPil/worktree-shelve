/// 다시 만들 수 있는 산출물(빌드 결과·의존성·캐시) 이름 목록.
///
/// M1 에서는 두 곳에 쓴다.
/// 1) 최신 수정 시각 계산에서 뺀다 — `npm install` 이 방금 돌았다고 "최근 작업"으로 보지 않게.
/// 2) 무시 파일 백업에서 뺀다 — `.env` 는 백업하지만 `node_modules` 는 백업하지 않는다.
library;

const artifactNames = <String>{
  // JavaScript·TypeScript
  'node_modules', '.next', '.nuxt', '.svelte-kit', '.turbo', '.parcel-cache', '.angular',
  'dist', 'build', 'out-tsc', 'coverage', '.vite',
  // Python
  '.venv', 'venv', '__pycache__', '.pytest_cache', '.mypy_cache', '.ruff_cache', '.tox',
  // Dart·Flutter·JVM·Rust
  '.dart_tool', '.gradle', 'target',
  // 테스트 결과물·OS 잡동사니
  'test-results', 'playwright-report', '.cache', '.DS_Store',
};

/// 상대 경로의 어느 한 부분이라도 산출물 이름이면 true.
bool isArtifactPath(String relativePath) {
  for (final part in relativePath.split('/')) {
    if (part.isNotEmpty && artifactNames.contains(part)) return true;
  }
  return false;
}
