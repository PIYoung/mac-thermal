# Mac Thermal

**한국어** · [English](README.en.md) · [日本語](README.ja.md) · [简体中文](README.zh-CN.md)

작은 메뉴 막대 안에서 Mac의 온도와 자원 사용량을 한눈에 보는 무료 오픈소스 앱입니다. 실측값을 가벼운 움직임과 함께 표시합니다.

**AI로 제작했습니다.** 코드, UI, 번역과 문서는 OpenAI Codex를 활용하고 사용자의 반복적인 피드백을 반영해 만들었습니다.

![Mac Thermal CPU 패널](docs/images/mac-thermal-cpu.png)

실제 UI를 합성 예시 데이터로 렌더링했습니다. macOS 버전에 따라 유리 효과가 다를 수 있습니다.

## 주요 기능

- **메뉴 막대:** CPU 온도·사용률, SSD 읽기·쓰기, 네트워크 업로드·다운로드 속도.
- **움직이는 지표:** CPU 리듬 막대 또는 순환 점, 전송 방향으로 흐르는 네트워크, 사용 용량을 채우고 I/O 활동에 맞춰 물결치는 SSD.
- **자원별로 자세히:** CPU·메모리·SSD·네트워크 탭으로 사용량과 그래프를 확인합니다. CPU·메모리 탭은 해당 자원을 많이 쓰는 프로세스 TOP 3를 함께 보여주고, CPU·SSD 온도는 보조 정보로 표시합니다. 부팅 후 경과 시간도 확인할 수 있습니다.
- **내 취향대로:** 설정 맨 위에서 한국어·영어·일본어·중국어 간체를 즉시 전환하고, 움직임·강도·로그인 시 자동 실행을 설정합니다. 기본 언어는 한국어입니다.
- **macOS에 맞게:** 밝은·어두운 모드, macOS 26의 Liquid Glass, 동작 줄이기와 키보드 탐색을 지원합니다.
- **로컬에서만:** 계정, 광고, 분석·추적, 서버 전송, 관리자 helper, 팬 제어가 없습니다.

## 설치

**Apple Silicon Mac · macOS 14 이상**이 필요합니다. 현재 배포 파일은 ARM64 전용입니다. Intel Mac은 지원하지 않습니다.

1. [최신 DMG 다운로드](https://github.com/PIYoung/mac-thermal/releases/latest/download/Mac-Thermal-v2.4.0-arm64.dmg).
2. DMG를 열고 **Mac Thermal.app**을 **Applications** 폴더로 드래그합니다.
3. 앱을 실행하고 메뉴 막대의 지표를 클릭합니다. Dock 아이콘은 표시하지 않습니다.

ZIP이 필요하면 [릴리스 페이지](https://github.com/PIYoung/mac-thermal/releases/latest)에서 받을 수 있습니다. 자동 업데이트 기능은 없으며 새 버전은 릴리스에서 설치합니다.

현재 바이너리는 **ad-hoc 서명**되어 있으며 Apple Developer ID 서명·공증을 받지 않았습니다. 다운로드한 앱은 macOS Gatekeeper에 의해 차단될 수 있습니다. 실행이 차단되면 보안 설정을 해제하는 대신 아래 소스 빌드 방법을 사용하세요. 내려받은 파일은 릴리스의 `SHA256SUMS`와 대조할 수 있습니다.

### 소스에서 빌드·설치

Apple Silicon Mac과 **macOS 26 SDK를 포함한 Xcode 26 또는 호환 Command Line Tools**가 필요합니다. 실행 대상은 macOS 14 이상이며, macOS 26 이전에는 표준 반투명 패널을 사용합니다.

```sh
git clone https://github.com/PIYoung/mac-thermal.git
cd mac-thermal
zsh scripts/install.sh --open
```

로컬에서 빌드해 `~/Applications/Mac Thermal.app`에 설치한 뒤 실행합니다. 실행하지 않고 설치만 하려면 `--open`을 빼세요. `sudo`는 사용하지 않습니다. 빌드만 하려면 `zsh build.sh`를 실행하세요. 결과는 `build/Mac Thermal.app`입니다.

## 사용하기

메뉴 막대를 클릭하면 고정 크기 패널이 열립니다. 오른쪽 위 **설정** 아이콘으로 설정을 열고 닫습니다. 처음에는 CPU 탭이 열리고, 이후에는 마지막으로 본 탭을 기억합니다. 언어·탭·움직임 설정은 다음 실행에도 유지됩니다. 로그인 시 자동 실행은 **설정 → 로그인 시 자동 실행**에서 관리합니다. 소스 설치 스크립트의 대상인 `~/Applications`에서 실행할 때만 첫 실행 시 자동으로 등록하며, DMG를 통해 `/Applications`에 설치한 경우에는 자동 등록하지 않습니다. macOS가 승인을 요청하면 시스템의 로그인 항목에서 허용해야 합니다.

열 상태가 높아지면 메뉴 막대 글자가 주황색 또는 빨간색으로 바뀝니다. 이 상태는 macOS가 보고하는 열 상태이며, 임의의 온도 임계값이 아닙니다. 앱은 냉각이나 팬 속도를 조절하지 않습니다.

## 알아둘 점

- CPU 온도는 읽을 수 있는 코어 센서의 **최댓값**입니다. 현재 **Apple M4 Pro에서 검증**했으며 다른 칩의 센서 호환성은 확인하지 않았습니다. 조회할 수 없는 값은 `—`로 표시합니다.
- 메모리 온도는 제공하지 않습니다. 메모리 사용량·압박·압축·스왑을 표시합니다.
- TOP 3는 **프로세스별** 순위이며 앱의 여러 프로세스를 합산하지 않습니다. CPU 비율은 전체 논리 코어 기준입니다.
- SSD I/O는 내부 물리 SSD 전체, 네트워크는 활성 `en*` 인터페이스 기준입니다. VPN·loopback은 합산하지 않습니다.
- 지표는 2초마다 수집합니다. 그래프는 메모리에만 유지하고, 애니메이션은 최대 8fps입니다.

정확한 계산 방법, 표시 단위와 호환성 한계는 [기술 설명](docs/DETAILS.md)을 참고하세요.

## 기여와 라이선스

[이슈](https://github.com/PIYoung/mac-thermal/issues)로 버그·번역·기능 제안을 보내거나 [기여 안내](CONTRIBUTING.md)에 따라 PR을 보내주세요. 센서 문제를 제보할 때 Mac 칩과 macOS 버전을 알려주면 도움이 됩니다. 개인 정보와 다른 앱의 프로세스 이름은 가려 주세요.

프로젝트 소스 코드는 [MIT 라이선스](LICENSE)로 배포합니다. Stats의 센서 프로토콜·키 매핑을 참고한 부분의 저작권과 MIT 고지는 [THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt)에 보존합니다. 앱 아이콘·그래프·움직임은 자체 구현이며 Stats의 UI 자산을 포함하지 않습니다. 시스템에서 표시하는 Apple 심볼·글꼴에는 해당 제공자의 조건이 적용됩니다. [코드·자산 출처](ASSET_PROVENANCE.md)를 확인하세요.
