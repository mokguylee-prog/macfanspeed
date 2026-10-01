import AppKit

private var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
    checks += 1
}

func sample(_ type: String, _ bytes: [UInt8], size: UInt32? = nil) -> SMCVal {
    SMCVal(dataSize: size ?? UInt32(bytes.count),
           dataType: type.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }, bytes: bytes)
}

// 실제 M5 Pro에서 읽은 최소/최대 RPM과 Intel 표준 형식의 알려진 값.
check(sample("flt ", [0x00, 0xc0, 0xa8, 0x44]).number == 1350, "M5 최소 RPM")
check(sample("flt ", [0x00, 0x28, 0xa7, 0x45]).number == 5349, "M5 팬 1 최대 RPM")
check(sample("flt ", [0x00, 0x88, 0xb4, 0x45]).number == 5777, "M5 팬 2 최대 RPM")
check(sample("fpe2", [0x1f, 0x40]).number == 2000, "Intel RPM 빅엔디안")
check(sample("fpe2", [0x1f, 0x43]).number == 2000.75, "fpe2 소수부")
check(sample("sp78", [0x32, 0x80]).number == 50.5, "Intel CPU 온도")
check(sample("sp78", [0xff, 0x80]).number == -0.5, "sp78 부호")
check(sample("ui8 ", [2]).number == 2, "팬 개수")
check(sample("ui16", [1, 0]).number == 256, "수동 제어 비트마스크")
check(sample("ui32", [0, 0, 0x0d, 0xac]).number == 3500, "SMC 키 개수")
check(sample("flt ", [0, 0, 0, 0]).number == 0, "정지한 팬은 유효한 0 RPM")
check(sample("flt ", [0, 0, 0]).number == nil, "잘린 float 거부")
check(sample("fpe2", [0x1f, 0x40], size: 4).number == nil, "키 크기 불일치 거부")
check(sample("flt ", [0, 0, 0xc0, 0x7f]).number == nil, "NaN 거부")
check(sample("flt ", [0, 0, 0x80, 0x7f]).number == nil, "무한대 거부")
check(sample("xxxx", [0, 0]).number == nil, "알 수 없는 타입 거부")
check(sample("fpe2", [0, 0]).encoding(2000) == [0x1f, 0x40], "Intel 목표 RPM 인코딩")
check(sample("flt ", [0, 0, 0, 0]).encoding(1350) == [0, 0xc0, 0xa8, 0x44], "M5 목표 RPM 인코딩")
check(sample("fpe2", [0, 0]).encoding(20000) == nil, "fpe2 오버플로 거부")
check(sample("flt ", [0, 0, 0, 0]).encoding(-1) == nil, "음수 목표 RPM 거부")
check(sample("ui8 ", [0]).encoding(1) == [1], "New 모델 수동 모드")
check(sample("ui8 ", [0]).encoding(256) == nil, "모드 오버플로 거부")

// GUI의 모델 선택이 root 데몬까지 전달되고 이전 형식도 유효해야 한다.
for model in MacModel.allCases {
    for rpm: Int? in [nil, 1350, 5777] {
        let command = FanCommand(model: model, rpm: rpm)
        check(FanCommand(payload: command.payload) == command, "모델별 IPC 명령 전달")
    }
}
let oldAuto = FanCommand(payload: "auto")
check(oldAuto != nil && oldAuto?.rpm == nil, "이전 자동 명령")
check(FanCommand(payload: "2000")?.rpm == 2000, "이전 수동 명령")
for payload in ["", " ", "new", "new -1", "new 30001", "bad 2000", "new auto extra"] {
    check(FanCommand(payload: payload) == nil, "잘못된 IPC 명령 거부: \(payload)")
}

// GUI 이벤트로 스위치 콜백, 실패 시 복귀, 0 RPM/센서 없음/팬 없음 표시를 확인한다.
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let view = MenuView(minRPM: 1350, maxRPM: 5777, autoStartOn: false, model: .new)
func labels() -> [String] { view.subviews.compactMap { ($0 as? NSTextField)?.stringValue } }
view.updateReadout(FanReadout(model: .new, fanCount: 2, rpms: [2000, 3000],
                              temperature: 50.5, minRPM: 1350, maxRPM: 5777))
check(labels().contains("2000"), "자동 모드에서도 실제 RPM을 크게 표시")
check(labels().contains("팬 1  2000 RPM\n팬 2  3000 RPM"), "두 팬 개별 표시")
let toggle = view.subviews.compactMap { $0 as? NSSwitch }
    .first { $0.identifier?.rawValue == "modelToggle" }!
var selected: MacModel?
view.onModelChange = { selected = $0; return true }
toggle.state = .off
_ = toggle.sendAction(toggle.action!, to: toggle.target)
check(selected == .legacy, "OFF 선택이 이전 모델로 전달됨")
check(labels().contains(MacModel.legacy.title), "선택 모델 안내")
view.onModelChange = { _ in false }
toggle.state = .on
_ = toggle.sendAction(toggle.action!, to: toggle.target)
check(toggle.state == .off, "모델 변경 실패 시 스위치 복귀")
view.onModelChange = { selected = $0; return true }
toggle.state = .on
_ = toggle.sendAction(toggle.action!, to: toggle.target)
check(selected == .new, "ON 선택이 New 모델로 전달됨")
view.updateReadout(FanReadout(model: .new, fanCount: 2, rpms: [0, nil],
                              temperature: nil, minRPM: 1350, maxRPM: 5777))
check(labels().contains("0"), "0 RPM 유지")
check(labels().contains("팬 1  0 RPM\n팬 2  읽기 불가"), "정지와 읽기 실패 구분")
check(labels().contains("CPU  읽기 불가"), "이전 온도 값 삭제")
view.updateReadout(FanReadout(model: .new, fanCount: 0, rpms: [],
                              temperature: 40, minRPM: 1200, maxRPM: 6200))
check(labels().contains("냉각 팬이 없는 모델"), "팬 없는 모델 표시")
check(view.subviews.compactMap { $0 as? VerticalRPMSlider }.allSatisfy { !$0.isEnabled },
      "팬 없는 모델 제어 비활성화")

// 모델 변경 시 저장 값과 센서 프로필이 함께 바뀌며 관리자 권한을 요청하지 않는다.
let preferences = UserDefaults(suiteName: "com.fanspeed.app")!
let originalPreference = preferences.string(forKey: "macModel")
let manager = FanManager.shared
let originalModel = manager.model
if originalModel == .legacy { check(manager.selectModel(.new), "저장 테스트 준비") }
check(manager.selectModel(.legacy), "이전 모델 선택 성공")
check(preferences.string(forKey: "macModel") == "legacy", "이전 모델 선택 저장")
check(manager.readout().model == .legacy, "이전 모델 센서 프로필 적용")
check(manager.selectModel(.new), "New 모델 선택 성공")
check(preferences.string(forKey: "macModel") == "new", "New 모델 선택 저장")
check(manager.readout().model == .new, "New 모델 센서 프로필 적용")
check(manager.selectModel(originalModel), "기존 선택 복원")
if let originalPreference { preferences.set(originalPreference, forKey: "macModel") }
else { preferences.removeObject(forKey: "macModel") }

// 동일한 실제 뷰를 화면 밖에서 렌더링하여 레이아웃을 검토할 수 있다.
if let index = CommandLine.arguments.firstIndex(of: "--preview"),
   CommandLine.arguments.indices.contains(index + 1) {
    view.updateReadout(FanReadout(model: .new, fanCount: 2, rpms: [0, 0],
                                  temperature: 39, minRPM: 1350, maxRPM: 5777))
    view.layoutSubtreeIfNeeded()
    if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        }
    }
}
print("통과: \(checks)개 검증")
