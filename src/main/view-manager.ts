import {
  BaseWindow,
  clipboard,
  Menu,
  MenuItemConstructorOptions,
  session,
  shell,
  WebContentsView
} from 'electron';
import { ServiceInstance, TabRuntimeState, UserAgentMode } from '../shared/types';
import {
  buildUserAgent,
  parseUnreadCountFromTitle,
  shouldOpenInAppPopup
} from '../shared/url-utils';

export interface ContentBounds {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface ViewManagerCallbacks {
  onRuntimeStateChanged: (state: TabRuntimeState) => void;
  onShortcutTriggered: (action: string, payload?: number) => void;
}

const ALLOWED_PERMISSIONS = new Set([
  'notifications',
  'media',
  'mediaKeySystem',
  'clipboard-read',
  'clipboard-sanitized-write',
  'fullscreen',
  'geolocation',
  'pointerLock',
  'window-management',
  'display-capture'
]);

export class ServiceViewManager {
  private readonly hostWindow: BaseWindow;
  private readonly callbacks: ViewManagerCallbacks;
  private readonly views = new Map<string, WebContentsView>();
  private readonly states = new Map<string, TabRuntimeState>();
  private readonly instances = new Map<string, ServiceInstance>();

  private activeInstanceId: string | null = null;
  private attachedViewId: string | null = null;
  private overlayVisible = false;
  private locked = false;
  private bounds: ContentBounds = { x: 248, y: 48, width: 1000, height: 760 };

  constructor(hostWindow: BaseWindow, callbacks: ViewManagerCallbacks) {
    this.hostWindow = hostWindow;
    this.callbacks = callbacks;
  }

  public syncInstances(instances: ServiceInstance[]): void {
    const validIds = new Set(instances.map((i) => i.instanceId));

    // 削除されたインスタンスのViewを破棄
    for (const existingId of Array.from(this.views.keys())) {
      if (!validIds.has(existingId)) {
        this.destroyView(existingId);
      }
    }
    for (const existingId of Array.from(this.states.keys())) {
      if (!validIds.has(existingId)) {
        this.states.delete(existingId);
      }
    }

    this.instances.clear();
    for (const instance of instances) {
      this.instances.set(instance.instanceId, instance);
      if (!this.states.has(instance.instanceId)) {
        this.states.set(instance.instanceId, {
          instanceId: instance.instanceId,
          currentUrl: instance.url,
          title: instance.name,
          faviconUrl: null,
          unreadCount: 0,
          isLoading: false,
          isSleeping: true,
          canGoBack: false,
          canGoForward: false,
          muted: instance.muted,
          zoomFactor: instance.zoomFactor,
          uaMode: instance.uaMode,
          loadError: null
        });
      }
    }
  }

  public getAllRuntimeStates(): TabRuntimeState[] {
    return Array.from(this.states.values()).map((s) => ({ ...s }));
  }

  public getTotalUnreadCount(excludeMatching: boolean): number {
    let total = 0;
    for (const [id, state] of this.states.entries()) {
      const inst = this.instances.get(id);
      if (!inst || !inst.notificationsEnabled) continue;
      if (excludeMatching && inst.isAdultOrMatching) continue;
      total += state.unreadCount;
    }
    return total;
  }

  public setBounds(nextBounds: ContentBounds): void {
    this.bounds = {
      x: Math.max(0, Math.round(nextBounds.x)),
      y: Math.max(0, Math.round(nextBounds.y)),
      width: Math.max(0, Math.round(nextBounds.width)),
      height: Math.max(0, Math.round(nextBounds.height))
    };
    this.refreshAttachedView();
  }

  public setOverlayVisible(visible: boolean): void {
    if (this.overlayVisible === visible) return;
    this.overlayVisible = visible;
    this.refreshAttachedView();
  }

  public setLocked(locked: boolean): void {
    if (this.locked === locked) return;
    this.locked = locked;
    this.refreshAttachedView();
  }

  public activate(instanceId: string | null): void {
    this.activeInstanceId = instanceId;
    if (!instanceId) {
      this.refreshAttachedView();
      return;
    }

    const instance = this.instances.get(instanceId);
    if (!instance) {
      this.activeInstanceId = null;
      this.refreshAttachedView();
      return;
    }

    if (!this.views.has(instanceId)) {
      this.createView(instance);
    }

    this.refreshAttachedView();
  }

  private refreshAttachedView(): void {
    const shouldHide = this.overlayVisible || this.locked || !this.activeInstanceId;

    if (shouldHide) {
      if (this.attachedViewId) {
        const currentView = this.views.get(this.attachedViewId);
        if (currentView) {
          try {
            this.hostWindow.contentView.removeChildView(currentView);
          } catch {
            // 既に切り離されている場合は無視
          }
        }
        this.attachedViewId = null;
      }
      return;
    }

    const targetId = this.activeInstanceId!;
    const targetView = this.views.get(targetId);
    if (!targetView) return;

    if (this.attachedViewId && this.attachedViewId !== targetId) {
      const prevView = this.views.get(this.attachedViewId);
      if (prevView) {
        try {
          this.hostWindow.contentView.removeChildView(prevView);
        } catch {
          // ignore
        }
      }
      this.attachedViewId = null;
    }

    if (this.attachedViewId !== targetId) {
      this.hostWindow.contentView.addChildView(targetView);
      this.attachedViewId = targetId;
    }

    targetView.setBounds(this.bounds);
  }

  private getPartitionName(instanceId: string): string {
    return `persist:omnisns-${instanceId}`;
  }

  private getChromeVersion(): string {
    return process.versions.chrome || '136.0.0.0';
  }

  private createView(instance: ServiceInstance): WebContentsView {
    const partition = this.getPartitionName(instance.instanceId);
    const ses = session.fromPartition(partition);
    const userAgent = buildUserAgent(instance.uaMode, this.getChromeVersion());

    ses.setUserAgent(userAgent);
    ses.setPermissionRequestHandler((_wc, permission, callback) => {
      callback(ALLOWED_PERMISSIONS.has(permission));
    });
    ses.setPermissionCheckHandler((_wc, permission) => {
      return ALLOWED_PERMISSIONS.has(permission);
    });

    const view = new WebContentsView({
      webPreferences: {
        partition,
        contextIsolation: true,
        nodeIntegration: false,
        sandbox: true,
        spellcheck: true,
        autoplayPolicy: 'user-gesture-required'
      }
    });

    const wc = view.webContents;
    wc.setUserAgent(userAgent);
    wc.setAudioMuted(instance.muted);
    wc.setZoomFactor(instance.zoomFactor);

    const updateState = (partial: Partial<TabRuntimeState>) => {
      const current = this.states.get(instance.instanceId);
      if (!current) return;
      const next: TabRuntimeState = { ...current, ...partial };
      this.states.set(instance.instanceId, next);
      this.callbacks.onRuntimeStateChanged({ ...next });
    };

    const syncNavigationFlags = () => {
      if (wc.isDestroyed()) return;
      updateState({
        currentUrl: wc.getURL() || instance.url,
        canGoBack: wc.navigationHistory.canGoBack(),
        canGoForward: wc.navigationHistory.canGoForward()
      });
    };

    wc.on('did-start-loading', () => {
      updateState({ isLoading: true, isSleeping: false, loadError: null });
    });

    wc.on('did-stop-loading', () => {
      updateState({ isLoading: false, isSleeping: false });
      syncNavigationFlags();
    });

    wc.on('did-navigate', () => syncNavigationFlags());
    wc.on('did-navigate-in-page', () => syncNavigationFlags());

    wc.on('did-fail-load', (_event, errorCode, errorDescription, validatedURL, isMainFrame) => {
      // ERR_ABORTED (-3) はリダイレクトやSPA遷移時に頻発するためエラー表示しない
      if (!isMainFrame || errorCode === -3) return;
      updateState({
        isLoading: false,
        loadError: `${errorDescription} (${errorCode}) — ${validatedURL}`
      });
    });

    wc.on('page-title-updated', (_event, title) => {
      const unreadCount = parseUnreadCountFromTitle(title);
      updateState({ title: title || instance.name, unreadCount });
    });

    wc.on('page-favicon-updated', (_event, favicons) => {
      if (favicons && favicons.length > 0) {
        updateState({ faviconUrl: favicons[0] });
      }
    });

    // WebContentsViewフォーカス中でもアプリ全体の主要ショートカットを効かせる
    wc.on('before-input-event', (event, input) => {
      if (input.type !== 'keyDown') return;
      const ctrl = input.control || input.meta;
      if (!ctrl) return;

      const key = input.key.toLowerCase();
      if (input.shift && key === 'l') {
        event.preventDefault();
        this.callbacks.onShortcutTriggered('toggle-lock');
        return;
      }
      if (!input.shift && !input.alt && key === 'k') {
        event.preventDefault();
        this.callbacks.onShortcutTriggered('open-catalog');
        return;
      }
      if (!input.shift && !input.alt && /^[1-9]$/.test(key)) {
        event.preventDefault();
        this.callbacks.onShortcutTriggered('switch-tab', Number(key) - 1);
      }
    });

    // OAuth / SSO ポップアップは同一パーティションの子ウィンドウで許可、その他外部リンクは既定ブラウザへ
    wc.setWindowOpenHandler((details) => {
      const currentUrl = wc.getURL() || instance.url;
      if (shouldOpenInAppPopup(details.url, currentUrl)) {
        return {
          action: 'allow',
          overrideBrowserWindowOptions: {
            width: 560,
            height: 760,
            autoHideMenuBar: true,
            title: `${instance.name} - 認証 / ウィンドウ`,
            webPreferences: {
              partition,
              contextIsolation: true,
              nodeIntegration: false,
              sandbox: true
            }
          }
        };
      }

      if (/^https?:\/\//i.test(details.url)) {
        void shell.openExternal(details.url);
      }
      return { action: 'deny' };
    });

    // 認証ポップアップ側にもクリーンなChrome UAを適用（Googleログイン等対策）
    wc.on('did-create-window', (childWindow) => {
      const latestInst = this.instances.get(instance.instanceId);
      const latestUa = buildUserAgent(latestInst?.uaMode ?? instance.uaMode, this.getChromeVersion());
      childWindow.webContents.setUserAgent(latestUa);
    });

    // ネイティブ右クリックコンテキストメニュー
    wc.on('context-menu', (_event, params) => {
      const template: MenuItemConstructorOptions[] = [];

      if (params.isEditable) {
        template.push(
          { label: '元に戻す', role: 'undo' },
          { label: 'やり直し', role: 'redo' },
          { type: 'separator' },
          { label: '切り取り', role: 'cut' },
          { label: 'コピー', role: 'copy' },
          { label: '貼り付け', role: 'paste' },
          { label: 'すべて選択', role: 'selectAll' }
        );
      } else if (params.selectionText) {
        template.push({ label: 'コピー', role: 'copy' });
      }

      if (params.linkURL && /^https?:\/\//i.test(params.linkURL)) {
        if (template.length > 0) template.push({ type: 'separator' });
        template.push(
          {
            label: 'リンクを既定のブラウザで開く',
            click: () => void shell.openExternal(params.linkURL)
          },
          {
            label: 'リンクのアドレスをコピー',
            click: () => clipboard.writeText(params.linkURL)
          }
        );
      }

      if (params.mediaType === 'image' && params.srcURL) {
        if (template.length > 0) template.push({ type: 'separator' });
        template.push(
          {
            label: '画像をコピー',
            click: () => wc.copyImageAt(params.x, params.y)
          },
          {
            label: '画像のURLをコピー',
            click: () => clipboard.writeText(params.srcURL)
          }
        );
      }

      if (template.length > 0) template.push({ type: 'separator' });
      template.push(
        {
          label: '戻る',
          enabled: wc.navigationHistory.canGoBack(),
          click: () => wc.navigationHistory.goBack()
        },
        {
          label: '進む',
          enabled: wc.navigationHistory.canGoForward(),
          click: () => wc.navigationHistory.goForward()
        },
        {
          label: '再読み込み',
          click: () => wc.reload()
        }
      );

      const menu = Menu.buildFromTemplate(template);
      menu.popup();
    });

    this.views.set(instance.instanceId, view);
    updateState({ isSleeping: false, isLoading: true, loadError: null });
    void wc.loadURL(instance.url);
    return view;
  }

  public sleepTab(instanceId: string): void {
    const view = this.views.get(instanceId);
    if (!view) return;

    if (this.attachedViewId === instanceId) {
      try {
        this.hostWindow.contentView.removeChildView(view);
      } catch {
        // ignore
      }
      this.attachedViewId = null;
    }

    if (!view.webContents.isDestroyed()) {
      view.webContents.close({ waitForBeforeUnload: false });
    }
    this.views.delete(instanceId);

    const state = this.states.get(instanceId);
    if (state) {
      const next: TabRuntimeState = {
        ...state,
        isSleeping: true,
        isLoading: false,
        unreadCount: 0,
        loadError: null
      };
      this.states.set(instanceId, next);
      this.callbacks.onRuntimeStateChanged({ ...next });
    }
  }

  public destroyView(instanceId: string): void {
    this.sleepTab(instanceId);
    if (this.activeInstanceId === instanceId) {
      this.activeInstanceId = null;
    }
  }

  public destroyAll(): void {
    for (const id of Array.from(this.views.keys())) {
      this.sleepTab(id);
    }
    this.activeInstanceId = null;
    this.attachedViewId = null;
  }

  public goBack(instanceId: string): void {
    const wc = this.views.get(instanceId)?.webContents;
    if (wc && !wc.isDestroyed() && wc.navigationHistory.canGoBack()) {
      wc.navigationHistory.goBack();
    }
  }

  public goForward(instanceId: string): void {
    const wc = this.views.get(instanceId)?.webContents;
    if (wc && !wc.isDestroyed() && wc.navigationHistory.canGoForward()) {
      wc.navigationHistory.goForward();
    }
  }

  public reload(instanceId: string, hard = false): void {
    const view = this.views.get(instanceId);
    if (!view) {
      const instance = this.instances.get(instanceId);
      if (instance) {
        this.createView(instance);
        this.refreshAttachedView();
      }
      return;
    }
    const wc = view.webContents;
    if (wc.isDestroyed()) return;
    if (hard) {
      wc.reloadIgnoringCache();
    } else {
      wc.reload();
    }
  }

  public goHome(instanceId: string): void {
    const instance = this.instances.get(instanceId);
    if (!instance) return;
    const view = this.views.get(instanceId) ?? this.createView(instance);
    if (!view.webContents.isDestroyed()) {
      void view.webContents.loadURL(instance.url);
    }
    this.refreshAttachedView();
  }

  public setMuted(instanceId: string, muted: boolean): void {
    const instance = this.instances.get(instanceId);
    if (instance) instance.muted = muted;

    const wc = this.views.get(instanceId)?.webContents;
    if (wc && !wc.isDestroyed()) {
      wc.setAudioMuted(muted);
    }
    const state = this.states.get(instanceId);
    if (state) {
      state.muted = muted;
      this.callbacks.onRuntimeStateChanged({ ...state });
    }
  }

  public setZoom(instanceId: string, zoomFactor: number): void {
    const clamped = Math.max(0.5, Math.min(2.0, Math.round(zoomFactor * 100) / 100));
    const instance = this.instances.get(instanceId);
    if (instance) instance.zoomFactor = clamped;

    const wc = this.views.get(instanceId)?.webContents;
    if (wc && !wc.isDestroyed()) {
      wc.setZoomFactor(clamped);
    }
    const state = this.states.get(instanceId);
    if (state) {
      state.zoomFactor = clamped;
      this.callbacks.onRuntimeStateChanged({ ...state });
    }
  }

  public setUaMode(instanceId: string, uaMode: UserAgentMode): void {
    const instance = this.instances.get(instanceId);
    if (instance) instance.uaMode = uaMode;

    const ua = buildUserAgent(uaMode, this.getChromeVersion());
    const ses = session.fromPartition(this.getPartitionName(instanceId));
    ses.setUserAgent(ua);

    const wc = this.views.get(instanceId)?.webContents;
    if (wc && !wc.isDestroyed()) {
      wc.setUserAgent(ua);
      wc.reloadIgnoringCache();
    }
    const state = this.states.get(instanceId);
    if (state) {
      state.uaMode = uaMode;
      this.callbacks.onRuntimeStateChanged({ ...state });
    }
  }

  public async clearSessionData(instanceId: string): Promise<void> {
    const ses = session.fromPartition(this.getPartitionName(instanceId));
    await ses.clearStorageData();
    await ses.clearCache();
    const instance = this.instances.get(instanceId);
    const wc = this.views.get(instanceId)?.webContents;
    if (instance && wc && !wc.isDestroyed()) {
      void wc.loadURL(instance.url);
    }
  }

  public toggleDevTools(instanceId: string): void {
    const wc = this.views.get(instanceId)?.webContents;
    if (!wc || wc.isDestroyed()) return;
    if (wc.isDevToolsOpened()) {
      wc.closeDevTools();
    } else {
      wc.openDevTools({ mode: 'detach' });
    }
  }

  public openCurrentUrlExternally(instanceId: string): void {
    const state = this.states.get(instanceId);
    const targetUrl = state?.currentUrl || this.instances.get(instanceId)?.url;
    if (targetUrl && /^https?:\/\//i.test(targetUrl)) {
      void shell.openExternal(targetUrl);
    }
  }
}
