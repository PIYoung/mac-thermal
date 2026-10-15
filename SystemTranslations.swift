import Foundation

extension L10n {
    // Original translations. Values are English, Japanese, and Simplified Chinese.
    static let systemTranslations: [String: [String]] = [
        "정상": ["Normal", "正常", "正常"],
        "약간 높음": ["Elevated", "やや高温", "温度偏高"],
        "높음": ["High", "高温", "高温"],
        "냉각 필요": ["Cooling needed", "冷却が必要", "需要降温"],
        "확인 불가": ["Unavailable", "取得できません", "无法获取"],
        "측정 중": ["Measuring", "測定中", "测量中"],
        "macOS 열 상태가 정상 범위입니다": ["macOS thermal state is normal", "macOSの温度状態は正常です", "macOS温度状态正常"],
        "macOS가 온도 상승을 감지했습니다": ["macOS detected rising temperatures", "macOSが温度の上昇を検知しました", "macOS检测到温度升高"],
        "부하를 줄이고 통풍을 확인하세요": ["Reduce workload and check ventilation", "負荷を減らし、通気を確認してください", "请减少负载并检查通风"],
        "열이 시스템 성능에 영향을 주고 있습니다": ["Heat is affecting system performance", "高温がシステムの性能に影響しています", "高温正在影响系统性能"],
        "열 상태를 확인할 수 없습니다": ["Thermal state is unavailable", "温度状態を取得できません", "无法获取温度状态"],
        "로그인 자동 실행은 macOS 13 이상에서 사용할 수 있습니다.": ["Launch at login requires macOS 13 or later.", "ログイン時の自動起動にはmacOS 13以降が必要です。", "登录时自动启动需要macOS 13或更高版本。"],
        "이 앱의 로그인 항목을 찾을 수 없습니다. 앱 설치 위치와 코드 서명을 확인해 주세요.": ["This app’s login item could not be found. Check the app’s installation location and code signature.", "このアプリのログイン項目が見つかりません。アプリのインストール先とコード署名を確認してください。", "找不到此应用的登录项。请检查应用的安装位置和代码签名。"],
        "로그인 자동 실행이 켜진 상태를 확인하지 못했습니다.": ["Could not confirm that launch at login is enabled.", "ログイン時の自動起動が有効になったことを確認できませんでした。", "无法确认登录时自动启动已启用。"],
        "로그인 자동 실행이 꺼진 상태를 확인하지 못했습니다.": ["Could not confirm that launch at login is disabled.", "ログイン時の自動起動が無効になったことを確認できませんでした。", "无法确认登录时自动启动已停用。"],
        "자동 실행: macOS 13 이상 필요": ["Launch at login: macOS 13+ required", "自動起動：macOS 13以降が必要", "自动启动：需要macOS 13或更高版本"],
        "로그인 시 자동 실행: 꺼짐": ["Launch at login: Off", "ログイン時に自動起動：オフ", "登录时自动启动：关"],
        "로그인 시 자동 실행: 켜짐": ["Launch at login: On", "ログイン時に自動起動：オン", "登录时自动启动：开"],
        "자동 실행: 시스템 설정에서 승인 필요": ["Launch at login: Approve in System Settings", "自動起動：システム設定での許可が必要", "自动启动：需要在系统设置中批准"],
        "자동 실행 항목을 찾을 수 없음": ["Login item not found", "ログイン項目が見つかりません", "找不到登录项"],
        "자동 실행 상태 확인 불가": ["Login item status unavailable", "自動起動の状態を取得できません", "无法获取自动启动状态"],
        "부팅 후 시간 확인 불가": ["Uptime unavailable", "起動後の時間を取得できません", "无法获取运行时间"],
        "부팅 후 %d일 %d시간 %d분": ["Uptime: %d d %d h %d min", "起動後 %d日%d時間%d分", "已运行 %d天%d小时%d分钟"],
        "부팅 후 %d시간 %d분": ["Uptime: %d h %d min", "起動後 %d時間%d分", "已运行 %d小时%d分钟"],
        "부팅 후 %d분": ["Uptime: %d min", "起動後 %d分", "已运行 %d分钟"],
        "부팅 후 1분 미만": ["Uptime: less than 1 min", "起動後1分未満", "运行不足1分钟"],
        "리듬 막대": ["Rhythm bars", "リズムバー", "律动条"],
        "순환 점": ["Orbiting dots", "回転ドット", "环绕圆点"],
        "Mac Thermal · %@\nCPU %@ / 사용률 %@\nSSD 읽기 %@ · 쓰기 %@\nSSD 사용 용량 %@ · 온도 %@\n업로드 %@ · 다운로드 %@\n%@ · 클릭하면 패널과 메뉴바 설정": [
            "Mac Thermal · %@\nCPU %@ / Usage %@\nSSD read %@ · Write %@\nSSD storage used %@ · Temperature %@\nUpload %@ · Download %@\n%@ · Click for the panel and menu bar settings",
            "Mac Thermal · %@\nCPU %@ / 使用率 %@\nSSD読み込み %@ · 書き込み %@\nSSD使用容量 %@ · 温度 %@\nアップロード %@ · ダウンロード %@\n%@ · クリックしてパネルとメニューバー設定を開く",
            "Mac Thermal · %@\nCPU %@ / 使用率 %@\nSSD读取 %@ · 写入 %@\nSSD已用容量 %@ · 温度 %@\n上传 %@ · 下载 %@\n%@ · 点击打开面板和菜单栏设置"
        ],
        "Mac Thermal, CPU %@, 사용률 %@, SSD 읽기 %@, 쓰기 %@, 저장 공간 사용 %@, 업로드 %@, 다운로드 %@, 열 상태 %@, 메뉴바 %@": [
            "Mac Thermal, CPU %@, usage %@, SSD read %@, write %@, storage used %@, upload %@, download %@, thermal state %@, menu bar %@",
            "Mac Thermal、CPU %@、使用率 %@、SSD読み込み %@、書き込み %@、ストレージ使用量 %@、アップロード %@、ダウンロード %@、温度状態 %@、メニューバー %@",
            "Mac Thermal，CPU %@，使用率 %@，SSD读取 %@，写入 %@，存储空间已用 %@，上传 %@，下载 %@，温度状态 %@，菜单栏 %@"
        ]
    ]
}
