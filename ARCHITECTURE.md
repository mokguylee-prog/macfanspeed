# FanSpeed v0.2 — 아키텍처 문서

> macOS 메뉴바 팬 속도 제어 앱  
> 만든이: 월평동 이상목  
> 최초 작성: 2026-06-07

---

## 1. 왜 만들었나

MacBook Pro 11,1 (Intel i5, 2013년)의 팬 소음이 너무 커서  
메뉴바에서 바로 팬 속도를 모니터링하고 조절하기 위해 제작.

---

## 2. 전체 구조

```
┌─────────────────────────────────────────┐
│  FanSpeed (GUI, 사용자 권한)             │
│  ├── NSStatusItem  (메뉴바 아이콘 + RPM) │
│  └── NSPopover                          │
│       ├── 4개 프리셋 버튼               │
│       ├── VerticalRPMSlider (커스텀)    │
│       ├── 현재 RPM / CPU 온도 표시      │
│       └── 자동 시작 토글 / 종료          │
│                  │                      │
│       파일 IPC: /Users/Shared/.fanspeed_target
│                  │                      │
│  fanspeed-helper (root, LaunchDaemon)   │
│  └── SMCKit → IOKit → AppleSMC         │
└─────────────────────────────────────────┘
```

### 권한 흐름

| 동작 | 권한 | 방법 |
|------|------|------|
| 팬 RPM / 온도 읽기 | 일반 사용자 | IOKit 직접 |
| 팬 속도 쓰기 (데몬 있을 때) | root (데몬) | 파일 IPC |
| 팬 속도 쓰기 (데몬 없을 때) | root (일시) | osascript 관리자 권한 |
| 데몬 설치 | root (1회) | osascript + launchctl |
| 자동 시작 등록 | 사용자 | LaunchAgent (~/Library/LaunchAgents) |

---

## 3. SMC 접근 원리

### 3-1. SMC란
System Management Controller — macOS의 저수준 하드웨어 컨트롤러.  
IOKit의 `AppleSMC` 서비스를 통해 키-값 구조로 접근.

### 3-2. 구조체 패딩 버그 (핵심 발견)

처음 구현에서 팬 속도가 모두 0으로 읽혔다. 원인은 **Swift 구조체 패딩 불일치**.

```swift
// 잘못된 버전 — Swift가 9바이트로 만듦
struct SMCKeyInfoData {
    var dataSize: UInt32      // 4바이트
    var dataType: UInt32      // 4바이트
    var dataAttributes: UInt8 // 1바이트
    // Swift: 합계 9바이트
    // C:     합계 12바이트 (4바이트 정렬로 3바이트 패딩 추가됨)
}

// 수정된 버전 — C와 동일한 12바이트
struct SMCKeyInfoData {
    var dataSize: UInt32
    var dataType: UInt32
    var dataAttributes: UInt8
    var _pad1: UInt8 = 0   // ← 명시적 패딩
    var _pad2: UInt8 = 0
    var _pad3: UInt8 = 0
}
// SMCKeyData 전체: 정확히 80바이트
```

전체 구조체가 76바이트(틀림) → 80바이트(맞음)로 수정 후 모든 읽기가 정상화.

### 3-3. 팬 제어 키 (Intel Mac)

| SMC 키 | 타입 | 용도 |
|--------|------|------|
| `FNum` | ui8  | 팬 개수 |
| `F0Ac` | fpe2 | 팬 0 현재 RPM (읽기) |
| `F0Mn` | fpe2 | 팬 0 최소 RPM |
| `F0Mx` | fpe2 | 팬 0 최대 RPM |
| `F0Tg` | fpe2 | 팬 0 목표 RPM (쓰기) |
| `FS! ` | ui16 | 수동 모드 비트마스크 (팬당 1비트) |
| `TC0P` | sp78 | CPU 온도 |

### 3-4. fpe2 / sp78 포맷

```
fpe2: uint16 빅엔디안, 상위 10비트 = 정수부, 하위 6비트 = 소수부
      읽기: raw >> 2 = RPM
      쓰기: rpm * 4 = raw (hi = raw>>8, lo = raw&0xFF)

sp78: uint16, 상위 8비트 = 정수(°C), 하위 8비트 = 소수 (/ 256)
```

### 3-5. 수동 제어 방법

```
F0Md (수동 모드 키)가 이 MacBook Pro 11,1에는 없음 (result=132, not found).
대신 Intel Mac 표준 방식:

1. FS! = 0b0001  → 팬 0 수동 모드 진입
2. F0Tg = 목표 RPM (fpe2 포맷)
3. FS! = 0x0000  → 자동 제어 복귀 (Auto)
```

---

## 4. 파일 IPC 구조 (데몬)

```
GUI 앱 (사용자)          데몬 (root)
      │                      │
      │  echo "3000" >       │
      │  /Users/Shared/      │
      │  .fanspeed_target    │
      └────────────────────→ │
                             │  2초마다 파일 폴링
                             │  "auto"   → FS!=0 (자동)
                             │  "3000"   → FS!=1, F0Tg=3000
                             └→ SMCKit.setFanTarget()
```

**타겟 파일**: `/Users/Shared/.fanspeed_target`  
**데몬 바이너리**: `/usr/local/bin/fanspeed-helper`  
**LaunchDaemon plist**: `/Library/LaunchDaemons/com.fanspeed.helper.plist`

---

## 5. 자동 시작 (LaunchAgent)

```
~/Library/LaunchAgents/com.fanspeed.app.plist
```

- `RunAtLoad: true` → 로그인 시 자동 실행
- 관리자 권한 불필요 (사용자 홈 디렉토리)
- `launchctl bootstrap gui/<uid>` 로 즉시 로드

---

## 6. 소스 파일 역할

| 파일 | 역할 |
|------|------|
| `main.swift` | 진입점. `--daemon` / `--smc-set` / GUI 세 가지 모드 분기 |
| `SMCKit.swift` | IOKit AppleSMC 저수준 읽기/쓰기 |
| `FanManager.swift` | 팬 제어 고수준 API, 데몬 설치, LaunchAgent |
| `AppDelegate.swift` | NSStatusItem, NSPopover, 타이머, 아이콘 |
| `MenuView.swift` | 팝오버 UI (상태, 프리셋, 슬라이더, 토글, 푸터) |
| `VerticalRPMSlider.swift` | 커스텀 수직 슬라이더 (Core Graphics 완전 커스텀) |

---

## 7. 빌드

```bash
cd /Volumes/MACD/AI_Work1/FanSpeed
bash build.sh
./FanSpeed
```

의존성 없음. 표준 macOS SDK만 사용 (AppKit + IOKit + Foundation).  
Xcode 불필요, `swiftc` CLI로 컴파일.

---

## 8. 개발 이력

| 버전 | 날짜 | 주요 변경 |
|------|------|-----------|
| v0.1 | 2026-06-07 | 초기 완성. SMC 읽기 버그(구조체 패딩) 수정, FS!/F0Tg 제어 구현 |
| v0.2 | 2026-06-07 | 파란 아이콘, 메뉴바 RPM 표시, 팝오버 즉시 표시, 최초 데몬 자동 설치 안내, 텍스트 잘림 수정 |
| v0.2.1 | 2026-06-07 | 슬라이더 1 RPM 미세 조절, 중복 실행 차단, 데몬 폴링 0.3초로 단축, sticky-dir IPC 버그 수정 |

---

## 9. 비밀번호 1회 원칙 (Authentication-Once Design)

### 9-1. 왜 어려운 문제인가

SMC 쓰기(`FS!`, `F0Tg`)는 root 권한이 필요하다.
- macOS는 일반 사용자가 SMC에 쓰는 것을 차단한다.
- 매번 쓸 때마다 `osascript ... with administrator privileges` 를 호출하면 사용자가 슬라이더를 움직일 때마다 비밀번호 다이얼로그가 뜬다. → 사용성 0.

### 9-2. 해결: 권한 분리 + 파일 IPC

GUI 앱(사용자 권한)과 SMC 쓰기 권한(root)을 **시간적으로 분리**한다.

```
                                  ┌─────────────────────────┐
사용자가 슬라이더 조작              │ root 데몬 (LaunchDaemon) │
      │                           │  부팅 시 자동 시작        │
      │ 1. 파일에 RPM 쓰기         │  무한 폴링 루프           │
      ▼                           │                          │
  /Users/Shared/.fanspeed_target  │  2. 파일 변경 감지 →     │
  (chmod 666)                ◄───►│     SMC 쓰기              │
                                  └─────────────────────────┘
```

- **1회만 비밀번호 입력**: 최초 데몬 설치 시 `osascript ... with administrator privileges` 로 1번. 이후 LaunchDaemon이 부팅마다 자동 root 실행.
- **이후 모든 제어는 파일 쓰기**: 일반 사용자 권한으로 666 파일에 RPM을 write → 데몬이 0.3초 폴링으로 감지 → root 권한으로 SMC에 반영.

### 9-3. 단일 바이너리 3-모드 분기

같은 실행 파일이 인자에 따라 GUI/데몬/CLI 세 가지 역할을 한다.

```swift
// main.swift
if args.contains("--daemon")        { FanManager.runDaemon() }   // root, 무한 루프
if args.contains("--smc-set")       { exit(FanManager.runCLI(...)) } // root, 1회 쓰기
// 그 외: GUI 메뉴바 앱
```

데몬 설치 시 동일 바이너리를 `/usr/local/bin/fanspeed-helper` 로 복사하고 `--daemon` 인자로 LaunchDaemon 등록. 별도의 helper 프로젝트가 필요 없다.

### 9-4. ⚠️ 함정: sticky 디렉토리에서 atomically:true 사용 금지

`/Users/Shared/` 은 sticky 디렉토리(`drwxrwxrwt`)이고 타겟 파일 소유자는 root다.
Swift 의 `String.write(toFile:atomically:true,...)` 는 내부적으로 **임시파일 생성 후 rename(2)** 으로 덮어쓴다. 그런데 **sticky 디렉토리에서는 자신이 소유하지 않은 파일을 rename으로 덮어쓸 수 없다 (EPERM)**.

결과: 매 commit 마다 write 실패 → `commit()` 이 `false` → fallback 으로 osascript 다이얼로그가 매번 뜸. ("비밀번호 1회 원칙" 완전 붕괴, 실사용 불가능.)

**올바른 구현**:
```swift
// ❌ atomically:true — sticky dir에서 EPERM
try payload.write(toFile: target, atomically: true, encoding: .utf8)

// ✅ in-place 쓰기 (파일 권한 666 보장 시)
if let fh = FileHandle(forWritingAtPath: target) {
    try fh.truncate(atOffset: 0)
    try fh.write(contentsOf: data)
}
```

설치 스크립트는 반드시 `chmod 666 /Users/Shared/.fanspeed_target` 을 보장해야 한다.

### 9-5. 중복 실행 차단

LaunchAgent 의 `RunAtLoad: true` 가 등록 즉시 같은 앱을 한 번 더 띄운다. 사용자가 수동 실행한 인스턴스와 LaunchAgent 가 띄운 인스턴스가 모두 살아 있으면 두 GUI 가 떠 있게 된다.

`main.swift` 진입 시 `NSWorkspace.runningApplications` 로 같은 실행파일명을 가진 다른 PID 가 있으면 즉시 `exit(0)`. 데몬은 helper 바이너리(이름이 다름)이므로 이 검사에 걸리지 않는다.
