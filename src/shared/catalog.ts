import { CatalogService, CategoryMeta } from './types';

export const CATEGORIES: CategoryMeta[] = [
  {
    id: 'major-sns',
    label: 'メジャーSNS',
    description: 'Webブラウザから無料でDM・メッセージ送信に対応した主要SNS'
  },
  {
    id: 'messaging',
    label: 'チャット・メッセージ',
    description: 'リアルタイムチャット・通話・SMS連携対応のメッセンジャー'
  },
  {
    id: 'matching-global',
    label: 'マッチング',
    description: '無料プランでWeb版からメッセージ送信に対応したマッチングサービス'
  },
  {
    id: 'business-creative',
    label: 'ビジネス・創作・趣味',
    description: 'キャリア・クリエイター・語学・コミュニティ向け無料DM対応サービス'
  },
  {
    id: 'custom',
    label: 'カスタム追加',
    description: '任意のWeb SNS・分散サーバー・社内チャットを自由に追加'
  }
];

export const SERVICE_CATALOG: CatalogService[] = [
  // ========================
  // 1. メジャーSNS
  // ========================
  {
    id: 'instagram',
    name: 'Instagram',
    aliases: ['insta', 'インスタ', 'インスタグラム', 'ig'],
    category: 'major-sns',
    url: 'https://www.instagram.com/direct/inbox/',
    homeUrl: 'https://www.instagram.com/',
    color: '#E1306C',
    badge: 'IG',
    defaultUa: 'desktop',
    description: '写真・リール・ストーリーズ閲覧とWeb版DMに対応。',
    defaultPinned: true
  },
  {
    id: 'threads',
    name: 'Threads',
    aliases: ['スレッズ', 'meta'],
    category: 'major-sns',
    url: 'https://www.threads.com/',
    homeUrl: 'https://www.threads.com/',
    color: '#18181B',
    badge: 'TH',
    defaultUa: 'desktop',
    description: 'MetaのテキストSNS。Web版ネイティブDM・グループチャットに対応。',
    defaultPinned: true
  },
  {
    id: 'messenger',
    name: 'Facebook Messenger',
    aliases: ['fb', 'メッセンジャー', 'facebook'],
    category: 'major-sns',
    url: 'https://www.messenger.com/',
    homeUrl: 'https://www.messenger.com/',
    color: '#0084FF',
    badge: 'FM',
    defaultUa: 'desktop',
    description: 'Facebook連携メッセンジャー専用Webクライアント。'
  },
  {
    id: 'facebook',
    name: 'Facebook',
    aliases: ['fb', 'フェイスブック'],
    category: 'major-sns',
    url: 'https://www.facebook.com/messages/',
    homeUrl: 'https://www.facebook.com/',
    color: '#1877F2',
    badge: 'FB',
    defaultUa: 'desktop',
    description: 'フィード閲覧とメッセージ送受信をまとめて利用可能。'
  },
  {
    id: 'bluesky',
    name: 'Bluesky',
    aliases: ['bsky', 'ブルースカイ', 'ブルスカ'],
    category: 'major-sns',
    url: 'https://bsky.app/messages',
    homeUrl: 'https://bsky.app/',
    color: '#0085FF',
    badge: 'BS',
    defaultUa: 'desktop',
    description: '分散型マイクロブログ。Web版チャット（DM）に対応。',
    defaultPinned: true
  },
  {
    id: 'mixi2',
    name: 'mixi2',
    aliases: ['ミクシィ2', 'ミクシィ'],
    category: 'major-sns',
    url: 'https://mixi.social/',
    homeUrl: 'https://mixi.social/',
    color: '#F59E0B',
    badge: 'm2',
    defaultUa: 'desktop',
    description: '日本発の短文・コミュニティSNS。PCブラウザ版でDM・グループDMに対応。',
    note: 'PCブラウザ向けUAでの利用を推奨します。',
    defaultPinned: true
  },
  {
    id: 'tiktok',
    name: 'TikTok',
    aliases: ['ティックトック'],
    category: 'major-sns',
    url: 'https://www.tiktok.com/messages',
    homeUrl: 'https://www.tiktok.com/',
    color: '#FE2C55',
    badge: 'TT',
    defaultUa: 'desktop',
    description: 'ショート動画閲覧とWeb版DMに対応（相互フォロー等の条件あり）。'
  },
  {
    id: 'snapchat',
    name: 'Snapchat',
    aliases: ['スナップチャット', 'スナチャ'],
    category: 'major-sns',
    url: 'https://web.snapchat.com/',
    homeUrl: 'https://www.snapchat.com/',
    color: '#EAB308',
    badge: 'SC',
    defaultUa: 'desktop',
    description: 'Snapchat for Webによるチャット・スナップ送受信。',
    note: 'PC用Chromium UAで動作します。'
  },
  {
    id: 'reddit',
    name: 'Reddit',
    aliases: ['レディット', '掲示板'],
    category: 'major-sns',
    url: 'https://chat.reddit.com/',
    homeUrl: 'https://www.reddit.com/',
    color: '#FF4500',
    badge: 'RD',
    defaultUa: 'desktop',
    description: '世界最大級のフォーラムSNS。Web版チャット/DMに対応。'
  },
  {
    id: 'pinterest',
    name: 'Pinterest',
    aliases: ['ピンタレスト'],
    category: 'major-sns',
    url: 'https://www.pinterest.com/',
    homeUrl: 'https://www.pinterest.com/',
    color: '#E60023',
    badge: 'PI',
    defaultUa: 'desktop',
    description: 'ピン共有とWeb版メッセージ送信に対応。'
  },
  {
    id: 'tumblr',
    name: 'Tumblr',
    aliases: ['タンブラー'],
    category: 'major-sns',
    url: 'https://www.tumblr.com/messaging',
    homeUrl: 'https://www.tumblr.com/',
    color: '#35465C',
    badge: 'TB',
    defaultUa: 'desktop',
    description: 'ミニブログとWeb版ダイレクトメッセージに対応。'
  },
  {
    id: 'mastodon',
    name: 'Mastodon',
    aliases: ['マストドン', 'fediverse', '分散sns'],
    category: 'major-sns',
    url: 'https://mastodon.social/',
    homeUrl: 'https://mastodon.social/',
    color: '#6364FF',
    badge: 'MD',
    defaultUa: 'desktop',
    description: '分散型SNS。利用中のインスタンスURLに変更して追加できます。',
    note: '追加時にご自身のサーバーURLへ変更してください。',
    requiresCustomUrl: true
  },
  {
    id: 'misskey',
    name: 'Misskey',
    aliases: ['ミスキー', 'fediverse', '分散sns'],
    category: 'major-sns',
    url: 'https://misskey.io/',
    homeUrl: 'https://misskey.io/',
    color: '#86B300',
    badge: 'MK',
    defaultUa: 'desktop',
    description: '日本発の分散型SNS。チャットやダイレクトノートに対応。',
    note: '追加時にご自身のサーバーURLへ変更してください。',
    requiresCustomUrl: true
  },
  {
    id: 'weibo',
    name: 'Weibo (微博)',
    aliases: ['ウェイボー', '中国'],
    category: 'major-sns',
    url: 'https://weibo.com/',
    homeUrl: 'https://weibo.com/',
    color: '#E6162D',
    badge: 'WB',
    defaultUa: 'desktop',
    description: '中国最大級のマイクロブログ。Web版私信（DM）に対応。'
  },
  {
    id: 'vk',
    name: 'VK (VKontakte)',
    aliases: ['ブイケー', 'ロシア'],
    category: 'major-sns',
    url: 'https://vk.com/im',
    homeUrl: 'https://vk.com/',
    color: '#0077FF',
    badge: 'VK',
    defaultUa: 'desktop',
    description: '総合SNSのWeb版メッセンジャー。'
  },
  {
    id: 'mixi-classic',
    name: 'mixi (初代)',
    aliases: ['ミクシィ', 'mixi'],
    category: 'major-sns',
    url: 'https://mixi.jp/',
    homeUrl: 'https://mixi.jp/',
    color: '#D97706',
    badge: 'm1',
    defaultUa: 'desktop',
    description: '初代mixiのコミュニティ・メッセージ機能。'
  },

  // ========================
  // 2. チャット・メッセンジャー
  // ========================
  {
    id: 'discord',
    name: 'Discord',
    aliases: ['ディスコード', 'ディスコ'],
    category: 'messaging',
    url: 'https://discord.com/app',
    homeUrl: 'https://discord.com/',
    color: '#5865F2',
    badge: 'DC',
    defaultUa: 'desktop',
    description: 'DM・サーバーチャット・通話に対応したフル機能Webクライアント。',
    defaultPinned: true
  },
  {
    id: 'telegram',
    name: 'Telegram',
    aliases: ['テレグラム'],
    category: 'messaging',
    url: 'https://web.telegram.org/',
    homeUrl: 'https://telegram.org/',
    color: '#229ED9',
    badge: 'TG',
    defaultUa: 'desktop',
    description: '高速メッセンジャーのWeb版。QRまたは電話番号でログイン。'
  },
  {
    id: 'whatsapp',
    name: 'WhatsApp Web',
    aliases: ['ワッツアップ'],
    category: 'messaging',
    url: 'https://web.whatsapp.com/',
    homeUrl: 'https://www.whatsapp.com/',
    color: '#25D366',
    badge: 'WA',
    defaultUa: 'desktop',
    description: 'スマホ版とQR連携して利用するWeb版WhatsApp。',
    note: 'PC用User-Agent必須（デフォルト設定済み）。'
  },
  {
    id: 'slack',
    name: 'Slack',
    aliases: ['スラック', 'ビジネス'],
    category: 'messaging',
    url: 'https://app.slack.com/',
    homeUrl: 'https://slack.com/',
    color: '#4A154B',
    badge: 'SL',
    defaultUa: 'desktop',
    description: 'ビジネス・コミュニティ向けチャットワークスペース。'
  },
  {
    id: 'teams',
    name: 'Microsoft Teams',
    aliases: ['チームズ', 'skype', 'マイクロソフト'],
    category: 'messaging',
    url: 'https://teams.microsoft.com/',
    homeUrl: 'https://www.microsoft.com/ja-jp/microsoft-teams/',
    color: '#6264A7',
    badge: 'MT',
    defaultUa: 'desktop',
    description: 'ビジネス・個人向けチャット＆通話（旧Skype統合先）。'
  },
  {
    id: 'chatwork',
    name: 'Chatwork',
    aliases: ['チャットワーク'],
    category: 'messaging',
    url: 'https://www.chatwork.com/',
    homeUrl: 'https://go.chatwork.com/',
    color: '#F03748',
    badge: 'CW',
    defaultUa: 'desktop',
    description: '日本のビジネスチャット定番。Web版フル機能。'
  },
  {
    id: 'google-chat',
    name: 'Google Chat',
    aliases: ['グーグルチャット', 'gchat'],
    category: 'messaging',
    url: 'https://chat.google.com/',
    homeUrl: 'https://chat.google.com/',
    color: '#00AC47',
    badge: 'GC',
    defaultUa: 'desktop',
    description: 'Googleアカウントで使えるチャット＆スペース。'
  },
  {
    id: 'band',
    name: 'BAND',
    aliases: ['バンド', 'グループ'],
    category: 'messaging',
    url: 'https://band.us/',
    homeUrl: 'https://band.us/',
    color: '#00C73C',
    badge: 'BD',
    defaultUa: 'desktop',
    description: 'サークル・部活・チーム向けグループSNS＆チャット。'
  },
  {
    id: 'element',
    name: 'Element (Matrix)',
    aliases: ['マトリックス', 'エレメント'],
    category: 'messaging',
    url: 'https://app.element.io/',
    homeUrl: 'https://element.io/',
    color: '#0DBD8B',
    badge: 'EL',
    defaultUa: 'desktop',
    description: 'エンドツーエンド暗号化対応の分散チャットクライアント。'
  },
  {
    id: 'twitch',
    name: 'Twitch',
    aliases: ['ツイッチ', '配信'],
    category: 'messaging',
    url: 'https://www.twitch.tv/',
    homeUrl: 'https://www.twitch.tv/',
    color: '#9146FF',
    badge: 'TW',
    defaultUa: 'desktop',
    description: 'ライブ配信チャットおよびささやき（Whisper）送信に対応。'
  },
  {
    id: 'steam-chat',
    name: 'Steam Chat',
    aliases: ['スチーム', 'ゲーム'],
    category: 'messaging',
    url: 'https://steamcommunity.com/chat/',
    homeUrl: 'https://store.steampowered.com/',
    color: '#1B2838',
    badge: 'ST',
    defaultUa: 'desktop',
    description: 'Steamフレンド・グループチャットWeb版。'
  },
  {
    id: 'google-messages',
    name: 'Googleメッセージ Web',
    aliases: ['sms', 'rcs', 'ショートメッセージ'],
    category: 'messaging',
    url: 'https://messages.google.com/web/',
    homeUrl: 'https://messages.google.com/',
    color: '#1A73E8',
    badge: 'SM',
    defaultUa: 'desktop',
    description: 'Android端末とQR連携してPCからSMS/RCSを送受信可能。'
  },

  // ========================
  // 3. マッチング（無料プランでメッセージ送信対応）
  // ========================
  {
    id: 'tinder',
    name: 'Tinder',
    aliases: ['ティンダー', 'マッチング'],
    category: 'matching-global',
    url: 'https://tinder.com/',
    homeUrl: 'https://tinder.com/',
    color: '#FE3C72',
    badge: 'TD',
    defaultUa: 'desktop',
    description: '世界最大級のスワイプ型マッチング。無料プランでTinder Webからメッセージ送信対応。'
  },
  {
    id: 'bumble',
    name: 'Bumble',
    aliases: ['バンブル', 'マッチング'],
    category: 'matching-global',
    url: 'https://bumble.com/app',
    homeUrl: 'https://bumble.com/',
    color: '#FBBF24',
    badge: 'BM',
    defaultUa: 'desktop',
    description: '恋活・友達作り（BFF）対応。無料プランでBumble Webからチャット可能。'
  },
  {
    id: 'okcupid',
    name: 'OkCupid',
    aliases: ['オーケーキューピッド', 'マッチング'],
    category: 'matching-global',
    url: 'https://www.okcupid.com/',
    homeUrl: 'https://www.okcupid.com/',
    color: '#2563EB',
    badge: 'OK',
    defaultUa: 'desktop',
    description: '価値観質問ベースのグローバルマッチング。無料プランでメッセージ送受信対応。'
  },
  {
    id: 'badoo',
    name: 'Badoo',
    aliases: ['バドゥー', 'マッチング'],
    category: 'matching-global',
    url: 'https://badoo.com/',
    homeUrl: 'https://badoo.com/',
    color: '#7C3AED',
    badge: 'BA',
    defaultUa: 'desktop',
    description: '欧州・南米を中心に人気のマッチングSNS。無料プランでWeb版チャット対応。'
  },
  {
    id: 'pof',
    name: 'Plenty of Fish (POF)',
    aliases: ['pof', 'マッチング'],
    category: 'matching-global',
    url: 'https://www.pof.com/',
    homeUrl: 'https://www.pof.com/',
    color: '#0284C7',
    badge: 'PF',
    defaultUa: 'desktop',
    description: '英語圏定番のマッチングサイト。無料プランでWebからメッセージ送信可能。'
  },

  // ========================
  // 4. ビジネス・創作・趣味
  // ========================
  {
    id: 'linkedin',
    name: 'LinkedIn',
    aliases: ['リンクトイン', 'ビジネス', '転職'],
    category: 'business-creative',
    url: 'https://www.linkedin.com/messaging/',
    homeUrl: 'https://www.linkedin.com/',
    color: '#0A66C2',
    badge: 'LI',
    defaultUa: 'desktop',
    description: '世界最大級のビジネスSNS。Web版メッセージング対応。'
  },
  {
    id: 'wantedly',
    name: 'Wantedly',
    aliases: ['ウォンテッドリー', '採用', 'ビジネス'],
    category: 'business-creative',
    url: 'https://www.wantedly.com/messages',
    homeUrl: 'https://www.wantedly.com/',
    color: '#21BDDB',
    badge: 'WT',
    defaultUa: 'desktop',
    description: '日本のビジネスSNS。採用・カジュアル面談メッセージに対応。'
  },
  {
    id: 'youtrust',
    name: 'YOUTRUST',
    aliases: ['ユートラスト', 'キャリア'],
    category: 'business-creative',
    url: 'https://youtrust.jp/',
    homeUrl: 'https://youtrust.jp/',
    color: '#00C4B4',
    badge: 'YT',
    defaultUa: 'desktop',
    description: '日本のキャリアSNS。スカウト・メッセージ送受信に対応。'
  },
  {
    id: 'eight',
    name: 'Eight',
    aliases: ['エイト', '名刺'],
    category: 'business-creative',
    url: 'https://8card.net/',
    homeUrl: 'https://8card.net/',
    color: '#00A0E9',
    badge: '8',
    defaultUa: 'desktop',
    description: '名刺管理SNS。つながった相手とWeb版メッセージ可能。'
  },
  {
    id: 'pixiv',
    name: 'pixiv',
    aliases: ['ピクシブ', 'イラスト', '創作'],
    category: 'business-creative',
    url: 'https://www.pixiv.net/messages.php',
    homeUrl: 'https://www.pixiv.net/',
    color: '#0096FA',
    badge: 'PX',
    defaultUa: 'desktop',
    description: '国内最大級の創作SNS。Web版ダイレクトメッセージに対応。'
  },
  {
    id: 'ameba',
    name: 'Ameba (アメブロ)',
    aliases: ['アメーバ', 'ブログ'],
    category: 'business-creative',
    url: 'https://msg.ameba.jp/',
    homeUrl: 'https://ameblo.jp/',
    color: '#2D8C3C',
    badge: 'AM',
    defaultUa: 'desktop',
    description: 'アメーバのWeb版メッセージボックス。'
  },
  {
    id: 'behance',
    name: 'Behance',
    aliases: ['ビハンス', 'adobe', 'デザイン'],
    category: 'business-creative',
    url: 'https://www.behance.net/inbox',
    homeUrl: 'https://www.behance.net/',
    color: '#1769FF',
    badge: 'BE',
    defaultUa: 'desktop',
    description: 'Adobe系クリエイターSNSの受信トレイ・メッセージ機能。'
  },
  {
    id: 'dribbble',
    name: 'Dribbble',
    aliases: ['ドリブル', 'デザイン'],
    category: 'business-creative',
    url: 'https://dribbble.com/messages',
    homeUrl: 'https://dribbble.com/',
    color: '#EA4C89',
    badge: 'DR',
    defaultUa: 'desktop',
    description: 'デザイナー向けSNSのメッセージ機能。'
  },
  {
    id: 'deviantart',
    name: 'DeviantArt',
    aliases: ['デヴィアントアート', 'イラスト'],
    category: 'business-creative',
    url: 'https://www.deviantart.com/chat',
    homeUrl: 'https://www.deviantart.com/',
    color: '#05CC47',
    badge: 'DA',
    defaultUa: 'desktop',
    description: '海外アートコミュニティのチャット・ノート機能。'
  },
  {
    id: 'tandem',
    name: 'Tandem',
    aliases: ['タンデム', '語学', '英会話'],
    category: 'business-creative',
    url: 'https://app.tandem.net/',
    homeUrl: 'https://tandem.net/',
    color: '#F43F5E',
    badge: 'TN',
    defaultUa: 'desktop',
    description: '語学交換SNSのWeb版チャットクライアント。'
  },
  {
    id: 'nextdoor',
    name: 'Nextdoor',
    aliases: ['ネクストドア', '地域'],
    category: 'business-creative',
    url: 'https://nextdoor.com/',
    homeUrl: 'https://nextdoor.com/',
    color: '#8ED500',
    badge: 'ND',
    defaultUa: 'desktop',
    description: '地域コミュニティSNS。近隣ユーザー間のDMに対応。'
  }
];

export function findCatalogService(serviceId: string): CatalogService | undefined {
  return SERVICE_CATALOG.find((item) => item.id === serviceId);
}
