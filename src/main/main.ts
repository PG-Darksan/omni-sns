import {
  app,
  BrowserWindow,
  clipboard,
  ipcMain,
  Menu,
  nativeImage,
  shell,
  Tray
} from 'electron';
import fs from 'node:fs';
import path from 'node:path';
import { CATEGORIES, SERVICE_CATALOG } from '../shared/catalog';
import {
  AddInstancePayload,
  AppSettings,
  ServiceInstance,
  TabRuntimeState
} from '../shared/types';
import { ConfigStore } from './store';
import { ServiceViewManager } from './view-manager';

const TOOLBAR_HEIGHT = 50;

let mainWindow: BrowserWindow | null = null;
let tray: Tray | null = null;
let store: ConfigStore;
let viewManager: ServiceViewManager | null = null;
let isQuitting = false;
let isLocked = false;
let currentOverlayVisible = false;

function resolveAssetPath(filename: string): string {
  const candidates = [
    path.join(app.getAppPath(), 'assets', filename),
    path.join(__dirname, '..', '..', 'assets', filename)
  ];
  for (const candidate of candidates) {
    if (fs.existsSync(candidate)) {
      return candidate;
    }
  }
  return candidates[0];
}

function getVisibleInstances(): ServiceInstance[] {
  const settings = store.getSettings();
  return store
    .getInstances()
    .filter((inst) => settings.showMatchingServices || !inst.isAdultOrMatching);
}

function updateWindowTitle(): void {
  if (!mainWindow || mainWindow.isDestroyed()) return;
  if (isLocked) {
    mainWindow.setTitle('OmniSNS');
    return;
  }
  const settings = store.getSettings();
  const unread = viewManager?.getTotalUnreadCount(!settings.showMatchingServices) ?? 0;
  mainWindow.setTitle(unread > 0 ? `(${unread}) OmniSNS` : 'OmniSNS');
}

function updateViewBounds(): void {
  if (!mainWindow || mainWindow.isDestroyed() || !viewManager) return;
  const [contentWidth, contentHeight] = mainWindow.getContentSize();
  const sidebarWidth = store.getSettings().sidebarWidth;
  viewManager.setBounds({
    x: sidebarWidth,
    y: TOOLBAR_HEIGHT,
    width: Math.max(0, contentWidth - sidebarWidth),
    height: Math.max(0, contentHeight - TOOLBAR_HEIGHT)
  });
}

function broadcastState(): void {
  if (!mainWindow || mainWindow.isDestroyed()) return;
  mainWindow.webContents.send('app:state-updated', {
    config: store.getConfig(),
    runtimeStates: viewManager?.getAllRuntimeStates() ?? [],
    isLocked
  });
  updateWindowTitle();
}

function ensureSafeActiveInstance(): string | null {
  const visible = getVisibleInstances();
  const currentActive = store.getSettings().activeInstanceId;
  if (currentActive && visible.some((inst) => inst.instanceId === currentActive)) {
    return currentActive;
  }
  const fallback = visible[0]?.instanceId ?? null;
  store.updateSettings({ activeInstanceId: fallback });
  return fallback;
}

function setLockedState(nextLocked: boolean): void {
  isLocked = nextLocked;
  viewManager?.setLocked(nextLocked);
  broadcastState();
}

function createTray(): void {
  if (tray) return;
  try {
    const iconPath = resolveAssetPath('icon.png');
    const icon = fs.existsSync(iconPath)
      ? nativeImage.createFromPath(iconPath).resize({ width: 16, height: 16 })
      : nativeImage.createEmpty();

    tray = new Tray(icon);
    tray.setToolTip('OmniSNS - All-in-One SNS & Matching Desk');

    const rebuildTrayMenu = () => {
      const contextMenu = Menu.buildFromTemplate([
        {
          label: 'OmniSNS を表示',
          click: () => {
            if (mainWindow && !mainWindow.isDestroyed()) {
              mainWindow.show();
              mainWindow.focus();
            }
          }
        },
        {
          label: isLocked ? 'ロック解除画面を表示' : 'プライバシーロック (Ctrl+Shift+L)',
          click: () => {
            if (mainWindow && !mainWindow.isDestroyed()) {
              mainWindow.show();
              mainWindow.focus();
            }
            setLockedState(true);
          }
        },
        { type: 'separator' },
        {
          label: '終了',
          click: () => {
            isQuitting = true;
            app.quit();
          }
        }
      ]);
      tray?.setContextMenu(contextMenu);
    };

    rebuildTrayMenu();
    tray.on('click', () => {
      if (!mainWindow || mainWindow.isDestroyed()) return;
      if (mainWindow.isVisible()) {
        mainWindow.focus();
      } else {
        mainWindow.show();
      }
    });
  } catch {
    tray = null;
  }
}

function createMainWindow(): void {
  const config = store.getConfig();
  const bounds = config.windowBounds ?? { width: 1380, height: 880 };
  const iconPath = resolveAssetPath('icon.png');

  mainWindow = new BrowserWindow({
    width: Math.max(960, bounds.width || 1380),
    height: Math.max(640, bounds.height || 880),
    x: bounds.x,
    y: bounds.y,
    minWidth: 960,
    minHeight: 620,
    title: 'OmniSNS',
    backgroundColor: config.settings.theme === 'light' ? '#f3f5f8' : '#0f1219',
    autoHideMenuBar: true,
    icon: fs.existsSync(iconPath) ? iconPath : undefined,
    webPreferences: {
      preload: path.join(__dirname, '..', 'preload', 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true
    }
  });

  if (bounds.isMaximized) {
    mainWindow.maximize();
  }

  // シェルUI自体の予期しないナビゲーションを防止
  mainWindow.webContents.on('will-navigate', (event, targetUrl) => {
    if (!targetUrl.startsWith('file://')) {
      event.preventDefault();
      if (/^https?:\/\//i.test(targetUrl)) {
        void shell.openExternal(targetUrl);
      }
    }
  });

  viewManager = new ServiceViewManager(mainWindow, {
    onRuntimeStateChanged: (state: TabRuntimeState) => {
      if (mainWindow && !mainWindow.isDestroyed()) {
        mainWindow.webContents.send('tab:runtime-updated', state);
      }
      updateWindowTitle();
    },
    onShortcutTriggered: (action: string, payload?: number) => {
      if (!mainWindow || mainWindow.isDestroyed()) return;
      if (action === 'toggle-lock') {
        if (!isLocked) {
          setLockedState(true);
        } else if (!store.getSettings().lockPin) {
          setLockedState(false);
        } else {
          mainWindow.webContents.send('app:shortcut', { action: 'focus-pin' });
        }
        return;
      }
      mainWindow.webContents.send('app:shortcut', { action, payload });
    }
  });

  viewManager.syncInstances(store.getInstances());

  const saveBounds = () => {
    if (!mainWindow || mainWindow.isDestroyed()) return;
    const maximized = mainWindow.isMaximized();
    const normal = mainWindow.getNormalBounds();
    store.updateWindowBounds({
      x: normal.x,
      y: normal.y,
      width: normal.width,
      height: normal.height,
      isMaximized: maximized
    });
  };

  mainWindow.on('resize', () => {
    updateViewBounds();
  });
  mainWindow.on('maximize', () => {
    updateViewBounds();
    saveBounds();
  });
  mainWindow.on('unmaximize', () => {
    updateViewBounds();
    saveBounds();
  });
  mainWindow.on('moved', saveBounds);
  mainWindow.on('resized', saveBounds);

  mainWindow.on('close', (event) => {
    saveBounds();
    if (!isQuitting && store.getSettings().minimizeToTray) {
      event.preventDefault();
      mainWindow?.hide();
    }
  });

  mainWindow.on('closed', () => {
    viewManager?.destroyAll();
    viewManager = null;
    mainWindow = null;
  });

  const rendererHtml = path.join(__dirname, '..', 'renderer', 'index.html');
  void mainWindow.loadFile(rendererHtml);

  mainWindow.webContents.once('did-finish-load', () => {
    updateViewBounds();
    const initialActive = ensureSafeActiveInstance();
    if (initialActive && !currentOverlayVisible && !isLocked) {
      viewManager?.activate(initialActive);
    }
    broadcastState();

    if (process.argv.includes('--smoke-test')) {
      const screenshotArg = process.argv.find((arg) => arg.startsWith('--screenshot='));
      const screenshotPath = screenshotArg ? screenshotArg.slice('--screenshot='.length) : null;
      setTimeout(async () => {
        try {
          if (screenshotPath && mainWindow && !mainWindow.isDestroyed()) {
            const image = await mainWindow.webContents.capturePage();
            fs.mkdirSync(path.dirname(screenshotPath), { recursive: true });
            fs.writeFileSync(screenshotPath, image.toPNG());
          }
          console.log('[smoke-test] OmniSNS main window and shell UI loaded successfully.');
          isQuitting = true;
          app.exit(0);
        } catch (err) {
          console.error('[smoke-test] Failed:', err);
          isQuitting = true;
          app.exit(1);
        }
      }, 2200);
    }
  });

  createTray();
}

function registerIpcHandlers(): void {
  ipcMain.handle('app:get-bootstrap', () => {
    updateViewBounds();
    const activeId = ensureSafeActiveInstance();
    if (activeId && !currentOverlayVisible && !isLocked) {
      viewManager?.activate(activeId);
    }
    return {
      config: store.getConfig(),
      catalog: SERVICE_CATALOG,
      categories: CATEGORIES,
      runtimeStates: viewManager?.getAllRuntimeStates() ?? [],
      appVersion: app.getVersion(),
      isLocked
    };
  });

  ipcMain.handle('tab:activate', (_event, instanceId: string | null) => {
    const target = instanceId ? store.getInstance(instanceId) : undefined;
    const settings = store.getSettings();
    if (target && !settings.showMatchingServices && target.isAdultOrMatching) {
      return store.getConfig();
    }
    const nextId = target ? target.instanceId : null;
    store.updateSettings({ activeInstanceId: nextId });
    viewManager?.activate(nextId);
    broadcastState();
    return store.getConfig();
  });

  ipcMain.handle('tab:add', (_event, payload: AddInstancePayload) => {
    const created = store.addInstance(payload);
    // マッチング系を追加した場合、表示設定がOFFなら自動でONにする
    if (created.isAdultOrMatching && !store.getSettings().showMatchingServices) {
      store.updateSettings({ showMatchingServices: true });
    }
    viewManager?.syncInstances(store.getInstances());
    viewManager?.activate(created.instanceId);
    broadcastState();
    return { created, config: store.getConfig() };
  });

  ipcMain.handle('tab:remove', (_event, instanceId: string) => {
    store.removeInstance(instanceId);
    viewManager?.syncInstances(store.getInstances());
    const nextActive = ensureSafeActiveInstance();
    viewManager?.activate(nextActive);
    broadcastState();
    return store.getConfig();
  });

  ipcMain.handle(
    'tab:update',
    (
      _event,
      instanceId: string,
      patch: Partial<Pick<ServiceInstance, 'name' | 'url' | 'notificationsEnabled' | 'color' | 'badge'>>
    ) => {
      const updated = store.updateInstance(instanceId, patch);
      viewManager?.syncInstances(store.getInstances());
      broadcastState();
      return updated;
    }
  );

  ipcMain.handle('tab:reorder', (_event, orderedIds: string[]) => {
    store.reorderInstances(orderedIds);
    viewManager?.syncInstances(store.getInstances());
    broadcastState();
    return store.getConfig();
  });

  ipcMain.handle('tab:action', async (_event, instanceId: string, action: string) => {
    const instance = store.getInstance(instanceId);
    if (!instance || !viewManager) return;

    switch (action) {
      case 'back':
        viewManager.goBack(instanceId);
        break;
      case 'forward':
        viewManager.goForward(instanceId);
        break;
      case 'reload':
        viewManager.reload(instanceId, false);
        break;
      case 'hard-reload':
        viewManager.reload(instanceId, true);
        break;
      case 'home':
        viewManager.goHome(instanceId);
        break;
      case 'sleep':
        viewManager.sleepTab(instanceId);
        break;
      case 'wake':
        viewManager.activate(instanceId);
        break;
      case 'toggle-mute': {
        const nextMuted = !instance.muted;
        store.updateInstance(instanceId, { muted: nextMuted });
        viewManager.setMuted(instanceId, nextMuted);
        broadcastState();
        break;
      }
      case 'zoom-in': {
        const nextZoom = Math.min(2.0, Math.round((instance.zoomFactor + 0.1) * 100) / 100);
        store.updateInstance(instanceId, { zoomFactor: nextZoom });
        viewManager.setZoom(instanceId, nextZoom);
        broadcastState();
        break;
      }
      case 'zoom-out': {
        const nextZoom = Math.max(0.5, Math.round((instance.zoomFactor - 0.1) * 100) / 100);
        store.updateInstance(instanceId, { zoomFactor: nextZoom });
        viewManager.setZoom(instanceId, nextZoom);
        broadcastState();
        break;
      }
      case 'zoom-reset': {
        store.updateInstance(instanceId, { zoomFactor: 1.0 });
        viewManager.setZoom(instanceId, 1.0);
        broadcastState();
        break;
      }
      case 'toggle-ua': {
        const nextUa = instance.uaMode === 'desktop' ? 'mobile' : 'desktop';
        store.updateInstance(instanceId, { uaMode: nextUa });
        viewManager.setUaMode(instanceId, nextUa);
        broadcastState();
        break;
      }
      case 'clear-session':
        await viewManager.clearSessionData(instanceId);
        break;
      case 'devtools':
        viewManager.toggleDevTools(instanceId);
        break;
      case 'open-external':
        viewManager.openCurrentUrlExternally(instanceId);
        break;
      default:
        break;
    }
  });

  ipcMain.handle('settings:update', (_event, patch: Partial<AppSettings>) => {
    const updated = store.updateSettings(patch);
    updateViewBounds();
    const safeActive = ensureSafeActiveInstance();
    viewManager?.activate(safeActive);
    broadcastState();
    return updated;
  });

  ipcMain.handle('ui:set-overlay', (_event, visible: boolean) => {
    currentOverlayVisible = Boolean(visible);
    viewManager?.setOverlayVisible(currentOverlayVisible);
  });

  ipcMain.handle('ui:set-locked', (_event, locked: boolean, pinAttempt?: string) => {
    if (!locked) {
      const expectedPin = store.getSettings().lockPin;
      if (expectedPin && pinAttempt !== expectedPin) {
        return { ok: false, error: 'PINコードが一致しません。' };
      }
    }
    setLockedState(Boolean(locked));
    return { ok: true };
  });

  ipcMain.handle('ui:copy-text', (_event, text: string) => {
    if (typeof text === 'string') {
      clipboard.writeText(text);
    }
  });

  ipcMain.handle('app:open-external-url', (_event, url: string) => {
    if (typeof url === 'string' && /^https?:\/\//i.test(url)) {
      void shell.openExternal(url);
    }
  });
}

// シングルインスタンス制御
const gotSingleInstanceLock = app.requestSingleInstanceLock();
if (!gotSingleInstanceLock) {
  app.quit();
} else {
  app.on('second-instance', () => {
    if (mainWindow && !mainWindow.isDestroyed()) {
      if (mainWindow.isMinimized()) mainWindow.restore();
      mainWindow.show();
      mainWindow.focus();
    }
  });

  app.on('before-quit', () => {
    isQuitting = true;
  });

  app.whenReady().then(() => {
    const configPath = path.join(app.getPath('userData'), 'omni-sns-config.json');
    store = new ConfigStore(configPath);
    registerIpcHandlers();
    createMainWindow();
  });

  app.on('window-all-closed', () => {
    if (process.platform !== 'darwin') {
      app.quit();
    }
  });
}
