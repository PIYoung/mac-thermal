# 코드·자산 출처

확인일: 2026-10-19. 적용 버전: v2.1.0부터.

- 앱 아이콘·패널 헤더의 표장: `scripts/DrawIcon.swift`의 직접 지정한 Bézier 도형으로 생성합니다. 외부 이미지, 글꼴, SF Symbols 또는 심볼에서 가져온 경로를 사용하지 않습니다.
- README의 아이콘 PNG는 위 원본 아이콘에서 생성합니다. `docs/images/readme-platforms.svg`의 메타데이터 표시는 직접 작성한 도형·텍스트이며 외부 배지 서비스를 사용하지 않습니다.
- README 메뉴바 GIF·PNG와 4개 언어 자원·Codex 패널 PNG는 `scripts/render-readme-assets.sh`로 재생성합니다. 합성 예시 수치를 실제 앱 렌더러로 그리며, 사용자 화면·실제 프로세스 이름·실시간 수집값을 공개 이미지에 넣지 않습니다. 메뉴바를 감싼 둥근 배경은 문서용 자체 도형입니다.
- README의 헤더·소개·다운로드·접이식 안내 구성은 [Best-README-Template](https://github.com/othneildrew/Best-README-Template)을 참고했습니다. [Unlicense 원문](https://github.com/othneildrew/Best-README-Template/blob/main/LICENSE.txt)을 2026-10-15에 확인했으며, 원본 소개 문구·로고·이미지는 포함하지 않았습니다. 문서 문구·HTML·이미지는 이 프로젝트에서 작성합니다.
- 그래프·탭·유리 카드: 프로젝트에서 직접 작성한 AppKit/QuartzCore 코드입니다. 다른 앱의 소스나 화면 자산을 복제하지 않습니다.
- GPU 수집기: 프로젝트에서 직접 작성한 IOKit 레지스트리 조회 코드입니다. 외부 앱 소스·라이브러리를 추가하지 않으며 GPU 사용률은 드라이버 속성값을 검증해 표시합니다.
- GPU 4×3 타일과 밝기 파동: 직접 지정한 둥근 사각형과 수학식으로 구현합니다. 격자의 칸 수는 사용률 눈금이며 다른 앱의 아이콘·셰이더·애니메이션 코드나 벡터 경로를 사용하지 않습니다.
- 디스크 정리 화면·검색·휴지통 이동: 이 프로젝트에서 직접 작성한 AppKit·Foundation·POSIX 코드입니다. 외부 정리 도구·규칙 데이터·패키지·이미지를 포함하지 않으며, 네 언어 문구도 직접 작성합니다.
- Codex 메뉴바 로봇: 직접 지정한 사각형·원·선과 네 자세로 그린 Core Graphics 도형입니다. [RunCat Runner Gallery](https://runcat-dev.github.io/RunnerGallery/)는 작은 단색 동작의 참고 자료로만 보았으며 해당 저장소의 이미지·프레임·벡터 경로·코드를 가져오지 않았습니다. Codex 로고나 다른 앱의 캐릭터도 포함하지 않습니다.
- Codex 보조 패널·로컬 기록 집계: 이 프로젝트에서 작성한 AppKit·Foundation 코드와 시스템 기능 아이콘입니다. Codex의 로고·UI 자산·소스 코드·바이너리를 복제하거나 배포하지 않습니다. 외부 패키지·Codex 바이너리는 번들에 포함하지 않습니다. 선택적인 계정 한도 기능은 사용자가 별도로 설치한 OpenAI 서명 Codex 실행 파일을 공식 stdio 프로토콜로 호출합니다.
- CPU 사용률: 시스템 CPU tick 차이를 사용합니다. 그래프는 실제 측정값만 표시하며 추가 라이브러리를 사용하지 않습니다.
- 메뉴바 리듬 막대·순환 점·방향성 전송 입자·SSD 물결: 이 프로젝트에서 직접 작성한 Core Graphics 도형과 수학식입니다. 외부 아이콘·셰이더·애니메이션 라이브러리·벡터 경로를 사용하지 않습니다. CPU·SSD 활동·네트워크 값에 동작을 연결하고 용량 채움은 실제 사용 비율을 나타냅니다.
- 한국어·영어·일본어·중국어 간체 UI 문구: 이 프로젝트에서 직접 작성한 번역입니다. 외부 번역 패키지·사전 데이터·온라인 번역 서비스는 포함하거나 호출하지 않습니다.
- 부팅 후 경과 시간: macOS의 `mach_continuous_time`과 `mach_timebase_info`를 사용합니다.
- 센서 프로토콜·키 매핑: Stats를 기술 참고로 사용했습니다. 출처와 저장소 MIT 고지(2019), 참고 파일의 개별 저작권 고지(2020·2021), MIT 허가문 전체는 `THIRD_PARTY_NOTICES.txt`에 있으며 앱 번들에도 포함합니다.
- 앱 내부 기능 아이콘·텍스트: macOS 시스템 API의 SF Symbols와 시스템 글꼴로 표시합니다. 글꼴 파일·Apple 제품 이미지를 따로 복사하거나 재배포하지 않습니다.

Apple의 SF Symbols 지침은 앱 아이콘·로고·상표 용도에 심볼이나 혼동할 만큼 유사한 이미지를 사용하는 것을 금지합니다. v2.1.0 앱 아이콘은 원래 사용하던 SF Symbol을 제거하고 자체 디자인으로 교체했습니다.

공식 지침: https://developer.apple.com/design/human-interface-guidelines/sf-symbols

이 문서는 코드·자산의 출처와 사용 범위를 기록합니다. Mac Thermal 자체 코드는 루트 LICENSE의 MIT 라이선스로 공개합니다. Stats 참고 부분의 기존 저작권 및 MIT 고지는 THIRD_PARTY_NOTICES.txt에 그대로 보존합니다. SF Symbols와 macOS 시스템 글꼴은 Apple의 이용 조건이 적용되며 MIT로 재허가하지 않습니다. 공개 배포에는 현재 검토된 소스와 새로 빌드한 앱만 포함하고, 과거의 로컬 복구용 보관본은 포함하지 않습니다.

- 이전 계정 일별 그래프와 호버 말풍선은 자체 AppKit 도형이었으며 v2.10.1에서 제거했습니다. 외부 차트 코드·이미지·라이브러리는 사용하지 않습니다.


- Codex 상세 지표: 입력·출력 구성 막대, 숫자 카드와 펼침 UI는 이 프로젝트에서 작성한 AppKit 도형·시스템 글꼴입니다. 외부 코드·이미지·차트 패키지를 추가하지 않습니다.

- Codex·설정 공용 커스텀 스크롤바: 자체 NSBezierPath·NSGradient로 그린 3pt 손잡이와 6pt 강조 상태입니다. AppKit NSScroller의 드래그·페이지 이동·접근성 동작은 유지하며 외부 자산이나 코드를 추가하지 않습니다.

- 선택형 한도 리셋 알림: 이 프로젝트에서 작성한 상태 비교·설정 코드와 macOS UserNotifications API를 사용합니다. 설정의 bell.badge는 앱 내부 알림 기능을 설명하는 시스템 SF Symbol이며, 외부 코드·아이콘 파일·패키지는 추가하지 않습니다.

- 홈 자동 검사: 이 프로젝트에서 작성한 Foundation·POSIX 메타데이터 검사와 AppKit 선택·확인 UI입니다. 새 외부 코드·파일 판별 데이터베이스·아이콘·패키지는 추가하지 않습니다.

- CPU 팬 상태·회전수 행과 항목별 온도 경고는 자체 AppKit UI입니다. fanblades.fill은 앱 내부 팬 기능용 시스템 SF Symbol입니다. 팬은 기존 SMC 연결에서 FNum/FnAc만 읽고, 제어·속도 변경·관리자 helper·추가 라이브러리를 포함하지 않습니다. 키 매핑 참고 출처와 MIT 고지는 THIRD_PARTY_NOTICES.txt에 보존합니다.

- GPU 온도 행·메모리 주변 온도 행은 자체 AppKit UI와 시스템 글꼴입니다. 확인된 M4 계열 SMC 키 또는 명시적으로 GPU로 이름 붙은 HID 센서만 읽고 PMU를 대체 온도로 쓰지 않습니다. 메모리 주변 온도는 메모리 칩 내부 온도로 표현하지 않습니다. 센서 매핑은 기존 Stats v3.0.21 values.swift 참고 범위이며 MIT 고지를 보존합니다.

- 상태 안내·AI 설명 화면: 자체 AppKit 카드와 기존 GlassScroller를 재사용합니다. 외부 이미지·아이콘·모델·패키지를 추가하지 않습니다. Foundation Models는 macOS가 제공하는 선택형 시스템 프레임워크이며 SystemLanguageModel.default만 사용합니다. 생성 문구와 별도로 측정 근거·기본 안내·고정 행동 버튼을 표시합니다.

Codex robot idle/active motion reuses the original four geometric typing poses at two cadences. No external animation, sprite, library or model is added.

The compact AI header button uses the untinted native AppKit glass bezel with blue lettering on macOS 26+, an original translucent fallback on older macOS, and the system sparkles/back symbols inside the app. No external artwork, package or repeating animation is added.
