import { contextBridge, ipcRenderer } from 'electron';
import {
  AddInstancePayload,
  AppConfig,
  AppSettings,
  CatalogService,
  CategoryMeta,
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
}

export interface StateUpdatedPayload {
  config: AppConfig;
  runtimeStates: TabRuntimeState[];
  isLocked: boolean;
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
  ) => Promise<ServiceInstance | undefined>;
  reorderTabs: (orderedIds: string[]) => Promise<AppConfig>;
  tabAction: (instanceId: string, action: string) => Promise<void>;
  updateSettings: (patch: Partial<AppSettings>) => Promise<AppSettings>;
  setOverlayVisible: (visible: boolean) => Promise<void>;
  setLocked: (locked: boolean, pinAttempt?: string) => Promise<{ ok: boolean; error?: string }>;
  copyText: (text: string) => Promise<void>;
  openExternalUrl: (url: string) => Promise<void>;
  onStateUpdated: (listener: (payload: StateUpdatedPayload) => void) => () => void;
  onRuntimeUpdated: (listener: (state: TabRuntimeState) => void) => () => void;
  onShortcut: (listener: (payload: ShortcutEventPayload) => void) => () => void;
}

const api: OmniApi = {
  getBootstrap: () => ipcRenderer.invoke('app:get-bootstrap'),
  activateTab: (instanceId) => ipcRenderer.invoke('tab:activate', instanceId),
  addTab: (payload) => ipcRenderer.invoke('tab:add', payload),
  removeTab: (instanceId) => ipcRenderer.invoke('tab:remove', instanceId),
  updateTab: (instanceId, patch) => ipcRenderer.invoke('tab:update', instanceId, patch),
  reorderTabs: (orderedIds) => ipcRenderer.invoke('tab:reorder', orderedIds),
  tabAction: (instanceId, action) => ipcRenderer.invoke('tab:action', instanceId, action),
  updateSettings: (patch) => ipcRenderer.invoke('settings:update', patch),
  setOverlayVisible: (visible) => ipcRenderer.invoke('ui:set-overlay', visible),
  setLocked: (locked, pinAttempt) => ipcRenderer.invoke('ui:set-locked', locked, pinAttempt),
  copyText: (text) => ipcRenderer.invoke('ui:copy-text', text),
  openExternalUrl: (url) => ipcRenderer.invoke('app:open-external-url', url),
  onStateUpdated: (listener) => {
    const wrapped = (_event: Electron.IpcRendererEvent, payload: StateUpdatedPayload) => listener(payload);
    ipcRenderer.on('app:state-updated', wrapped);
    return () => ipcRenderer.removeListener('app:state-updated', wrapped);
  },
  onRuntimeUpdated: (listener) => {
    const wrapped = (_event: Electron.IpcRendererEvent, state: TabRuntimeState) => listener(state);
    ipcRenderer.on('tab:runtime-updated', wrapped);
    return () => ipcRenderer.removeListener('tab:runtime-updated', wrapped);
  },
  onShortcut: (listener) => {
    const wrapped = (_event: Electron.IpcRendererEvent, payload: ShortcutEventPayload) => listener(payload);
    ipcRenderer.on('app:shortcut', wrapped);
    return () => ipcRenderer.removeListener('app:shortcut', wrapped);
  }
};

contextBridge.exposeInMainWorld('omniApi', api);
