# Optional fan control: setup, updates and removal

[한국어](#한국어) · [English](#english) · [日本語](#日本語) · [简体中文](#简体中文)

## 한국어

기본 모니터링은 관리자 권한 없이 동작합니다. 실험적 팬 제어만 **지속 실행되는 root 도우미를 별도로 설치**해야 합니다. 다운로드·앱 실행·패널 열기만으로 설치하거나 냉각을 시작하지 않습니다.

DMG 안의 `Mac Thermal Fan Tools v2.16.0` 폴더를 쓰기 가능한 위치에 복사하거나 릴리즈의 `Mac-Thermal-v2.16.0-fan-tools.zip`을 풉니다. 이 폴더에는 개인 경로·UID·인증정보가 담긴 설치 매니페스트가 없습니다. Apple 공증을 받지 않은 커뮤니티 빌드이므로 소스·출처를 검토하세요. macOS가 차단하면 보안 검사를 끄거나 우회하지 말고 소스에서 빌드하세요. 준비에는 `/usr/bin/python3`를 제공하는 Xcode/Command Line Tools가 필요합니다.

아래 공통 명령은 **해당 Fan Tools 폴더 안에서** 실행합니다. 앱이 `/Applications` 외에 있으면 준비 명령의 앱 경로만 실제 위치로 바꾸세요. 준비는 일반 사용자로 실행하며 설치하지 않습니다. 생성된 `REVIEW.txt`, `MANIFEST.json`, `install.py`, `uninstall.py`를 확인한 뒤 설치 명령만 직접 관리자 권한으로 실행합니다. 비밀번호는 터미널에만 입력하세요. 설치 후 앱의 CPU → 팬 제어에서 RPM을 골라 시작합니다.

고정 RPM은 이후 부하가 늘면 Apple 자동 제어보다 냉각이 부족할 수 있고 소음·전력 사용을 늘릴 수 있습니다. 지원되지 않는 기기에서는 제어하지 않습니다. 100°C 이상 CPU 온도·높은 열 압박·온도 읽기 실패·잠자기·연결 끊김 시 자동 복귀를 요청하지만 하드웨어 보장은 아닙니다. 한 Mac의 시작·취소·앱 종료·10분 만료만 실기 확인했습니다. 실제 잠자기·도우미 강제 종료 복구와 다른 Mac은 미검증입니다.

## English

Basic monitoring needs no administrator access. Experimental fan control alone requires a **separately installed persistent root helper**. Downloading, launching or opening the panel never installs it or starts cooling.

Copy the versioned `Mac Thermal Fan Tools v2.16.0` folder from the DMG to a writable location, or extract `Mac-Thermal-v2.16.0-fan-tools.zip`. It contains no personal manifest, UID pin or credentials. Community builds are not Apple-notarized: review their source and origin. If macOS blocks them, build from source rather than disabling or bypassing security checks. Preparation requires Xcode/Command Line Tools providing `/usr/bin/python3`.

Run the common commands below **inside the extracted Fan Tools folder**. Change only the app path in the preparation command if needed. Prepare as your ordinary user; preparation does not install anything. Review the generated `REVIEW.txt`, `MANIFEST.json`, `install.py` and `uninstall.py`, then personally run the administrator installation command. Enter your password only in Terminal. After installation, choose RPM under CPU → Fan control and start the session.

A fixed RPM can provide less cooling than Apple automatic mode as load rises, and increase noise or power use. Unsupported hardware is not controlled. CPU temperature at or above 100°C, serious thermal pressure, unavailable temperature, sleep or disconnect request automatic mode; these are software safeguards, not hardware guarantees. Only start, cancel, app-exit recovery and the full ten-minute timeout were physically tested on one Mac. Physical sleep/wake, helper crashes and other Macs remain unverified.

## 日本語

通常の監視に管理者権限は不要です。実験的ファン制御だけは、**常駐するrootヘルパーを別途インストール**します。ダウンロード・起動・パネル表示だけではインストールや冷却を開始しません。

DMGのバージョン別Fan Toolsフォルダーを書き込み可能な場所へコピーするか、`fan-tools.zip`を展開します。個人用マニフェスト・UID設定・認証情報は含みません。Apple未公証のため出所とソースを確認し、ブロック時は保護を解除・回避せずソースからビルドしてください。準備には`/usr/bin/python3`を含むXcode/Command Line Toolsが必要です。

以下の共通コマンドは**展開したFan Toolsフォルダー内**で実行します。準備は一般ユーザーで実行し、必要に応じてアプリのパスだけ変更します。生成された`REVIEW.txt`・`MANIFEST.json`・インストール/削除スクリプトを確認し、管理者インストールは自身で行ってください。パスワードはターミナルのみに入力します。完了後、CPU → ファン制御からRPMを選んで開始します。

負荷が増えると固定RPMでは自動制御より冷却が不足する場合があり、騒音・電力消費も増えることがあります。高温・熱圧力・温度取得失敗・スリープ・切断時は自動復帰を要求しますが、ハードウェア保証ではありません。1台で開始・キャンセル・アプリ終了・10分終了を実測しました。他のMac、実際のスリープとヘルパー強制終了の復旧は未検証です。

## 简体中文

基础监控不需要管理员权限。仅实验性风扇控制需要**单独安装常驻root辅助程序**。下载、启动或打开面板都不会自动安装或开始冷却。

将DMG内按版本命名的Fan Tools文件夹复制到可写位置，或解压`fan-tools.zip`。其中不包含个人安装清单、UID绑定或凭据。此构建未经Apple公证，请检查来源与源码；被macOS阻止时请从源码构建，不要关闭或绕过保护。准备步骤需要提供`/usr/bin/python3`的Xcode/Command Line Tools。

请在**解压后的Fan Tools文件夹内**运行以下共用命令。以普通用户准备，必要时只修改应用路径。检查生成的`REVIEW.txt`、`MANIFEST.json`及安装/移除脚本后，再自行执行管理员安装。密码仅输入终端。安装后进入CPU → 风扇控制，选择RPM并开始。

负载增加时，固定RPM可能比Apple自动控制提供更少冷却，并增加噪音或耗电。高温、热压力、温度读取失败、睡眠或连接断开会请求自动恢复，但这些软件措施不是硬件保证。已在一台Mac实测开始、取消、应用退出恢复与完整10分钟到期。其他Mac、实际睡眠唤醒及辅助程序崩溃恢复尚未验证。

## Common commands / 공통 명령

Prepare only, without sudo or installation:

```sh
/usr/bin/python3 -I scripts/prepare_fan_installation.py "/Applications/Mac Thermal.app"
```

Review `build/fan-control-installation/REVIEW.txt` and the other generated files. Then, only if you choose administrator installation:

```sh
sudo /usr/bin/python3 -I build/fan-control-installation/install.py
```

### Updates and removal / 업데이트·제거 / 更新と削除 / 更新与移除

**Keep the entire matching versioned tools folder. Do not overwrite its generated package.** Before replacing/rebuilding/re-signing an app with an installed fan helper, end cooling, keep the old app available, and run the **old folder's matching uninstaller**:

```sh
sudo /usr/bin/python3 -I build/fan-control-installation/uninstall.py
```

The uninstaller inhibits new starts, verifies Apple automatic and only then removes the exact helper. If verification fails, it retains the helper/recovery data. Do not force-remove, unload, change code-hash pins or delete the recovery files. If app ownership or identity checks fail, do not change permissions to bypass them; use a reviewed user-owned installation or stop.

기존 버전 도구 폴더와 생성된 패키지를 그대로 보관하세요. 앱 교체 전에 **그 버전의 제거 스크립트**로 자동 복귀·제거를 확인합니다. 실패하면 강제로 삭제하지 마세요. 그 뒤 새 앱과 새 버전 도구 폴더로 새로 준비·검토·설치합니다. 새 앱 해시가 기존 도우미와 다르면 연결되지 않는 것이 정상적인 보호 동작입니다.

Preserve the old version's folder, remove with its matching script, then install the new app and prepare/review a new package in the new version's folder. Exact app hashes intentionally prevent an old helper from accepting a changed build. No automatic privileged update is provided.

旧バージョンのフォルダーを保持し、その削除スクリプトで自動モードと削除を確認してから更新してください。失敗時は強制削除しません。新しいアプリには新しいフォルダーで準備・確認・インストールします。コードハッシュ不一致時の接続拒否は意図した保護です。

保留旧版整个工具文件夹，更新应用前先运行匹配的旧版移除脚本，确认自动模式与移除成功。失败时不要强制删除。新应用应在新版文件夹中重新准备、检查和安装。哈希不一致时拒绝连接属于预期保护。

[Policy and recovery design](FAN_CONTROL.md) · [Attended physical tests](FAN_CONTROL_TESTS.md) · [Security](../SECURITY.md)
