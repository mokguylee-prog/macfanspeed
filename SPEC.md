# FanSpeed — 제품 사양서 (SPEC)

> 버전: v0.3
> 대상: macOS 11 이상 (Apple Silicon / Intel), 센서 읽기 검증: M5 Pro / macOS 26.5.1
> 의존성: 없음 — AppKit + IOKit + Foundation 표준 SDK 만 사용

---

## 1. 제품 개요

FanSpeed 는 macOS 메뉴바에 상주하며 팬별 RPM 과 CPU 온도를 실시간 표시하고, 팝오버 UI 로 팬 속도를 조절하는 메뉴바 앱이다. Intel은 `FS!`, Apple Silicon은 `Fxmd` / `FxMd`로 모드를 선택하고 `FxTg`로 목표 RPM을 쓴다.

- **단일 바이너리** — `swiftc` 로 컴파일한 단일 실행 파일. `.app` 번들 없음.
- **메뉴바 only** — Dock 아이콘 없음 (`NSApplication.setActivationPolicy(.accessory)`).
- **비밀번호 1회 원칙** — 최초 데몬 설치 시 1회만 입력. 이후 모든 제어는 비밀번호 없이.

---

## 2. 동작 모드 (단일 바이너리 4-모드)

| 모드 | 인자 | 권한 | 용도 |
|------|------|------|------|
| GUI | (없음) | 사용자 | 메뉴바 + 팝오버 |
| 데몬 | `--daemon` | root (LaunchDaemon) | 파일 폴링 → SMC 쓰기 |
| 1회 CLI | `--smc-set auto\|manual <RPM> --model new\|legacy` | root (osascript) | 데몬 미설치 시 폴백 |
| 진단 | `--diagnose [--model new\|legacy]` | 사용자 | 읽기 전용 센서 JSON |

---

## 3. UI 사양

### 3-1. 메뉴바 (NSStatusItem)

```
[🌀 파란 팬 아이콘]  [현재 RPM]  [CPU 온도]
```

- 폰트: `NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)`
- 아이콘: Core Graphics 로 직접 그린 파란색 3-블레이드 팬 (16×16)
- 2초마다 갱신 (직렬 백그라운드 큐에서 SMC 읽고 메인에서 UI 업데이트)
- 팬별 RPM을 `/`로 구분. 실제 정지는 `0`, 읽기 실패는 `—`, 팬 없는 모델은 `팬 없음`.
- 클릭 시 팝오버 토글 (`leftMouseUp`, `rightMouseUp`)

### 3-2. 팝오버 (NSPopover, 280×406)

상단부터 5개 영역:

| 영역 | 위치 (y) | 구성 |
|------|----------|------|
| 1. 프리셋 행 | 10–62 | 4 버튼 (자동 / 조용히 / 보통 / 최대), SF Symbol + 텍스트 |
| 2. 제어 영역 | 84–239 | 수직 슬라이더(좌) + 대형 RPM 숫자(우) + 현재 RPM/CPU 라벨 |
| 3. 모델 선택 토글 | 264–305 | ON: New 모델(Apple Silicon), OFF: 이전 모델(Intel), 선택 안내 |
| 4. 자동 시작 토글 | 320–342 | NSSwitch + 라벨 |
| 5. 푸터 | 370–392 | "FanSpeed v0.3 YYYY-MM-DD" + "종료" |

- 모든 좌표는 `isFlipped = true` 기준 (y=0 상단).
- `popover.animates = false` — 즉시 표시.
- `popover.behavior = .transient` — 다른 곳 클릭 시 자동 닫힘.
- 자동 모드에서도 대형 숫자에 팬 1의 실제 RPM 표시. 팬별 현재 RPM과 New 모델 CPU 평균 온도를 별도로 표시.
- 첫 실행은 `hw.optional.arm64`로 실제 하드웨어 감지. 선택은 `com.fanspeed.app` UserDefaults의 `macModel`에 저장.
- 모델 변경 시 기존 수동 제어를 먼저 자동으로 복귀시킨다. 복귀 실패 시 스위치를 원래 상태로 돌린다.

### 3-3. 프리셋 매핑

| 프리셋 | RPM |
|--------|-----|
| 자동 | Intel: `FS! = 0`, New: 각 팬 모드 = 0 및 목표 RPM = 0 |
| 조용히 | `max(minRPM, 2000)` |
| 보통 | `(minRPM + maxRPM) / 2` |
| 최대 | `maxRPM` |

### 3-4. 수직 슬라이더 (VerticalRPMSlider, 30×155)

- 완전 커스텀 드로잉 (NSSlider 사용 안 함).
- 범위: `[minRPM, maxRPM]` — 각 팬의 `FxMn`, `FxMx` 에서 읽어옴. 적용 시 각 팬의 개별 범위로 제한.
- **스텝 1 RPM** (미세 조절 우선).
- 트랙 색상: 진행률에 따라 청록 → 주황 → 빨강 그라데이션.
- 노브: 흰색 원 + 약한 그림자.
- `mouseDown/Dragged` → `onChanged` (UI 갱신만), `mouseUp` → `onCommit` (SMC 적용).

---

## 4. 팬 제어 사양

### 4-1. SMC 키

| 키 | 타입 | 방향 | 용도 |
|----|------|------|------|
| `FNum` | ui8 | R | 팬 개수 |
| `FxAc` | fpe2 / flt | R | 팬 x 현재 RPM |
| `FxMn` | fpe2 / flt | R | 팬 x 최소 RPM |
| `FxMx` | fpe2 / flt | R | 팬 x 최대 RPM |
| `FxTg` | fpe2 / flt | W | 팬 x 목표 RPM |
| `FS! ` | ui16 | W | 수동 모드 비트마스크 (팬당 1비트) |
| `Fxmd` / `FxMd` | ui8 | R/W | New 모델 팬별 모드, 대소문자 탐지 |
| `TC0P/TC0E/TC0D/TCXC/TC0F` | sp78 | R | CPU 온도 (순차 시도) |
| `Tp*`, `Te*`, M3 CPU의 `Tf*` 일부 | flt | R | New 모델 CPU 센서 탐색 및 평균 |

### 4-2. 타입별 변환

```
fpe2 → RPM:  raw_be_u16 / 4
RPM → fpe2:  rpm * 4 → be_u16
sp78 → ℃:    signed_be_i16 / 256
flt → 수치:  little-endian IEEE-754 Float32
```

### 4-3. 수동 제어 시퀀스

```
Auto → Manual:  FS! = 0b0001 (또는 mask=2ⁿ-1)
                F0Tg = target_rpm
Manual → Auto:  FS! = 0x0000
```

`F0Md` (모드 키) 는 MacBook Pro 11,1 에 존재하지 않음 → `FS!` 비트마스크 방식 사용.
New 모델은 `Fxmd` / `FxMd`에 1을 쓰고 타입에 맞게 목표 RPM을 쓴다. 실패 시 전체 팬의 자동 복귀를 시도하며 CLI는 실패 코드를 반환한다. `Ftst` 강제 해제는 사용하지 않는다.

---

## 5. 데몬 / IPC 사양

### 5-1. 파일 IPC 프로토콜

**타겟 파일**: `/Users/Shared/.fanspeed_target` (mode 666, owner root)

**페이로드**:
- `"new auto"` / `"legacy auto"` → 해당 모델 방식으로 자동 복귀
- `"new <integer>"` / `"legacy <integer>"` → 해당 모델 방식으로 수동 RPM 설정
- 이전 GUI의 `"auto"` / `"<integer>"`도 처리하며 모델은 실제 하드웨어로 감지
- 빈 문자열 / 잘못된 명령은 무시 (in-place 쓰기 중 빈 파일 보호)

**폴링 주기**: 0.3초 (Thread.sleep)
**중복 쓰기 무시**: 마지막으로 성공한 명령과 같으면 SMC 호출 생략. 실패 시 재시도하며 모델 변경 시 기존 방식의 자동 복귀를 먼저 수행.

### 5-2. 데몬 등록

**plist**: `/Library/LaunchDaemons/com.fanspeed.helper.plist`
```xml
<key>Label</key><string>com.fanspeed.helper</string>
<key>ProgramArguments</key><array>
  <string>/usr/local/bin/fanspeed-helper</string>
  <string>--daemon</string>
</array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>FanSpeedIPCVersion</key><integer>2</integer>
```

**helper 바이너리**: GUI 와 동일한 실행 파일을 `/usr/local/bin/fanspeed-helper` 로 복사 (chmod 755, owner root).
이전 IPC 버전 도우미는 새 모델 선택 명령을 이해하지 못하므로 업데이트 안내 대상이다.
읽기에는 도우미가 필요 없으며 최초 수동 제어 시 설치를 안내한다.

### 5-3. ⚠️ 쓰기 방식 제약

`/Users/Shared/` 는 sticky 디렉토리(`drwxrwxrwt`). 일반 사용자는 root 소유 파일을 **rename 으로 덮어쓸 수 없다**. 따라서:

- ❌ 금지: `String.write(toFile:atomically:true)` — 내부적으로 임시파일+rename, EPERM 발생
- ✅ 사용: `FileHandle(forWritingAtPath:)` + `truncate(atOffset:0)` + `write(contentsOf:)` — in-place 쓰기

---

## 6. 자동 시작 (LaunchAgent)

**plist**: `~/Library/LaunchAgents/com.fanspeed.app.plist`

- `RunAtLoad: true` — 로그인 시 자동 실행
- 사용자 권한 (관리자 권한 불필요)
- 등록/해제는 팝오버의 토글로만 수행 (앱 시작 시 강제 등록 X)

### 중복 실행 차단

`main.swift` 진입 시 `NSWorkspace.shared.runningApplications` 를 스캔하여 같은 실행 파일명을 가진 다른 PID 가 있으면 즉시 `exit(0)`. LaunchAgent 등록 후 첫 번째 `launchctl load -w` 가 즉시 RunAtLoad 트리거 → 사용자가 수동 실행한 인스턴스와 충돌하는 문제 방지.

---

## 7. 파일 / 경로 일람

| 경로 | 소유자 | 권한 | 용도 |
|------|--------|------|------|
| `/usr/local/bin/fanspeed-helper` | root | 755 | 데몬 바이너리 |
| `/Library/LaunchDaemons/com.fanspeed.helper.plist` | root | 644 | 데몬 plist |
| `/Users/Shared/.fanspeed_target` | root | 666 | IPC 타겟 파일 |
| `~/Library/LaunchAgents/com.fanspeed.app.plist` | 사용자 | 644 | 자동 시작 plist |

---

## 8. 의존성 / 빌드

```bash
bash build.sh
bash test.sh
```

- Xcode 불필요
- 외부 패키지 없음
- arm64 / x86_64, macOS 11 최소 대상으로 컴파일 후 Universal 단일 실행 파일 산출
- Command Line Tools 사용 가능 시 빌드 프로세스에서만 선택. 시스템 Xcode 설정 변경 없음.
- 병합 후 로컬 실행용 ad-hoc 서명

---

## 9. 갱신 주기

| 항목 | 주기 |
|------|------|
| 메뉴바 RPM / 온도 표시 | 2초 (`Timer.tolerance = 0.4`) |
| 데몬 파일 폴링 | 0.3초 |
| 슬라이더 UI 갱신 | 입력 즉시 |
| SMC 쓰기 (slider commit) | mouseUp 시점 |

---

## 10. 제약 / 비범위

- **실기 검증 범위** — M5 Pro의 센서 읽기 검증. Intel 데이터 변환 회귀 검증. 관리자 권한의 실제 팬 쓰기는 이번 변경에서 검증하지 않음.
- **수동 제어 제한** — macOS / 펌웨어가 모드 변경을 거부할 수 있다. 이 경우 실패로 처리하며 강제 해제는 수행하지 않는다.
- **다중 팬 제어** — 팬별 현재 RPM 표시. 단일 슬라이더의 목표를 각 팬의 개별 최소/최대 범위로 제한해 적용.
- **자동 모드 학습 / 온도 곡선 없음** — SMC 의 기본 자동 제어에 위임. 커스텀 곡선 미지원.
- **Sandboxing 미적용** — root 데몬 설치 및 SMC 직접 접근 특성상 App Store 배포 불가.
