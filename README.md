# OmniSNS — Windows向け 全SNS・マッチングアプリ統合ブラウザ

**OmniSNS** は、Webブラウザから **DM / メッセージ送信に対応した主要SNS・メッセンジャー・マッチングアプリ（全61種＋カスタムURL）** を、1つのWindowsデスクトップアプリ内で切り替えて使える統合ブラウザアプリ（Electron製）です。

---

## 主な特徴

- **全61種のDM送信対応SNS・マッチングアプリをプリセット収録**
  - メジャーSNS、チャット/メッセンジャー、国内・海外マッチングアプリ、出会い系、ビジネス/創作系まで網羅
  - Mastodon / Misskey の独自インスタンスや社内チャットも「カスタム追加」から自由に登録可能
- **サービスごとの完全セッション分離 & マルチアカウント対応**
  - Electron の `WebContentsView` + 独立パーティション（`persist:omnisns-<instanceId>`）を採用
  - Cookie・ログイン状態がサービスごとに分離＆永続化され、同じSNSを複数アカウントで同時利用可能
- **PC版 / モバイル版 User-Agent をタブごとにワンクリック切替**
  - 標準でクリーンな最新 Chrome User-Agent を設定し、Googleログイン・WhatsApp Web・Snapchat Web・mixi2・東カレデート等に対応
  - OAuth / SSO ポップアップ（Google / Apple / LINE / Facebookログイン等）も同一パーティションの子ウィンドウでシームレスに完了
- **プライバシー保護機能**
  - **クイックロック（`Ctrl + Shift + L`）**: 人前で即座に全画面を隠蔽（任意PINコード対応）
  - **マッチング・出会い系の一括表示/非表示切替**: サイドバーとカタログからワンクリックで隠蔽
- **メモリ節約 & デスクトップ統合**
  - 遅延ロード + ワンクリック **タブ休止（スリープ）** で多数のSNSを登録しても軽量動作
  - 未読バッジ監視（タイトル変化から自動集計）、ドラッグ＆ドロップ並び替え、ズーム、ミュート、ダーク/ライトテーマ、Windowsタスクトレイ常駐対応

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

## キーボードショートカット

| ショートカット | 動作 |
| :--- | :--- |
| `Ctrl + K` | SNS・マッチングアプリ カタログを開く |
| `Ctrl + 1` 〜 `Ctrl + 9` | 登録済みサービスを番号順に切り替え |
| `Ctrl + Shift + L` | プライバシーロック（全画面即時隠蔽） |
| `Esc` | 開いているモーダルを閉じる |

---

## セットアップ & 起動方法（Windows）

### 必要環境
- Windows 10 / 11 (x64)
- Node.js 20 以上

### 開発・起動
```bash
git clone https://github.com/PG-Darksan/omni-sns.git
cd omni-sns
npm install
npm start
```

### 型チェック & テスト
```bash
npm run typecheck
npm test
```

### Windows インストーラー / ポータブル版のビルド
```bash
npm run dist:win
```
ビルド成果物は `release/` フォルダに出力されます（NSISインストーラー `.exe` およびポータブル `.exe`）。

---

## プロジェクト構成

```text
omni-sns/
├── assets/
│   ├── icon.svg             # アプリアイコン (SVG)
│   └── icon.png             # アプリアイコン (512x512 PNG)
├── scripts/
│   └── build.mjs            # esbuild ビルドスクリプト
├── src/
│   ├── shared/
│   │   ├── types.ts         # 共有型定義
│   │   ├── catalog.ts       # 全61種プリセットカタログマスタ
│   │   └── url-utils.ts     # UA生成・URL正規化・未読数解析・OAuth判定
│   ├── main/
│   │   ├── main.ts          # Electronメインプロセス・ウィンドウ・トレイ・IPC
│   │   ├── view-manager.ts  # WebContentsView制御・パーティション・UA・コンテキストメニュー
│   │   └── store.ts         # 原子的ファイル書き込みによる設定・インスタンス永続化
│   ├── preload/
│   │   └── preload.ts       # contextIsolation対応の安全なIPCブリッジ
│   └── renderer/
│       ├── index.html       # シェルUI HTML
│       ├── styles.css       # ダーク/ライトテーマ対応スタイル
│       └── renderer.ts      # サイドバー・カタログ・設定・ロック画面ロジック
└── tests/
    └── core.test.ts         # ユニットテスト
```

---

## ライセンス

[MIT License](./LICENSE)
