# 개발 이력 — 이전 세션 (PanSpeed 시절)

> 폴더 이름이 `PanSpeed` 였던 시점의 개발 흐름 정리.
> 세션 위치(참고용): 2026-06-07. macfanspeed 로 폴더 이름 변경 직전까지.
>
> 본 문서는 새 세션이 시작될 때 이전 작업 컨텍스트를 잃지 않도록 하기 위한 백업이다. 폴더 이름 변경은 Claude Code 세션 식별자(작업 디렉토리 경로)를 바꾸기 때문에, 변경 직후 대화 컨텍스트가 끊긴다.

---

## 1. 사용자 최초 요청 (Plan 모드)

> "MAC BOOK이잖아 팬 소리가 너무 커서 메뉴바에 팬 속도 조절하는 프로그램을 만들어야해. 인터넷에 검색해보고 팬속도 조절 하는 좀 깔끔한 프로그램 찾아서 만들어줘. about에는 월평동 이상목을 추가하고 메뉴바 눌렀을때 하단에 날짜를 버전으로 넣고, 종료 버튼도 넣어주고."

처음 계획은 Python(Tkinter/rumps) 으로 잡혔다가, 사용자가 **Swift 로 변경** 요청 → AppKit + IOKit 단일 바이너리로 방향 전환.

---

## 2. v0.1 — 초기 구현 & 0 RPM 버그 해결

### 2-1. 첫 빌드 후 사용자 보고

> "0 RPM으로 나오고 실제 속도 조절이 안되는데. 어떻게 된건가? 항상 일반적인 문제를 만드는것 같아. github, stack overflow 찾아보고 완벽하게 수정을 해."

### 2-2. 원인 진단 — 구조체 패딩 버그

머신: **MacBook Pro 11,1 (2013, Intel i5)** 확인. Intel은 SMC 팬 제어가 확실히 되므로 코드 버그.

`SMCKeyData` 구조체 전체 크기를 측정 → **76바이트** (정답: 80바이트).
원인: `SMCKeyInfoData` 가 C에서는 4바이트 정렬 패딩으로 12바이트인데 Swift에서는 9바이트로 잡힘.

```swift
// 수정 후 (정확한 80바이트 확보)
private struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
    var _pad1: UInt8 = 0   // ← 명시 패딩
    var _pad2: UInt8 = 0
    var _pad3: UInt8 = 0
}
```

수정 즉시 정상화:
```
fanCount: 1 | F0 현재: 6193 RPM | 최대: 6199 | CPU: 77.9°C
```

### 2-3. 팬이 시끄러운 이유 — 정상 동작

CPU가 77~94°C 로 매우 뜨거움. 팬 6199(=max) 는 고장이 아니라 정상 열 반응. 2013년 모델 특성.

### 2-4. 제어 방식 — `FS!` + `F0Tg`

- 기존 가정 `F0Md` (수동 모드 키) 가 이 모델에 없음 (result=132, not found)
- 대신 **`FS!` (ui16 비트마스크)** + **`F0Tg` (목표 RPM)** 사용. smcFanControl, Macs Fan Control 도 동일 방식.
- 수동 모드: `FS!` 비트 세팅 + `F0Tg` 쓰기
- 자동 복귀: `FS! = 0`
- `smcFanControl` 외부 도구 의존 제거 → **IOKit 직접 쓰기** + osascript 관리자 권한 자체 구현.

### 2-5. v0.1 산출물

| 파일 | 역할 |
|------|------|
| `Sources/SMCKit.swift` | IOKit AppleSMC 저수준 R/W |
| `Sources/FanManager.swift` | 프리셋 (Auto / Quiet / Normal / Turbo) |
| `Sources/AppDelegate.swift` | 메뉴바, About 다이얼로그 |
| `Sources/main.swift` | NSApp 진입점, `.accessory` 정책 |
| `build.sh` | `swiftc` 빌드 스크립트 |

---

## 3. UI 대대적 개편 — 첨부 이미지 스타일

### 3-1. 사용자 요청

> "메뉴바 구성된 느낌을 첨부 파일 같이 해주고, 폰트 크기들도 유사하게 해줘, 그리고 아이콘 만들어주고, 부팅되고 나서 자동으로 실행 되도록 해줘. 팬속도 설정 실패 나온다. 슬라이드바로 속도 조절하게 해줘. 슬라이드바는 상하가 좋겠어."

### 3-2. "팬속도 설정 실패" 의 진짜 원인

osascript 가 root 로 실행될 때 작업 디렉토리가 `/` 로 바뀌어 상대경로 `./PanSpeed` 가 안 잡힘. → **`absoluteSelfPath` 절대경로** 로 변환해서 osascript 호출.

### 3-3. 비밀번호 1회 원칙 도입

매번 비밀번호 묻는 건 슬라이더 연속 제어와 양립 불가능. → **LaunchDaemon + 파일 IPC**:

- 최초 1회 데몬 설치 → `/Library/LaunchDaemons/com.panspeed.helper.plist`
- 이후 `/Users/Shared/.panspeed_target` 에 RPM 쓰기 → 데몬이 폴링으로 SMC 반영
- 같은 바이너리를 `--daemon` 인자로 LaunchDaemon 등록 → helper 분리 프로젝트 불필요

### 3-4. UI 산출물

| 항목 | 내용 |
|------|------|
| 상단 상태 | `● 연결됨 ✓` (그린 도트) |
| 프리셋 | SF Symbol + 라벨 (자동/조용히/보통/최대), 선택 시 파란 하이라이트 |
| 중앙 | 커스텀 **수직 슬라이더** + 모노스페이스 대형 RPM 숫자 |
| 슬라이더 색 | 청록(저속) → 주황(중속) → 빨강(고속) |
| 현재/온도 | 현재 RPM + CPU°C (85°C↑ 주황 + ⚠️) |
| 하단 토글 | 로그인 시 자동 시작 |
| 푸터 | `PanSpeed 2026-06-07` (클릭→About) + `종료` |
| 아이콘 | Core Graphics 직접 생성 3-블레이드 팬 |

### 3-5. 새 파일

| 파일 | 역할 |
|------|------|
| `Sources/MenuView.swift` | 팝오버 UI 전체 |
| `Sources/VerticalRPMSlider.swift` | 커스텀 수직 슬라이더 |

---

## 4. v0.2 — 마감 다듬기

### 4-1. 사용자 요청

> "어떻게 처리했는지 .md 파일로 기록을 남겨둬. 메뉴바에 RPM 표기하는 것이 좋으니 실제 RPM 메뉴바에 같이 보여주도록 하고, 흰색아이콘을 파란색으로 변경해줘. 메뉴 하단 PanSpeed 날짜 옆에 v0.2 로 버전 넣어주고. 한단에 글자가 좀 잘려. 메뉴바 누르면 속도가 느리게 메뉴가 나오는데 이거 빠르게 나오도록 속도 개선을 해주고, 매번 관리자 비번을 안 누르도록 할 수는 없는건가?"

### 4-2. 처리 결과

| # | 요청 | 처리 |
|---|------|------|
| 1 | 문서화 | `ARCHITECTURE.md` 생성 — SMC 패딩 버그 발견 경위, FS!/F0Tg, 데몬 IPC, 파일 역할 |
| 2 | 메뉴바 RPM | 아이콘 옆 `1234` 숫자, 5초 갱신 |
| 3 | 파란 아이콘 | `NSColor.systemBlue`, `isTemplate = false` |
| 4 | 버전 표기 | 푸터 `PanSpeed v0.2 2026-06-07` |
| 5 | 텍스트 잘림 | 뷰 높이 368 → 392, 푸터 y좌표 재배치 |
| 6 | 팝오버 속도 | `popover.animates = false` + SMC 읽기 백그라운드 스레드 이동 |
| 7 | 비밀번호 1회 | 첫 실행 0.8초 후 "최초 설정" 다이얼로그 자동 표시 → 1회 입력으로 영구 해결 |

---

## 5. 추가 다듬기 ("연결됨" 행 제거 외)

### 5-1. 사용자 요청

> "연결됨은 무슨 의미지 필요 없을것 같은데. 자동, 조용히, 보통, 최대 메뉴 아이콘이 정 중앙은 아니고 위로 치우쳐져 있거든 깔끔하게 좀더 조정을 해줘. 아이콘 옆에 온도도 표시하지."

### 5-2. 처리

- **"연결됨" 행 제거** → 확보된 44px 만큼 전체 위로 정렬, 팝오버 392→350px 축소
- **프리셋 정중앙 정렬** → `NSButton.imagePosition=.imageAbove` 의 위치 치우침 해결 위해 **`PresetButton: NSView` 커스텀 구현**. `layout()` 에서 `baseY = (h - (icon+gap+title)) / 2` 수식으로 정확한 수직 중앙.
- **메뉴바 온도** → 기존 `[아이콘] 5234` → 변경 `[아이콘] 5234 77°C`. 백그라운드 스레드에서 RPM·온도 동시 읽기.

---

## 6. 폴더 이름 변경 (세션 분기점)

### 6-1. 사용자 요청

> "프로젝트 폴더 이름 내가 잘못 정했어. macfanspeed 로 변경 가능하지? 변경하고 계속 작업 가능하도록 해줘."

### 6-2. 처리

| 항목 | 변경 전 | 변경 후 |
|------|---------|---------|
| 프로젝트 폴더 | `/Volumes/MACD/AI_Work1/PanSpeed/` | `/Volumes/MACD/AI_Work1/macfanspeed/` |
| LaunchAgent ProgramArguments | `…/PanSpeed/PanSpeed` | `…/macfanspeed/PanSpeed` |
| 데몬 바이너리 | 구 경로 바이너리 | 신 경로 재빌드 후 복사 |

순서: LaunchAgent unload → 폴더 rename → 재빌드 → LaunchAgent 경로 수정 → 재로드.

### 6-3. ⚠️ 이때 발생한 세션 단절

Claude Code 는 작업 디렉토리 경로를 세션 식별자로 사용한다. 폴더 이름 변경 직후 새 디렉토리에서 시작된 세션은 이전 대화 컨텍스트를 잃는다. 따라서 이 문서가 필요해졌다.

---

## 7. 새 세션 (macfanspeed) 에서 이어진 작업

위 단절 이후 새 세션에서는 다음 작업이 진행됐다 (요약):

1. **이름 정합성 정리** — 코드 / 문서 / 데몬 plist / 실행파일의 `PanSpeed` → `FanSpeed`, `panspeed` → `fanspeed` 일괄 치환. 사용자가 처음에 이름을 잘못 정했음을 명시.
2. **중복 실행 차단** — `RunAtLoad` 자동 등록 + 수동 실행 충돌. `NSWorkspace.runningApplications` 로 차단.
3. **슬라이더 미세 조절** — step 50 → **1 RPM**.
4. **비밀번호 반복 묻기 버그 (재발)** — 원인: `String.write(atomically: true)` 가 `/Users/Shared/` (sticky 디렉토리) 의 root 소유 파일을 rename으로 못 덮어씀 (EPERM). 매번 commit 실패 → osascript 다이얼로그 반복. 수정: `FileHandle + truncate + write` in-place. 자세한 설명은 `ARCHITECTURE.md §9-4`.
5. **데몬 폴링 0.3초로 단축** (기존 2초 → 슬라이더 반응성 개선).
6. **README + 스크린샷 추가, GitHub public 공개**.
7. **SPEC.md 신규 작성**.

---

## 8. 교훈

- **폴더명에 제품명을 박아두는 것은 위험** — IDE 세션, LaunchAgent 경로, 데몬 plist 경로가 모두 폴더 경로에 종속된다. 이름 변경의 비용이 크다.
- **macOS sticky 디렉토리에서 root 소유 파일에는 Swift 표준 `write(atomically:true)` 금지** — 반드시 in-place 쓰기.
- **SMC 구조체는 C 와 정확히 같은 바이트 레이아웃** — Swift 의 자동 정렬에 맡기지 말고 명시 패딩.
- **LaunchAgent 의 `RunAtLoad: true`** 는 등록 즉시 한 번 더 실행됨 → 중복 인스턴스 차단 로직 필수.
