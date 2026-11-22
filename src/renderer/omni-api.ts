import { invoke } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';
import {
  AddInstancePayload,
  AppConfig,
  AppSettings,
  CatalogService,
  CategoryMeta,
  GestureSettings,
  ServiceInstance,
  TabRuntimeState
} from '../shared/types';

export interface BootstrapPayload {
  config: AppConfig;
  catalog: CatalogService[];
  categories: CategoryMeta[];
  runtimeStates: TabRuntimeState[];
  appVersion: string;
  isLocked: boolean;
  closedTabsCount: number;
}

export interface StateUpdatedPayload {
  config: AppConfig;
  runtimeStates: TabRuntimeState[];
  isLocked: boolean;
  closedTabsCount: number;
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
  updateTab: (
    instanceId: string,
    patch: Partial<Pick<ServiceInstance, 'name' | 'url' | 'notificationsEnabled' | 'color' | 'badge'>>
  ) => Promise<ServiceInstance | null>;
  reorderTabs: (orderedIds: string[]) => Promise<AppConfig>;
  tabAction: (instanceId: string, action: string) => Promise<void>;
  createSubTab: (instanceId: string, url?: string) => Promise<string>;
  activateSubTab: (instanceId: string, tabId: string) => Promise<void>;
  closeSubTab: (instanceId: string, tabId: string) => Promise<string | null>;
  closeOtherSubTabs: (instanceId: string, tabId: string) => Promise<number>;
  duplicateSubTab: (instanceId: string, tabId: string) => Promise<string>;
  restoreClosedTab: () => Promise<string>;
  updateGestureSettings: (gesture: GestureSettings) => Promise<GestureSettings>;
  updateSettings: (patch: Partial<AppSettings>) => Promise<AppSettings>;
  setOverlayVisible: (visible: boolean) => Promise<void>;
  setLocked: (locked: boolean, pinAttempt?: string) => Promise<{ ok: boolean; error?: string }>;
  copyText: (text: string) => Promise<void>;
  openExternalUrl: (url: string) => Promise<void>;
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
  updateGestureSettings: (gesture) =>
    invoke<GestureSettings>('gesture_update_settings', { gesture }),
  updateSettings: (patch) => invoke<AppSettings>('settings_update', { patch }),
  setOverlayVisible: (visible) => invoke<void>('ui_set_overlay', { visible }),
  setLocked: (locked, pinAttempt) =>
    invoke<{ ok: boolean; error?: string }>('ui_set_locked', {
      locked,
      pinAttempt: pinAttempt ?? null
    }),
  copyText: (text) => invoke<void>('ui_copy_text', { text }),
  openExternalUrl: (url) => invoke<void>('app_open_external_url', { url }),
  onStateUpdated: (listener) => subscribe<StateUpdatedPayload>('app:state-updated', listener),
  onRuntimeUpdated: (listener) => subscribe<TabRuntimeState>('tab:runtime-updated', listener),
  onShortcut: (listener) => subscribe<ShortcutEventPayload>('app:shortcut', listener)
};
