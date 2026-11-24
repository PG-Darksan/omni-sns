import { invoke } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';
import {
  AddInstancePayload,
  AppConfig,
  AppSettings,
  BrowserTabInfo,
  CatalogService,
  CategoryMeta,
  FollowSyncSettings,
  GestureSettings,
  ServiceInstance,
  TabRuntimeState,
  UpdateFollowSyncPatch
} from '../shared/types';

export interface BootstrapPayload {
  config: AppConfig;
  catalog: CatalogService[];
  categories: CategoryMeta[];
  runtimeStates: TabRuntimeState[];
  appVersion: string;
  closedTabsCount: number;
  gmailOpen: boolean;
  gmailRuntime?: BrowserTabInfo | null;
}

export interface StateUpdatedPayload {
  config: AppConfig;
  runtimeStates: TabRuntimeState[];
  closedTabsCount: number;
  gmailOpen: boolean;
  gmailRuntime?: BrowserTabInfo | null;
}

export interface ShortcutEventPayload {
  action: string;
  payload?: number;
}

export interface OmniApi {
  getBootstrap: () => Promise<BootstrapPayload>;
  activateTab: (instanceId: string | null) => Promise<AppConfig>;
  addTab: (payload: AddInstancePayload) => Promise<{ created: ServiceInstance; config: AppConfig }>;
  removeTab: (instanceId: string) => Promise<AppConfig>;
  removeTabs: (instanceIds: string[]) => Promise<AppConfig>;
  restoreArchivedTab: (instanceId: string) => Promise<ServiceInstance>;
  purgeArchivedTab: (instanceId: string) => Promise<boolean>;
  purgeAllArchivedTabs: () => Promise<number>;
  updateTab: (
    instanceId: string,
    patch: Partial<
      Pick<ServiceInstance, 'name' | 'accountLabel' | 'url' | 'notificationsEnabled' | 'color' | 'badge'>
    >
  ) => Promise<ServiceInstance | null>;
  reorderTabs: (orderedIds: string[]) => Promise<AppConfig>;
  tabAction: (instanceId: string, action: string) => Promise<void>;
  createSubTab: (instanceId: string, url?: string) => Promise<string>;
  activateSubTab: (instanceId: string, tabId: string) => Promise<void>;
  closeSubTab: (instanceId: string, tabId: string) => Promise<string | null>;
  closeOtherSubTabs: (instanceId: string, tabId: string) => Promise<number>;
  duplicateSubTab: (instanceId: string, tabId: string) => Promise<string>;
  restoreClosedTab: () => Promise<string>;
  navigateSubTab: (instanceId: string, url: string) => Promise<string>;
  updateGestureSettings: (gesture: GestureSettings) => Promise<GestureSettings>;
  adjustFollowCount: (instanceId: string, delta: number) => Promise<ServiceInstance | null>;
  resetFollowCount: (instanceId: string, resetTotal: boolean) => Promise<ServiceInstance | null>;
  adjustUnfollowCount: (instanceId: string, delta: number) => Promise<ServiceInstance | null>;
  resetUnfollowCount: (instanceId: string, resetTotal: boolean) => Promise<ServiceInstance | null>;
  setFollowHandle: (instanceId: string, handle: string) => Promise<ServiceInstance>;
  updateFollowSyncSettings: (patch: UpdateFollowSyncPatch) => Promise<FollowSyncSettings>;
  syncFollowNow: () => Promise<FollowSyncSettings>;
  updateSettings: (patch: Partial<AppSettings>) => Promise<AppSettings>;
  setOverlayVisible: (visible: boolean) => Promise<void>;
  copyText: (text: string) => Promise<void>;
  openExternalUrl: (url: string) => Promise<void>;
  toggleGmail: (open?: boolean) => Promise<boolean>;
  gmailAction: (action: string) => Promise<void>;
  navigateGmail: (url: string) => Promise<string>;
  onStateUpdated: (listener: (payload: StateUpdatedPayload) => void) => () => void;
  onRuntimeUpdated: (listener: (state: TabRuntimeState) => void) => () => void;
  onShortcut: (listener: (payload: ShortcutEventPayload) => void) => () => void;
}

function subscribe<T>(eventName: string, listener: (payload: T) => void): () => void {
  let active = true;
  let unlistenFn: (() => void) | null = null;

  void listen<T>(eventName, (event) => {
    if (active) {
      listener(event.payload);
    }
  }).then((fn) => {
    if (!active) {
      fn();
    } else {
      unlistenFn = fn;
    }
  });

  return () => {
    active = false;
    unlistenFn?.();
  };
}

export const omniApi: OmniApi = {
  getBootstrap: () => invoke<BootstrapPayload>('app_get_bootstrap'),
  activateTab: (instanceId) => invoke<AppConfig>('tab_activate', { instanceId }),
  addTab: (payload) =>
    invoke<{ created: ServiceInstance; config: AppConfig }>('tab_add', { payload }),
  removeTab: (instanceId) => invoke<AppConfig>('tab_remove', { instanceId }),
  removeTabs: (instanceIds) => invoke<AppConfig>('tab_remove_many', { instanceIds }),
  restoreArchivedTab: (instanceId) => invoke<ServiceInstance>('archived_restore', { instanceId }),
  purgeArchivedTab: (instanceId) => invoke<boolean>('archived_purge', { instanceId }),
  purgeAllArchivedTabs: () => invoke<number>('archived_purge_all'),
  updateTab: (instanceId, patch) =>
    invoke<ServiceInstance | null>('tab_update', { instanceId, patch }),
  reorderTabs: (orderedIds) => invoke<AppConfig>('tab_reorder', { orderedIds }),
  tabAction: (instanceId, action) => invoke<void>('tab_action', { instanceId, action }),
  createSubTab: (instanceId, url) =>
    invoke<string>('subtab_create', { instanceId, url: url ?? null }),
  activateSubTab: (instanceId, tabId) =>
    invoke<void>('subtab_activate', { instanceId, tabId }),
  closeSubTab: (instanceId, tabId) =>
    invoke<string | null>('subtab_close', { instanceId, tabId }),
  closeOtherSubTabs: (instanceId, tabId) =>
    invoke<number>('subtab_close_others', { instanceId, tabId }),
  duplicateSubTab: (instanceId, tabId) =>
    invoke<string>('subtab_duplicate', { instanceId, tabId }),
  restoreClosedTab: () => invoke<string>('subtab_restore_closed'),
  navigateSubTab: (instanceId, url) =>
    invoke<string>('subtab_navigate', { instanceId, url }),
  updateGestureSettings: (gesture) =>
    invoke<GestureSettings>('gesture_update_settings', { gesture }),
  adjustFollowCount: (instanceId, delta) =>
    invoke<ServiceInstance | null>('follow_adjust', { instanceId, delta }),
  resetFollowCount: (instanceId, resetTotal) =>
    invoke<ServiceInstance | null>('follow_reset', { instanceId, resetTotal }),
  adjustUnfollowCount: (instanceId, delta) =>
    invoke<ServiceInstance | null>('unfollow_adjust', { instanceId, delta }),
  resetUnfollowCount: (instanceId, resetTotal) =>
    invoke<ServiceInstance | null>('unfollow_reset', { instanceId, resetTotal }),
  setFollowHandle: (instanceId, handle) =>
    invoke<ServiceInstance>('follow_set_handle', { instanceId, handle }),
  updateFollowSyncSettings: (patch) =>
    invoke<FollowSyncSettings>('follow_sync_update_settings', { patch }),
  syncFollowNow: () => invoke<FollowSyncSettings>('follow_sync_now'),
  updateSettings: (patch) => invoke<AppSettings>('settings_update', { patch }),
  setOverlayVisible: (visible) => invoke<void>('ui_set_overlay', { visible }),
  copyText: (text) => invoke<void>('ui_copy_text', { text }),
  openExternalUrl: (url) => invoke<void>('app_open_external_url', { url }),
  toggleGmail: (open) => invoke<boolean>('gmail_toggle', { open: open ?? null }),
  gmailAction: (action) => invoke<void>('gmail_action', { action }),
  navigateGmail: (url) => invoke<string>('gmail_navigate', { url }),
  onStateUpdated: (listener) => subscribe<StateUpdatedPayload>('app:state-updated', listener),
  onRuntimeUpdated: (listener) => subscribe<TabRuntimeState>('tab:runtime-updated', listener),
  onShortcut: (listener) => subscribe<ShortcutEventPayload>('app:shortcut', listener)
};
