# FanSpeed — 제품 사양서 (SPEC)

> 버전: v0.2.1
> 대상: macOS (Intel), 검증 모델: MacBook Pro 11,1 (2013)
> 의존성: 없음 — AppKit + IOKit + Foundation 표준 SDK 만 사용

---

## 1. 제품 개요

FanSpeed 는 macOS 메뉴바에 상주하며 팬 RPM 과 CPU 온도를 실시간 표시하고, 팝오버 UI 로 즉시 팬 속도를 조절하는 메뉴바 앱이다. Intel Mac 의 SMC (System Management Controller) 키 `FS!`, `FxTg` 를 직접 제어한다.

- **단일 바이너리** — `swiftc` 로 컴파일한 단일 실행 파일. `.app` 번들 없음.
- **메뉴바 only** — Dock 아이콘 없음 (`NSApplication.setActivationPolicy(.accessory)`).
- **비밀번호 1회 원칙** — 최초 데몬 설치 시 1회만 입력. 이후 모든 제어는 비밀번호 없이.

---

## 2. 동작 모드 (단일 바이너리 3-모드)

| 모드 | 인자 | 권한 | 용도 |
|------|------|------|------|
| GUI | (없음) | 사용자 | 메뉴바 + 팝오버 |
| 데몬 | `--daemon` | root (LaunchDaemon) | 파일 폴링 → SMC 쓰기 |
| 1회 CLI | `--smc-set auto\|manual <RPM>` | root (osascript) | 데몬 미설치 시 폴백 |

---

## 3. UI 사양

### 3-1. 메뉴바 (NSStatusItem)

```
[🌀 파란 팬 아이콘]  [현재 RPM]  [CPU 온도]
```

- 폰트: `NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)`
- 아이콘: Core Graphics 로 직접 그린 파란색 3-블레이드 팬 (16×16)
- 5초마다 갱신 (백그라운드 큐에서 SMC 읽고 메인에서 UI 업데이트)
- 클릭 시 팝오버 토글 (`leftMouseUp`, `rightMouseUp`)

### 3-2. 팝오버 (NSPopover, 280×350)

상단부터 4개 영역:

| 영역 | 위치 (y) | 구성 |
|------|----------|------|
| 1. 프리셋 행 | 10–62 | 4 버튼 (자동 / 조용히 / 보통 / 최대), SF Symbol + 텍스트 |
| 2. 제어 영역 | 84–239 | 수직 슬라이더(좌) + 대형 RPM 숫자(우) + 현재 RPM/CPU 라벨 |
| 3. 자동 시작 토글 | 266–286 | NSSwitch + 라벨 |
| 4. 푸터 | 314–336 | "FanSpeed v0.2 YYYY-MM-DD" + "종료" |

- 모든 좌표는 `isFlipped = true` 기준 (y=0 상단).
- `popover.animates = false` — 즉시 표시.
- `popover.behavior = .transient` — 다른 곳 클릭 시 자동 닫힘.

### 3-3. 프리셋 매핑

| 프리셋 | RPM |
|--------|-----|
| 자동 | `FS! = 0` (SMC auto control) |
| 조용히 | `max(minRPM, 2000)` |
| 보통 | `(minRPM + maxRPM) / 2` |
| 최대 | `maxRPM` |

### 3-4. 수직 슬라이더 (VerticalRPMSlider, 30×155)

- 완전 커스텀 드로잉 (NSSlider 사용 안 함).
- 범위: `[minRPM, maxRPM]` — SMC `F0Mn`, `F0Mx` 에서 읽어옴.
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
| `F0Ac` | fpe2 | R | 팬 0 현재 RPM |
| `F0Mn` | fpe2 | R | 팬 0 최소 RPM |
| `F0Mx` | fpe2 | R | 팬 0 최대 RPM |
| `F0Tg` | fpe2 | W | 팬 0 목표 RPM |
| `FS! ` | ui16 | W | 수동 모드 비트마스크 (팬당 1비트) |
| `TC0P/TC0E/TC0D/TCXC/TC0F` | sp78 | R | CPU 온도 (순차 시도) |

### 4-2. fpe2 / sp78 변환

```
fpe2 → RPM:  raw_be_u16 >> 2
RPM → fpe2:  rpm * 4 → be_u16
sp78 → ℃:    hi + lo/256
```

### 4-3. 수동 제어 시퀀스

```
Auto → Manual:  FS! = 0b0001 (또는 mask=2ⁿ-1)
                F0Tg = target_rpm
Manual → Auto:  FS! = 0x0000
```

`F0Md` (모드 키) 는 MacBook Pro 11,1 에 존재하지 않음 → `FS!` 비트마스크 방식 사용.

---

## 5. 데몬 / IPC 사양

### 5-1. 파일 IPC 프로토콜

**타겟 파일**: `/Users/Shared/.fanspeed_target` (mode 666, owner root)

**페이로드**:
- `"auto"` → 자동 모드 (`FS! = 0`)
- `"<integer>"` → 수동 모드, 해당 RPM 으로 설정
- 빈 문자열 → `auto` 와 동등

**폴링 주기**: 0.3초 (Thread.sleep)
**중복 쓰기 무시**: 직전 값과 같으면 SMC 호출 생략.

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
```

**helper 바이너리**: GUI 와 동일한 실행 파일을 `/usr/local/bin/fanspeed-helper` 로 복사 (chmod 755, owner root).

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
swiftc \
  Sources/SMCKit.swift \
  Sources/FanManager.swift \
  Sources/VerticalRPMSlider.swift \
  Sources/MenuView.swift \
  Sources/AppDelegate.swift \
  Sources/main.swift \
  -framework AppKit -framework IOKit -framework Foundation \
  -o FanSpeed
```

- Xcode 불필요
- 외부 패키지 없음
- 단일 실행 파일 산출

---

## 9. 갱신 주기

| 항목 | 주기 |
|------|------|
| 메뉴바 RPM / 온도 표시 | 5초 (`Timer.tolerance = 1`) |
| 데몬 파일 폴링 | 0.3초 |
| 슬라이더 UI 갱신 | 입력 즉시 |
| SMC 쓰기 (slider commit) | mouseUp 시점 |

---

## 10. 제약 / 비범위

- **Apple Silicon 미지원** — Apple Silicon Mac 은 SMC 가 없거나(Mn/Mx 키 부재), 별도 방식 필요.
- **다중 팬 부분 지원** — 코드는 `FNum` 기반 비트마스크로 모든 팬을 동시 제어. 팬별 개별 RPM UI 는 없음 (단일 슬라이더 → 전 팬 동일 RPM).
- **자동 모드 학습 / 온도 곡선 없음** — SMC 의 기본 자동 제어에 위임. 커스텀 곡선 미지원.
- **Sandboxing 미적용** — root 데몬 설치 및 SMC 직접 접근 특성상 App Store 배포 불가.
