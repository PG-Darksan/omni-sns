export type ServiceCategory =
  | 'major-sns'
  | 'messaging'
  | 'matching-global'
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
  /** 初期起動時に標準でサイドバーに並べるおすすめサービスか */
  defaultPinned?: boolean;
}

export interface ServiceInstance {
  /** タブ（インスタンス）固有ID（セッション分離キーに使用） */
  instanceId: string;
  /** カタログID（カスタムサービスの場合は 'custom'） */
  serviceId: string;
  /** ユーザー表示名（サービス名） */
  name: string;
  /** 同一SNS内のアカウント表示名（ヘッダー切替タブに表示。例: メイン, サブ, 仕事用） */
  accountLabel?: string;
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
  /** 未読数監視を有効にするか */
  notificationsEnabled: boolean;
  /** 並び順 */
  order: number;
  /** 本日のフォロー回数 */
  followCountToday?: number;
  /** 累計フォロー回数 */
  followCountTotal?: number;
  /** 本日のアンフォロー回数 */
  unfollowCountToday?: number;
  /** 累計アンフォロー回数 */
  unfollowCountTotal?: number;
  /** 本日カウントの日付 (YYYY-MM-DD) */
  followCountDate?: string;
  /** 次の1件のフォローカウントが期限切れで減少する予定時刻（UNIX秒） */
  followNextResetAt?: number;
  /** フォローカウントがすべて期限切れになり 0 へリセットされる予定時刻（UNIX秒） */
  followFullResetAt?: number;
  /** 次の1件のアンフォローカウントが期限切れで減少する予定時刻（UNIX秒） */
  unfollowNextResetAt?: number;
  /** アンフォローカウントがすべて期限切れになり 0 へリセットされる予定時刻（UNIX秒） */
  unfollowFullResetAt?: number;
  /** 自動検出または手動設定されたログイン中アカウントID (@username) */
  detectedHandle?: string;
  /** SNS サーバー上の実フォロー中数（取得済みの場合） */
  snsFollowingCount?: number;
  /** SNS サーバー上の実フォロワー数（取得済みの場合） */
  snsFollowersCount?: number;
  /** 同一アカウントで開いている複数タブの保存状態 */
  savedTabs?: { url: string; title: string }[];
  /** 保存時のアクティブタブ位置 */
  savedActiveTabIndex?: number;
}

export interface BrowserTabInfo {
  tabId: string;
  instanceId: string;
  currentUrl: string;
  title: string;
  faviconUrl: string | null;
  unreadCount: number;
  isLoading: boolean;
  isSleeping: boolean;
  canGoBack: boolean;
  canGoForward: boolean;
  loadError: string | null;
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
  activeTabId: string;
  tabs: BrowserTabInfo[];
  crossSiteService?: string | null;
  crossSiteHandle?: string | null;
}

export type GestureShape =
  | 'L'
  | 'R'
  | 'U'
  | 'D'
  | 'NW'
  | 'NE'
  | 'SW'
  | 'SE'
  | 'LU'
  | 'LD'
  | 'RU'
  | 'RD'
  | 'UL'
  | 'UR'
  | 'DL'
  | 'DR';

export interface GestureSettings {
  enabled: boolean;
  wrapTabs: boolean;
  showTrail: boolean;
  showFeedback: boolean;
  allowDup: boolean;
  tremor: number;
  gestures: Record<string, string>;
}

export type ThemeMode = 'dark' | 'light';

export interface FollowSyncSettings {
  deviceId: string;
  githubToken: string;
  gistId: string;
  lastSyncAt?: number;
  lastSyncStatus?: string;
}

export interface UpdateFollowSyncPatch {
  githubToken?: string;
  gistId?: string;
}

export interface AccountFilterSettings {
  enabled: boolean;
  minFollowing?: number | null;
  maxFollowing?: number | null;
  minFollowers?: number | null;
  maxFollowers?: number | null;
  followingGreaterThanFollowers: boolean;
}

export interface AccountFilterLiveState {
  active: boolean;
  matched: number;
  hidden: number;
  pending: number;
  autoFetching: boolean;
}

export type HeaderAccountScope = 'all' | 'service';

export interface AppSettings {
  theme: ThemeMode;
  /** ウィンドウを閉じる際にトレイへ最小化するか */
  minimizeToTray: boolean;
  /** サイドバー幅（px） */
  sidebarWidth: number;
  /** 最後に開いていたサービスインスタンスID */
  activeInstanceId: string | null;
  /** ツールバー・タブバー（ヘッダー下部）を折り畳んでいるか */
  headerCollapsed?: boolean;
  /** ヘッダーのアカウント切替バーの表示範囲（'all': 全SNS横断 / 'service': 現在SNSのみ） */
  headerAccountScope?: HeaderAccountScope;
  /** PC版表示領域の下余白（px。画面下端の入力欄を上に持ち上げる） */
  viewportBottomInset?: number;
  /** フォロー・アンフォロー集計時間（時間単位、1〜168、既定24） */
  followWindowHours?: number;
  /** サービスカタログのカスタム並び順（serviceId の配列） */
  catalogOrder?: string[];
  /** マウスジェスチャー設定 */
  gesture: GestureSettings;
  /** フォロー数クロスデバイス同期設定 */
  followSync?: FollowSyncSettings;
  /** アカウント条件フィルタ設定（フォロー数・フォロワー数・フォロー多め） */
  accountFilter?: AccountFilterSettings;
}

export interface ArchivedInstance {
  /** 削除時にログイン記憶（プロファイル）を保持したまま退避されたサービスインスタンス */
  instance: ServiceInstance;
  /** アーカイブ日時（UNIX秒） */
  archivedAt: number;
}

export interface JevStateSnapshot {
  hasApiKey: boolean;
  apiKey: string;
  enabled: boolean;
  isActive: boolean;
  category: string;
  recentCategories: string[];
  threshold: number;
  totalInputTokens: number;
  totalApiCalls: number;
  totalJudgedAccounts: number;
  totalCostUsd: number;
  sessionInputTokens: number;
  sessionApiCalls: number;
  sessionCostUsd: number;
  cacheEntries: number;
  checkingRequests: number;
  lastError?: string | null;
  liveInList: boolean;
  liveMatched: number;
  liveHidden: number;
  liveAutoFetching: boolean;
}

export interface UpdateJevSettingsPatch {
  apiKey?: string;
  enabled?: boolean;
  category?: string;
  threshold?: number;
}

export interface JevTestResult {
  ok: boolean;
  message: string;
}

export interface AppConfig {
  version: number;
  settings: AppSettings;
  instances: ServiceInstance[];
  /** タブ削除後もログイン記憶を残している保存済みアカウント一覧 */
  archivedInstances?: ArchivedInstance[];
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
  accountLabel?: string;
  category: ServiceCategory;
  url: string;
  color: string;
  badge: string;
  uaMode: UserAgentMode;
}

export interface CategoryMeta {
  id: ServiceCategory;
  label: string;
  description: string;
}
