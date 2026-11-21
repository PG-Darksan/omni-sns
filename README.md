# OmniSNS — Windows & Android 向け 全SNS・マッチングアプリ統合ブラウザ

**OmniSNS** は、Webブラウザから **DM / メッセージ送信に対応した主要SNS・メッセンジャー・マッチングアプリ（全61種＋カスタムURL）** を、1つのアプリ内で切り替えて使える統合ブラウザアプリです。

- **Windows 版**: Electron + `WebContentsView`（サービスごと完全セッション分離 / インストーラー＆ポータブル `.exe`）
- **Android 版**: Flutter + Android WebView（下部クイックタブ切替 / ドロワー並び替え / リリース `.apk`）

> ビルド済みバイナリ（Windows `.exe` / Android `.apk`）は **[GitHub Releases](https://github.com/PG-Darksan/omni-sns/releases)** からダウンロードできます。

---

## 主な特徴

- **全61種のDM送信対応SNS・マッチングアプリをプリセット収録（Windows / Android 共通カタログ）**
  - メジャーSNS、チャット/メッセンジャー、国内・海外マッチングアプリ、出会い系、ビジネス/創作系まで網羅
  - Mastodon / Misskey の独自インスタンスや社内チャットも「カスタム追加」から自由に登録可能
- **PC版 / モバイル版 User-Agent をタブごとにワンクリック切替**
  - 標準でクリーンな最新 Chrome User-Agent を設定し、WhatsApp Web・Snapchat Web・mixi2・東カレデート等に対応
  - Windows版では独立パーティション（`persist:omnisns-<instanceId>`）による完全セッション分離＆マルチアカウント・OAuthポップアップに対応
- **プライバシー保護機能**
  - **クイックロック**: ワンクリック（Windowsは `Ctrl + Shift + L`）で全画面を即座に隠蔽（任意PINコード対応）
  - **マッチング・出会い系の一括表示/非表示切替**: タブ一覧とカタログからワンクリックで隠蔽
- **メモリ節約 & 快適操作**
  - 遅延ロード + **タブ休止（スリープ）** で多数のSNSを登録しても軽量動作
  - 未読バッジ自動集計、ドラッグ＆ドロップ並び替え、ダーク/ライトテーマ対応

---

## プリセット収録サービス一覧（全61種）

### 1. メジャーSNS (17種)
`X (旧Twitter)` / `Instagram` / `Threads` / `Facebook Messenger` / `Facebook` / `Bluesky` / `mixi2` / `TikTok` / `Snapchat` / `Reddit` / `Pinterest` / `Tumblr` / `Mastodon` / `Misskey` / `Weibo (微博)` / `VK (VKontakte)` / `mixi (初代)`

### 2. チャット・メッセンジャー (12種)
`Discord` / `Telegram` / `WhatsApp Web` / `Slack` / `Microsoft Teams` / `Chatwork` / `Google Chat` / `BAND` / `Element (Matrix)` / `Twitch` / `Steam Chat` / `Googleメッセージ Web (SMS/RCS)`

### 3. 国内マッチング・婚活 (9種)
`Pairs (ペアーズ)` / `with (ウィズ)` / `タップル (tapple)` / `Omiai (オミアイ)` / `マリッシュ (marrish)` / `アンジュ (ange)` / `ユーブライド (youbride)` / `ブライダルネット` / `東カレデート`

### 4. 海外マッチング (7種)
`Tinder` / `Bumble` / `OkCupid` / `Match (マッチドットコム)` / `Badoo` / `Plenty of Fish (POF)` / `Grindr Web`

### 5. 国内メッセージ系・出会い系 (4種)
`ハッピーメール` / `ワクワクメール` / `PCMAX` / `イククル`

### 6. ビジネス・創作・趣味 (12種)
`LinkedIn` / `Wantedly` / `YOUTRUST` / `Eight` / `pixiv` / `Ameba (アメブロ)` / `Behance` / `Dribbble` / `DeviantArt` / `Tandem` / `Nextdoor` / `Meetup`

> ※ `LINE`・`BeReal.`・`Signal`・`Hinge` などのネイティブアプリ専用サービス、および `YouTube` などのDM非対応サービスは、本アプリのコンセプト（統合ブラウザ × DM送信可能）に基づきプリセット対象外としています。

---

## キーボードショートカット（Windows版）

| ショートカット | 動作 |
| :--- | :--- |
| `Ctrl + K` | SNS・マッチングアプリ カタログを開く |
| `Ctrl + 1` 〜 `Ctrl + 9` | 登録済みサービスを番号順に切り替え |
| `Ctrl + Shift + L` | プライバシーロック（全画面即時隠蔽） |
| `Esc` | 開いているモーダルを閉じる |

---

## ビルド・開発方法

### Windows 版（Electron）
- 必要環境: Windows 10 / 11 (x64), Node.js 20 以上

```bash
npm install
npm start          # 開発起動
npm run typecheck  # TypeScript型チェック
npm test           # ユニットテスト
npm run dist:win   # NSISインストーラー & ポータブル .exe を release/ へ出力
```

### Android 版（Flutter）
- 必要環境: Flutter 3.x / Android SDK

```bash
npm run export:catalog          # 共通カタログを mobile/assets/catalog.json へ同期
cd mobile
flutter pub get
flutter analyze                 # 静的解析
flutter test                    # テスト
flutter build apk --release     # APKビルド (build/app/outputs/flutter-apk/app-release.apk)
```

---

## プロジェクト構成

```text
omni-sns/
├── assets/                  # Windows/共通アプリアイコン (SVG / 512x512 PNG)
├── scripts/
│   ├── build.mjs            # Electron esbuild ビルドスクリプト
│   └── export-catalog.mjs   # 共通61種カタログJSON書き出しスクリプト
├── src/                     # Windows版 (Electron + TypeScript)
│   ├── shared/              # 型定義・全61種カタログ・URL/UA/未読解析
│   ├── main/                # メインプロセス・WebContentsView管理・設定永続化
│   ├── preload/             # 安全なIPCブリッジ
│   └── renderer/            # シェルUI (HTML / CSS / TS)
├── tests/                   # Windows版ユニットテスト
└── mobile/                  # Android版 (Flutter + WebView)
    ├── assets/catalog.json  # 共通61種カタログマスタ
    ├── lib/                 # Flutter UI・WebViewタブ管理・設定永続化
    └── test/                # Flutterテスト
```

---

## ライセンス

[MIT License](./LICENSE)
