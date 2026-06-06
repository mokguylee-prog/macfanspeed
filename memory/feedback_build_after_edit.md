---
name: feedback-build-after-edit
description: 소스 수정 후 반드시 빌드 및 실행까지 자동으로 수행
metadata:
  type: feedback
---

소스 코드를 수정한 후에는 반드시 빌드하고 실행까지 해야 한다.

**Why:** 수정 후 빌드/실행은 항상 따라오는 작업이므로 사용자가 별도로 요청할 필요 없음.

**How to apply:** 소스 파일(.swift 등) 편집 완료 시 `bash build.sh` 로 빌드하고, 성공하면 앱을 실행한다.
