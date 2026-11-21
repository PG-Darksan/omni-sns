export type ServiceCategory =
  | 'major-sns'
  | 'messaging'
  | 'matching-jp'
  | 'matching-global'
  | 'matching-dating'
  | 'business-creative'
  | 'custom';

export type UserAgentMode = 'desktop' | 'mobile';

export interface CatalogService {
  /** 一意なサービスID */
  id: string;
  /** 表示名 */
  name: string;
  /** 検索用別名・キーワード */
  aliases: string[];
  /** カテゴリ */
  category: ServiceCategory;
  /** メッセージ/DM画面の初期URL */
  url: string;
  /** サービス公式サイトURL */
  homeUrl: string;
  /** ブランドアクセントカラー (HEX) */
  color: string;
  /** アイコン用短縮ラベル（ファビコン取得前のフォールバック） */
  badge: string;
  /** 推奨User-Agentモード */
  defaultUa: UserAgentMode;
  /** 短い説明 */
  description: string;
  /** 利用上の注意（PC UA必須、QR連携など） */
  note?: string;
  /** ユーザーがインスタンスURLを指定する必要があるか（Mastodon/Misskey等） */
  requiresCustomUrl?: boolean;
  /** 18+ / マッチング・出会い系フラグ（プライバシーフィルター対象） */
  isAdultOrMatching?: boolean;
  /** 初期起動時に標準でサイドバーに並べるおすすめサービスか */
  defaultPinned?: boolean;
}

export interface ServiceInstance {
  /** タブ（インスタンス）固有ID（セッション分離キーに使用） */
  instanceId: string;
  /** カタログID（カスタムサービスの場合は 'custom'） */
  serviceId: string;
  /** ユーザー表示名（マルチアカウント時に変更可能） */
  name: string;
  /** カテゴリ */
  category: ServiceCategory;
  /** 初期URL（ホーム復帰先） */
  url: string;
  /** アクセントカラー */
  color: string;
  /** 短縮バッジ文字 */
  badge: string;
  /** 現在のUAモード */
  uaMode: UserAgentMode;
  /** 音声ミュート状態 */
  muted: boolean;
  /** ズーム倍率（例: 1.0） */
  zoomFactor: number;
  /** 18+ / マッチング系フラグ */
  isAdultOrMatching: boolean;
  /** 未読数監視を有効にするか */
  notificationsEnabled: boolean;
  /** 並び順 */
  order: number;
}

export interface TabRuntimeState {
  instanceId: string;
  currentUrl: string;
  title: string;
  faviconUrl: string | null;
  unreadCount: number;
  isLoading: boolean;
  isSleeping: boolean;
  canGoBack: boolean;
  canGoForward: boolean;
  muted: boolean;
  zoomFactor: number;
  uaMode: UserAgentMode;
  loadError: string | null;
}

export type ThemeMode = 'dark' | 'light';

export interface AppSettings {
  theme: ThemeMode;
  /** マッチング・出会い系サービスをUIに表示するか */
  showMatchingServices: boolean;
  /** ウィンドウを閉じる際にトレイへ最小化するか */
  minimizeToTray: boolean;
  /** プライバシーロック用の任意PIN（空文字ならワンクリック解除） */
  lockPin: string;
  /** サイドバー幅（px） */
  sidebarWidth: number;
  /** 最後に開いていたサービスインスタンスID */
  activeInstanceId: string | null;
}

export interface AppConfig {
  version: number;
  settings: AppSettings;
  instances: ServiceInstance[];
  windowBounds?: {
    x?: number;
    y?: number;
    width: number;
    height: number;
    isMaximized?: boolean;
  };
}

export interface AddInstancePayload {
  serviceId: string;
  name: string;
  category: ServiceCategory;
  url: string;
  color: string;
  badge: string;
  uaMode: UserAgentMode;
  isAdultOrMatching: boolean;
}

export interface CategoryMeta {
  id: ServiceCategory;
  label: string;
  description: string;
  isMatchingGroup?: boolean;
}
