---
name: project-sticky-dir-ipc
description: /Users/Shared/ sticky 디렉토리에서 root 소유 IPC 파일 쓰기 시 atomically:true 금지
metadata:
  type: project
---

`/Users/Shared/.fanspeed_target` 같이 root 소유 파일에 일반 사용자가 IPC로 쓸 때, Swift의 `String.write(toFile:atomically:true)` 는 사용하면 안 된다.

**Why:** `/Users/Shared/`는 sticky 비트가 설정된 디렉토리(`drwxrwxrwt`). atomically:true는 내부적으로 임시 파일 생성 후 rename(2)으로 덮어쓰는데, sticky 디렉토리에서는 자신이 소유하지 않은 파일을 rename으로 덮어쓸 수 없음 (EPERM). 매 commit마다 write 실패 → osascript 권한 다이얼로그가 반복적으로 뜨는 버그가 발생함 (2026-06-07에 실제 발생).

**How to apply:** root 소유 IPC 파일 쓰기는 항상 `FileHandle(forWritingAtPath:)` + `truncate + write`로 in-place 처리. 파일 권한 666 + 데몬 polling 구조라면 일반 사용자가 직접 쓸 수 있다. 데몬 설치 스크립트는 반드시 `chmod 666 /Users/Shared/.fanspeed_target` 보장.
