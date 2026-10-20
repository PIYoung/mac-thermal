<p align="center"><img src="docs/images/app-icon.png" alt="Mac Thermal" width="64" height="64"></p>
<h1 align="center">Mac Thermal</h1>
<p align="center"><strong>Macの状態を、メニューバーでひと目に。</strong><br>Apple Silicon · macOS 14+ · MIT</p>
<p align="center"><a href="README.md">한국어</a> · <a href="README.en.md">English</a> · <strong>日本語</strong> · <a href="README.zh-CN.md">简体中文</a></p>
<p align="center"><a href="https://github.com/PIYoung/mac-thermal/releases/latest"><strong>↓ ダウンロード</strong></a> · <a href="RELEASES.md">更新履歴</a></p>

## メニューバーとパネル

<p align="center"><img src="docs/images/menubar.png" alt="CodexロボットとCPU・GPU・SSD・ネットワークのメニューバー" width="460"></p>
<table align="center">
  <tr><th>Codex補助パネル</th><th>リソースパネル</th></tr>
  <tr>
    <td><a href="docs/images/codex-ja-light.png"><img src="docs/images/codex-ja-light.png" alt="Codex補助パネル" width="190"></a></td>
    <td><a href="docs/images/panel-ja-cpu.png"><img src="docs/images/panel-ja-cpu.png" alt="リソースパネル" width="215"></a></td>
  </tr>
</table>
<sub>実際のアプリ描画による合成例です。半透明効果はmacOSのバージョンで異なります。</sub>

## 主な機能

- **メニューバー:** CPU温度・使用率、GPU使用率、SSD読み書き、ネットワーク速度と動く指標。
- **クリックでパネル:** CPU・GPU・メモリ・SSD・通信タブ、最近のグラフ、CPU・メモリ上位3プロセス、起動後の経過時間。
- **Codex:** 左の補助パネルにアプリ実行時間・今日のローカルトークン・モデル別使用量。新しいトークン記録を検出するとメニューバーのロボットが動きます。
- **ディスク整理:** 選んだフォルダの候補を確認し、最終確認後に選択ファイルをゴミ箱へ移動。
- **設定:** 表示項目・動き・ログイン時の起動を変更。韓国語が既定で、英語・日本語・簡体字中国語にも対応。

## インストール

1. [最新リリース](https://github.com/PIYoung/mac-thermal/releases/latest)から**DMG**をダウンロードします。ZIPもあります。
2. DMGを開き、**Mac Thermal.app**を**Applications**へドラッグします。
3. 起動してメニューバーをクリックします。更新時は新しいリリースをインストールします。

> このビルドはad-hoc署名で、Appleの公証はありません。macOSがブロックした場合、セキュリティ設定を解除せず下記のソースビルドをご利用ください。配布ファイルは`SHA256SUMS`で検証できます。

<details>
<summary>ソースからビルド・インストール</summary>

Apple Siliconと、macOS 26 SDKを含むXcode 26または互換Command Line Toolsが必要です。

```sh
git clone https://github.com/PIYoung/mac-thermal.git
cd mac-thermal
zsh scripts/install.sh --open
```

既存のアプリを終了してから実行してください。`~/Applications`にインストールします。`sudo`は不要です。

</details>

## Codex記録とプライバシー

Codex記録の読み取りは**既定でOFF**です。オンにすると`~/.codex/sessions`からモデル名・トークン数・時刻のみメモリに集計します。ファイルには会話本文もありますが、本文・コマンド・認証情報は保管・表示・送信せず、元ファイルも変更しません。オフで読み取りを止め、集計を消去します。

対象は**このMacの今日の記録（UTC）**で、アカウント全体の使用量・請求額ではありません。任意の[公式ログイン連携](docs/CODEX_ACCOUNT.md)で、パネルにアカウントの残り上限とリセット時刻を表示できます。ロボットは追加の記録がないと10秒後に止まり、リアルタイムのトークン消費や作業完了を示しません。

---

[技術説明](docs/DETAILS.md) · [セキュリティ](SECURITY.md) · [貢献](CONTRIBUTING.md) · [MITライセンス](LICENSE) · [サードパーティ通知](THIRD_PARTY_NOTICES.txt)

<sub>OpenAI Codexとユーザーのフィードバックを活用し、AIの支援で制作しました。</sub>
