# OmniSNS — Windows & Android 向け SNS統合ブラウザ

**OmniSNS** は、Webブラウザから **DM / メッセージ送信に対応した主要SNS・メッセンジャー・マッチングアプリ（全60種＋カスタムURL）** を、1つのアプリ内で切り替えて使える統合ブラウザアプリです。

- **Windows 版**: Tauri v2 + WebView2 マルチWebView（サービスごと独立プロファイルによる完全セッション分離 / 軽量インストーラー＆単体ポータブル `.exe`）
- **Android 版**: Flutter + Android WebView（下部クイックタブ切替 / ドロワー並び替え / リリース `.apk`）

> ビルド済みバイナリ（Windows `.exe` / Android `.apk`）は **[GitHub Releases](https://github.com/PG-Darksan/omni-sns/releases)** からダウンロードできます。

---

## 主な特徴

- **全60種のDM送信対応サービスをプリセット収録（Windows / Android 共通カタログ）**
  - メジャーSNS、チャット/メッセンジャー、国内・海外マッチングアプリ、出会い系、ビジネス/創作系までフラットに網羅
  - Mastodon / Misskey の独自インスタンスや社内チャットも「カスタム追加」から自由に登録可能
- **PC版 / モバイル版 User-Agent をタブごとにワンクリック切替**
  - 標準でクリーンな最新 Chrome User-Agent を設定し、WhatsApp Web・Snapchat Web・mixi2・東カレデート等に対応
  - Windows版ではサービスインスタンスごとの独立WebView2プロファイル（`profiles/omnisns-<instanceId>`）による完全セッション分離＆マルチアカウント・OAuthポップアップに対応
- **プライバシー保護機能**
  - **クイックロック**: ワンクリック（Windowsは `Ctrl + Shift + L`）で全画面を即座に隠蔽（任意PINコード対応）
- **マルチタブ & マウスジェスチャー（Windows版・HisatorNotebook 準拠）**
  - 各SNSサービス内で独立ログインセッションを共有したまま **複数タブ** の作成・複製・切替・削除・閉じたタブ復元に対応
  - 右クリック＋ドラッグによる **12方向マウスジェスチャー**（1方向 4種 ＋ 直角2方向 8種）＋ 透明オーバーレイ軌跡＆ガイド表示
  - **リアルタイム連続スクロール**: 上下左右スクロールを割り当てると、離した時ではなくドラッグ中に引っ張る長さに応じて滑らかに連続スクロール進行（引っ張るほど高速、別方向へ曲げると即停止）
  - 12方向ビジュアル割り当てボード、ドラッグ入替、手ぶれ補正（1〜30px）、続けて割り当てる、取り消し（`Ctrl+Z`）対応
- **メモリ節約 & 快適操作**
  - 遅延ロード + **タブ休止（スリープ）** で多数のSNSを登録しても軽量動作
  - 未読バッジ自動集計、ドラッグ＆ドロップ並び替え、ダーク/ライトテーマ対応

---

## プリセット収録サービス一覧（全60種）

### 1. メジャーSNS (16種)
`Instagram` / `Threads` / `Facebook Messenger` / `Facebook` / `Bluesky` / `mixi2` / `TikTok` / `Snapchat` / `Reddit` / `Pinterest` / `Tumblr` / `Mastodon` / `Misskey` / `Weibo (微博)` / `VK (VKontakte)` / `mixi (初代)`

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

> ※ `X (旧Twitter)` はアプリ内WebViewからのログイン制限のため対象外としています。また、`LINE`・`BeReal.`・`Signal`・`Hinge` などのネイティブアプリ専用サービス、および `YouTube` などのDM非対応サービスは、本アプリのコンセプト（統合ブラウザ × DM送信可能）に基づきプリセット対象外としています。

---

## キーボードショートカット（Windows版）

| ショートカット | 動作 |
| :--- | :--- |
| `右ドラッグ` | マウスジェスチャー（タブ切替・新規作成・削除・閉じたタブ復元・連続スクロール等） |
| `Ctrl + T` / `Ctrl + W` / `Ctrl + Shift + T` | 新しいタブを開く / タブを閉じる / 閉じたタブを復元 |
| `Ctrl + Tab` / `Ctrl + Shift + Tab` | 次 / 前のタブへ切り替え |
| `Ctrl + K` | サービス カタログを開く |
| `Ctrl + 1` 〜 `Ctrl + 9` | 登録済みサービスを番号順に切り替え |
| `Ctrl + Shift + L` | プライバシーロック（全画面即時隠蔽） |
| `Esc` | 開いているモーダルを閉じる / ドラッグ中のジェスチャーを中止 |

---

## ビルド・開発方法

### Windows 版（Tauri v2 + WebView2）
- 必要環境: Windows 10 / 11 (x64, WebView2 Runtime), Node.js 20 以上, Rust (stable / MSVC)

```bash
npm install
npm start          # 開発起動 (tauri dev)
npm run typecheck  # TypeScript型チェック
npm test           # TypeScript + Rust ユニットテスト
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
│   ├── build.mjs            # フロントエンド esbuild & カタログ書き出しスクリプト
│   ├── dist-win.mjs         # Tauri Windows リリースビルド & release/ 配置スクリプト
│   └── export-catalog.mjs   # 共通60種カタログJSON書き出しスクリプト (Tauri / Android 共通)
├── src/                     # 共通カタログ・シェルUIフロントエンド (TypeScript / HTML / CSS)
│   ├── shared/              # 型定義・全60種カタログ・URL/UA/未読解析
│   └── renderer/            # シェルUI (HTML / CSS / TS / Tauri IPCブリッジ)
├── src-tauri/               # Windows版ネイティブバックエンド (Rust / Tauri v2 / WebView2)
│   ├── assets/catalog.json  # 共通60種カタログマスタ（バイナリ埋め込み）
│   ├── capabilities/        # Tauri v2 権限設定（シェルUI専用）
│   └── src/                 # マルチWebView管理・WebView2制御・設定永続化・トレイ
├── tests/                   # TypeScript ユニットテスト
└── mobile/                  # Android版 (Flutter + WebView)
    ├── assets/catalog.json  # 共通60種カタログマスタ
    ├── lib/                 # Flutter UI・WebViewタブ管理・設定永続化
    └── test/                # Flutterテスト
```

---

## ライセンス

[MIT License](./LICENSE)
