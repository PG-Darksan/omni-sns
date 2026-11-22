import { GestureBoardModal } from './gesture-ui';
import { omniApi } from './omni-api';
import {
  AddInstancePayload,
  AppConfig,
  CatalogService,
  CategoryMeta,
  ServiceCategory,
  ServiceInstance,
  TabRuntimeState,
  UserAgentMode
} from '../shared/types';
import { makeBadgeText, normalizeServiceUrl } from '../shared/url-utils';

interface UiState {
  config: AppConfig | null;
  catalog: CatalogService[];
  categories: CategoryMeta[];
  runtimeMap: Map<string, TabRuntimeState>;
  isLocked: boolean;
  closedTabsCount: number;
  selectedCatalogCategory: ServiceCategory | 'all';
  catalogSearchQuery: string;
  sidebarFilterQuery: string;
  editingMode: 'create' | 'edit' | null;
  editingInstanceId: string | null;
  editingTemplate: CatalogService | null;
}

const state: UiState = {
  config: null,
  catalog: [],
  categories: [],
  runtimeMap: new Map(),
  isLocked: false,
  closedTabsCount: 0,
  selectedCatalogCategory: 'all',
  catalogSearchQuery: '',
  sidebarFilterQuery: '',
  editingMode: null,
  editingInstanceId: null,
  editingTemplate: null
};

let toastTimer: number | null = null;
let dragSourceId: string | null = null;
let gestureModal: GestureBoardModal | null = null;

function el<T extends HTMLElement>(id: string): T {
  const found = document.getElementById(id);
  if (!found) {
    throw new Error(`Missing required element #${id}`);
  }
  return found as T;
}

function showToast(message: string): void {
  const toast = el<HTMLDivElement>('toast');
  toast.textContent = message;
  toast.classList.remove('hidden');
  if (toastTimer !== null) {
    window.clearTimeout(toastTimer);
  }
  toastTimer = window.setTimeout(() => {
    toast.classList.add('hidden');
  }, 2400);
}

function isAnyModalOpen(): boolean {
  return (
    !el('catalog-modal').classList.contains('hidden') ||
    !el('edit-modal').classList.contains('hidden') ||
    !el('settings-modal').classList.contains('hidden') ||
    !el('gesture-modal').classList.contains('hidden')
  );
}

async function syncOverlayToMain(): Promise<void> {
  await omniApi.setOverlayVisible(isAnyModalOpen());
}

function getVisibleInstances(): ServiceInstance[] {
  if (!state.config) return [];
  const query = state.sidebarFilterQuery.trim().toLowerCase();

  return state.config.instances.filter((inst) => {
    if (!query) return true;
    return (
      inst.name.toLowerCase().includes(query) ||
      inst.url.toLowerCase().includes(query)
    );
  });
}

function getActiveInstance(): ServiceInstance | undefined {
  if (!state.config?.settings.activeInstanceId) return undefined;
  return state.config.instances.find(
    (item) => item.instanceId === state.config?.settings.activeInstanceId
  );
}

function applyThemeAndLayout(): void {
  if (!state.config) return;
  const { theme, sidebarWidth } = state.config.settings;
  document.documentElement.setAttribute('data-theme', theme);
  document.documentElement.style.setProperty('--sidebar-width', `${sidebarWidth}px`);

  const gestureBtn = el<HTMLButtonElement>('btn-gesture-settings');
  const gestureOn = Boolean(state.config.settings.gesture?.enabled);
  gestureBtn.classList.toggle('gesture-on', gestureOn);
  gestureBtn.title = gestureOn
    ? 'マウスジェスチャー設定（有効 · 右ドラッグで操作）'
    : 'マウスジェスチャー設定（無効）';
}

function renderSidebar(): void {
  if (!state.config) return;
  const listEl = el<HTMLDivElement>('service-list');
  const visible = getVisibleInstances();
  const activeId = state.config.settings.activeInstanceId;

  let totalUnread = 0;
  for (const inst of state.config.instances) {
    if (!inst.notificationsEnabled) continue;
    totalUnread += state.runtimeMap.get(inst.instanceId)?.unreadCount ?? 0;
  }

  const totalBadge = el<HTMLSpanElement>('total-unread-badge');
  if (totalUnread > 0 && !state.isLocked) {
    totalBadge.textContent = totalUnread > 99 ? '99+' : String(totalUnread);
    totalBadge.classList.remove('hidden');
  } else {
    totalBadge.classList.add('hidden');
  }

  listEl.innerHTML = '';

  if (visible.length === 0) {
    const emptyMsg = document.createElement('div');
    emptyMsg.style.padding = '16px 10px';
    emptyMsg.style.color = 'var(--text-muted)';
    emptyMsg.style.fontSize = '12px';
    emptyMsg.style.textAlign = 'center';
    emptyMsg.textContent = state.sidebarFilterQuery
      ? '該当するサービスがありません'
      : '下のボタンからSNSを追加してください';
    listEl.appendChild(emptyMsg);
    return;
  }

  visible.forEach((inst) => {
    const rt = state.runtimeMap.get(inst.instanceId);
    const item = document.createElement('div');
    item.className = 'service-item';
    item.setAttribute('role', 'tab');
    item.setAttribute('aria-selected', String(inst.instanceId === activeId));
    item.draggable = !state.sidebarFilterQuery;
    item.dataset.instanceId = inst.instanceId;

    if (inst.instanceId === activeId) item.classList.add('active');
    if (rt?.isSleeping) item.classList.add('sleeping');

    // Drag & drop reorder
    item.addEventListener('dragstart', (e) => {
      dragSourceId = inst.instanceId;
      item.classList.add('dragging');
      e.dataTransfer?.setData('text/plain', inst.instanceId);
    });
    item.addEventListener('dragend', () => {
      dragSourceId = null;
      item.classList.remove('dragging');
      listEl.querySelectorAll('.drag-over').forEach((node) => node.classList.remove('drag-over'));
    });
    item.addEventListener('dragover', (e) => {
      if (!dragSourceId || dragSourceId === inst.instanceId) return;
      e.preventDefault();
      item.classList.add('drag-over');
    });
    item.addEventListener('dragleave', () => {
      item.classList.remove('drag-over');
    });
    item.addEventListener('drop', async (e) => {
      e.preventDefault();
      item.classList.remove('drag-over');
      if (!dragSourceId || dragSourceId === inst.instanceId || !state.config) return;

      const ids = state.config.instances.map((x) => x.instanceId);
      const fromIndex = ids.indexOf(dragSourceId);
      const toIndex = ids.indexOf(inst.instanceId);
      if (fromIndex === -1 || toIndex === -1) return;

      ids.splice(fromIndex, 1);
      ids.splice(toIndex, 0, dragSourceId);
      await omniApi.reorderTabs(ids);
    });

    item.addEventListener('click', async () => {
      await omniApi.activateTab(inst.instanceId);
    });

    // Avatar
    const avatar = document.createElement('div');
    avatar.className = 'service-avatar';
    avatar.style.background = inst.color;
    if (rt?.faviconUrl) {
      const img = document.createElement('img');
      img.src = rt.faviconUrl;
      img.alt = '';
      img.onerror = () => {
        avatar.textContent = inst.badge;
      };
      avatar.appendChild(img);
    } else {
      avatar.textContent = inst.badge;
    }

    // Meta
    const meta = document.createElement('div');
    meta.className = 'service-meta';

    const nameEl = document.createElement('div');
    nameEl.className = 'service-name';
    nameEl.textContent = inst.name;

    const subEl = document.createElement('div');
    subEl.className = 'service-sub';
    if (inst.uaMode === 'mobile') {
      const uaTag = document.createElement('span');
      uaTag.className = 'tag-mini';
      uaTag.textContent = 'スマホUA';
      subEl.appendChild(uaTag);
    }
    if ((rt?.tabs?.length ?? 0) >= 2) {
      const tabTag = document.createElement('span');
      tabTag.className = 'tag-mini';
      tabTag.textContent = `${rt!.tabs.length}タブ`;
      subEl.appendChild(tabTag);
    }
    if (rt?.isSleeping) {
      const sleepTag = document.createElement('span');
      sleepTag.textContent = '休止中';
      subEl.appendChild(sleepTag);
    } else if (inst.muted) {
      const muteTag = document.createElement('span');
      muteTag.textContent = 'ミュート';
      subEl.appendChild(muteTag);
    }

    meta.appendChild(nameEl);
    if (subEl.childNodes.length > 0) {
      meta.appendChild(subEl);
    }

    // Right side (unread badge + hover actions)
    const right = document.createElement('div');
    right.className = 'service-right';

    const unread = inst.notificationsEnabled ? rt?.unreadCount ?? 0 : 0;
    if (unread > 0) {
      const badge = document.createElement('span');
      badge.className = 'unread-badge';
      badge.textContent = unread > 99 ? '99+' : String(unread);
      right.appendChild(badge);
    }

    const actions = document.createElement('div');
    actions.className = 'item-actions';

    const editBtn = document.createElement('button');
    editBtn.className = 'mini-action-btn';
    editBtn.title = '名前・URL編集';
    editBtn.textContent = '✎';
    editBtn.addEventListener('click', (e) => {
      e.stopPropagation();
      void openEditModalForExisting(inst);
    });

    const delBtn = document.createElement('button');
    delBtn.className = 'mini-action-btn danger';
    delBtn.title = 'サイドバーから削除';
    delBtn.textContent = '✕';
    delBtn.addEventListener('click', async (e) => {
      e.stopPropagation();
      const confirmed = window.confirm(`「${inst.name}」を一覧から削除しますか？`);
      if (!confirmed) return;
      await omniApi.removeTab(inst.instanceId);
      showToast(`「${inst.name}」を削除しました`);
    });

    actions.appendChild(editBtn);
    actions.appendChild(delBtn);
    right.appendChild(actions);

    item.appendChild(avatar);
    item.appendChild(meta);
    item.appendChild(right);
    listEl.appendChild(item);
  });
}

const ICON_VOLUME_ON =
  '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5"/><path d="M15.54 8.46a5 5 0 0 1 0 7.07"/><path d="M19.07 4.93a10 10 0 0 1 0 14.14"/></svg>';
const ICON_VOLUME_OFF =
  '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5"/><line x1="23" y1="9" x2="17" y2="15"/><line x1="17" y1="9" x2="23" y2="15"/></svg>';

function renderToolbarAndViewport(): void {
  const active = getActiveInstance();
  const rt = active ? state.runtimeMap.get(active.instanceId) : undefined;

  const backBtn = el<HTMLButtonElement>('btn-back');
  const fwdBtn = el<HTMLButtonElement>('btn-forward');
  const dotEl = el<HTMLSpanElement>('active-service-dot');
  const nameEl = el<HTMLSpanElement>('active-service-name');
  const urlEl = el<HTMLSpanElement>('active-url-text');
  const uaBtn = el<HTMLButtonElement>('btn-toggle-ua');
  const muteBtn = el<HTMLButtonElement>('btn-toggle-mute');
  const zoomResetBtn = el<HTMLButtonElement>('btn-zoom-reset');

  const emptyEl = el<HTMLDivElement>('empty-state');
  const sleepingEl = el<HTMLDivElement>('sleeping-state');
  const errorEl = el<HTMLDivElement>('error-state');

  emptyEl.classList.add('hidden');
  sleepingEl.classList.add('hidden');
  errorEl.classList.add('hidden');

  if (!active) {
    backBtn.disabled = true;
    fwdBtn.disabled = true;
    dotEl.className = 'status-dot';
    nameEl.textContent = 'サービス未選択';
    urlEl.textContent = '—';
    uaBtn.textContent = 'PC版';
    uaBtn.classList.remove('mobile-mode');
    muteBtn.innerHTML = ICON_VOLUME_ON;
    zoomResetBtn.textContent = '100%';
    emptyEl.classList.remove('hidden');
    return;
  }

  backBtn.disabled = !rt?.canGoBack;
  fwdBtn.disabled = !rt?.canGoForward;
  dotEl.className = `status-dot ${rt?.isLoading ? 'loading' : rt?.isSleeping ? '' : 'ready'}`;
  nameEl.textContent = active.name;
  urlEl.textContent = rt?.currentUrl || active.url;

  const isMobile = active.uaMode === 'mobile';
  uaBtn.textContent = isMobile ? 'スマホ版' : 'PC版';
  uaBtn.classList.toggle('mobile-mode', isMobile);

  muteBtn.innerHTML = active.muted ? ICON_VOLUME_OFF : ICON_VOLUME_ON;
  zoomResetBtn.textContent = `${Math.round(active.zoomFactor * 100)}%`;

  if (rt?.isSleeping) {
    el<HTMLHeadingElement>('sleeping-title').textContent = `「${active.name}」は休止中です`;
    sleepingEl.classList.remove('hidden');
  } else if (rt?.loadError) {
    el<HTMLParagraphElement>('error-detail').textContent = rt.loadError;
    errorEl.classList.remove('hidden');
  }
}

function renderLockOverlay(): void {
  const overlay = el<HTMLDivElement>('lock-overlay');
  const pinInput = el<HTMLInputElement>('unlock-pin-input');
  const errEl = el<HTMLDivElement>('unlock-error');

  if (!state.isLocked) {
    overlay.classList.add('hidden');
    pinInput.value = '';
    errEl.classList.add('hidden');
    return;
  }

  overlay.classList.remove('hidden');
  const hasPin = Boolean(state.config?.settings.lockPin);
  pinInput.classList.toggle('hidden', !hasPin);
  if (hasPin) {
    window.setTimeout(() => pinInput.focus(), 40);
  }
}

function renderCatalog(): void {
  const catTabs = el<HTMLDivElement>('catalog-categories');
  const grid = el<HTMLDivElement>('catalog-grid');
  const customForm = el<HTMLFormElement>('custom-service-form');

  // Category tabs
  catTabs.innerHTML = '';
  const allTab = document.createElement('button');
  allTab.type = 'button';
  allTab.className = `cat-tab ${state.selectedCatalogCategory === 'all' ? 'active' : ''}`;
  allTab.textContent = `すべて (${state.catalog.length})`;
  allTab.addEventListener('click', () => {
    state.selectedCatalogCategory = 'all';
    renderCatalog();
  });
  catTabs.appendChild(allTab);

  for (const cat of state.categories) {
    const count =
      cat.id === 'custom'
        ? null
        : state.catalog.filter((s) => s.category === cat.id).length;

    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'cat-tab';
    if (state.selectedCatalogCategory === cat.id) btn.classList.add('active');
    btn.textContent = count !== null ? `${cat.label} (${count})` : cat.label;
    btn.addEventListener('click', () => {
      state.selectedCatalogCategory = cat.id;
      renderCatalog();
    });
    catTabs.appendChild(btn);
  }

  if (state.selectedCatalogCategory === 'custom') {
    grid.classList.add('hidden');
    customForm.classList.remove('hidden');
    return;
  }

  grid.classList.remove('hidden');
  customForm.classList.add('hidden');

  const q = state.catalogSearchQuery.trim().toLowerCase();
  const filtered = state.catalog.filter((svc) => {
    if (state.selectedCatalogCategory !== 'all' && svc.category !== state.selectedCatalogCategory) {
      return false;
    }
    if (!q) return true;
    return (
      svc.name.toLowerCase().includes(q) ||
      svc.id.toLowerCase().includes(q) ||
      svc.description.toLowerCase().includes(q) ||
      svc.aliases.some((alias) => alias.toLowerCase().includes(q))
    );
  });

  // Count how many times each service is already added
  const addedCounts = new Map<string, number>();
  for (const inst of state.config?.instances ?? []) {
    addedCounts.set(inst.serviceId, (addedCounts.get(inst.serviceId) ?? 0) + 1);
  }

  grid.innerHTML = '';

  if (filtered.length === 0) {
    const noMatch = document.createElement('div');
    noMatch.style.gridColumn = '1 / -1';
    noMatch.style.textAlign = 'center';
    noMatch.style.padding = '36px 12px';
    noMatch.style.color = 'var(--text-secondary)';
    noMatch.innerHTML =
      '一致するサービスが見つかりません。「カスタム追加」タブから任意のURLを自由に追加できます。';
    grid.appendChild(noMatch);
    return;
  }

  for (const svc of filtered) {
    const count = addedCounts.get(svc.id) ?? 0;
    const card = document.createElement('div');
    card.className = 'catalog-card';

    const top = document.createElement('div');
    top.className = 'catalog-card-top';

    const avatar = document.createElement('div');
    avatar.className = 'service-avatar';
    avatar.style.background = svc.color;
    avatar.textContent = svc.badge;

    const titleWrap = document.createElement('div');
    titleWrap.className = 'catalog-card-title-wrap';

    const title = document.createElement('div');
    title.className = 'catalog-card-title';
    title.textContent = svc.name;

    if (count > 0) {
      const chip = document.createElement('span');
      chip.className = 'added-chip';
      chip.textContent = count === 1 ? '追加済み' : `${count}個追加済み`;
      title.appendChild(chip);
    }

    const urlSub = document.createElement('div');
    urlSub.className = 'catalog-card-url';
    urlSub.textContent = svc.url;

    titleWrap.appendChild(title);
    titleWrap.appendChild(urlSub);
    top.appendChild(avatar);
    top.appendChild(titleWrap);

    const desc = document.createElement('div');
    desc.className = 'catalog-card-desc';
    desc.textContent = svc.description;

    card.appendChild(top);
    card.appendChild(desc);

    if (svc.note) {
      const note = document.createElement('div');
      note.className = 'catalog-card-note';
      note.textContent = `※ ${svc.note}`;
      card.appendChild(note);
    }

    const actions = document.createElement('div');
    actions.className = 'catalog-card-actions';

    const addBtn = document.createElement('button');
    addBtn.type = 'button';
    addBtn.className = 'btn-primary';
    addBtn.textContent = count > 0 ? '＋ 別アカウント追加' : '＋ 追加して開く';
    addBtn.addEventListener('click', async () => {
      if (svc.requiresCustomUrl) {
        await openEditModalForTemplate(svc, count);
        return;
      }
      const label = count > 0 ? `${svc.name} (${count + 1})` : svc.name;
      await addServiceAndCloseCatalog({
        serviceId: svc.id,
        name: label,
        category: svc.category,
        url: svc.url,
        color: svc.color,
        badge: svc.badge,
        uaMode: svc.defaultUa
      });
    });

    const customizeBtn = document.createElement('button');
    customizeBtn.type = 'button';
    customizeBtn.className = 'btn-secondary';
    customizeBtn.textContent = '詳細設定';
    customizeBtn.title = '名前やURLを変更してから追加';
    customizeBtn.addEventListener('click', () => {
      void openEditModalForTemplate(svc, count);
    });

    actions.appendChild(addBtn);
    actions.appendChild(customizeBtn);
    card.appendChild(actions);
    grid.appendChild(card);
  }
}

async function addServiceAndCloseCatalog(payload: AddInstancePayload): Promise<void> {
  await omniApi.addTab(payload);
  el('catalog-modal').classList.add('hidden');
  el('edit-modal').classList.add('hidden');
  await syncOverlayToMain();
  showToast(`「${payload.name}」を追加しました`);
}

async function openCatalogModal(): Promise<void> {
  if (state.isLocked) return;
  el('catalog-modal').classList.remove('hidden');
  await syncOverlayToMain();
  renderCatalog();
  const searchInput = el<HTMLInputElement>('catalog-search');
  searchInput.focus();
  searchInput.select();
}

async function closeCatalogModal(): Promise<void> {
  el('catalog-modal').classList.add('hidden');
  await syncOverlayToMain();
}

async function openEditModalForTemplate(svc: CatalogService, existingCount: number): Promise<void> {
  state.editingMode = 'create';
  state.editingInstanceId = null;
  state.editingTemplate = svc;

  el<HTMLHeadingElement>('edit-modal-title').textContent = `${svc.name} を詳細追加`;
  el<HTMLInputElement>('edit-name').value = existingCount > 0 ? `${svc.name} (${existingCount + 1})` : svc.name;
  el<HTMLInputElement>('edit-url').value = svc.url;
  el<HTMLSelectElement>('edit-ua').value = svc.defaultUa;
  el<HTMLInputElement>('edit-color').value = svc.color;
  el<HTMLInputElement>('edit-notifications').checked = true;

  el('edit-modal').classList.remove('hidden');
  await syncOverlayToMain();
  el<HTMLInputElement>('edit-name').focus();
}

async function openEditModalForExisting(inst: ServiceInstance): Promise<void> {
  state.editingMode = 'edit';
  state.editingInstanceId = inst.instanceId;
  state.editingTemplate = null;

  el<HTMLHeadingElement>('edit-modal-title').textContent = `「${inst.name}」の設定`;
  el<HTMLInputElement>('edit-name').value = inst.name;
  el<HTMLInputElement>('edit-url').value = inst.url;
  el<HTMLSelectElement>('edit-ua').value = inst.uaMode;
  el<HTMLInputElement>('edit-color').value = inst.color;
  el<HTMLInputElement>('edit-notifications').checked = inst.notificationsEnabled;

  el('edit-modal').classList.remove('hidden');
  await syncOverlayToMain();
  el<HTMLInputElement>('edit-name').focus();
}

async function closeEditModal(): Promise<void> {
  el('edit-modal').classList.add('hidden');
  state.editingMode = null;
  state.editingInstanceId = null;
  state.editingTemplate = null;
  await syncOverlayToMain();
}

async function openSettingsModal(): Promise<void> {
  if (!state.config || state.isLocked) return;
  const s = state.config.settings;
  el<HTMLSelectElement>('setting-theme').value = s.theme;
  el<HTMLInputElement>('setting-minimize-tray').checked = s.minimizeToTray;
  el<HTMLInputElement>('setting-sidebar-width').value = String(s.sidebarWidth);
  el<HTMLSpanElement>('setting-sidebar-width-val').textContent = String(s.sidebarWidth);
  el<HTMLInputElement>('setting-lock-pin').value = s.lockPin;

  el('settings-modal').classList.remove('hidden');
  await syncOverlayToMain();
}

async function closeSettingsModal(): Promise<void> {
  el('settings-modal').classList.add('hidden');
  await syncOverlayToMain();
}

async function openGestureModal(): Promise<void> {
  if (!state.config || state.isLocked || !gestureModal) return;
  gestureModal.open(state.config.settings.gesture);
  await syncOverlayToMain();
}

async function closeGestureModal(): Promise<void> {
  gestureModal?.close();
  await syncOverlayToMain();
}

function renderTabBar(): void {
  const stripEl = el<HTMLDivElement>('tab-strip');
  const newBtn = el<HTMLButtonElement>('btn-new-subtab');
  const dupBtn = el<HTMLButtonElement>('btn-dup-subtab');
  const closeOthersBtn = el<HTMLButtonElement>('btn-close-other-subtabs');
  const restoreBtn = el<HTMLButtonElement>('btn-restore-subtab');
  const closedCountEl = el<HTMLSpanElement>('closed-tabs-count');

  const active = getActiveInstance();
  const rt = active ? state.runtimeMap.get(active.instanceId) : undefined;
  const tabs = rt?.tabs ?? [];

  newBtn.disabled = !active;
  dupBtn.disabled = !active || tabs.length === 0;
  closeOthersBtn.disabled = !active || tabs.length <= 1;
  restoreBtn.disabled = state.closedTabsCount === 0;

  if (state.closedTabsCount > 0) {
    closedCountEl.textContent = String(state.closedTabsCount);
    closedCountEl.classList.remove('hidden');
  } else {
    closedCountEl.classList.add('hidden');
  }

  stripEl.innerHTML = '';
  if (!active || tabs.length === 0) return;

  for (const tab of tabs) {
    const isCurrent = tab.tabId === rt?.activeTabId;
    const chip = document.createElement('div');
    chip.className = 'browser-tab';
    chip.setAttribute('role', 'tab');
    chip.setAttribute('aria-selected', String(isCurrent));
    if (isCurrent) chip.classList.add('active');
    if (tab.isLoading) chip.classList.add('loading');
    chip.title = `${tab.title || active.name}\n${tab.currentUrl}\n（中クリックで閉じる）`;

    chip.addEventListener('click', () => {
      if (!isCurrent) {
        void omniApi.activateSubTab(active.instanceId, tab.tabId);
      }
    });
    chip.addEventListener('auxclick', (e) => {
      if (e.button === 1) {
        e.preventDefault();
        void omniApi.closeSubTab(active.instanceId, tab.tabId).then((msg) => {
          if (msg) showToast(msg);
        });
      }
    });

    const icon = document.createElement('span');
    icon.className = 'browser-tab-icon';
    icon.style.background = active.color;
    if (tab.faviconUrl) {
      const img = document.createElement('img');
      img.src = tab.faviconUrl;
      img.alt = '';
      img.onerror = () => {
        icon.textContent = active.badge;
      };
      icon.appendChild(img);
    } else {
      icon.textContent = active.badge;
    }

    const title = document.createElement('span');
    title.className = 'browser-tab-title';
    title.textContent = tab.title || active.name;

    const closeBtn = document.createElement('button');
    closeBtn.type = 'button';
    closeBtn.className = 'browser-tab-close';
    closeBtn.textContent = '✕';
    closeBtn.title = 'このタブを閉じる';
    closeBtn.addEventListener('click', (e) => {
      e.stopPropagation();
      void omniApi.closeSubTab(active.instanceId, tab.tabId).then((msg) => {
        if (msg) showToast(msg);
      });
    });

    chip.appendChild(icon);
    chip.appendChild(title);
    chip.appendChild(closeBtn);
    stripEl.appendChild(chip);
  }
}

function renderAll(): void {
  applyThemeAndLayout();
  renderSidebar();
  renderToolbarAndViewport();
  renderTabBar();
  renderLockOverlay();
  if (state.config?.settings.gesture) {
    gestureModal?.syncSettings(state.config.settings.gesture);
  }
  if (!el('catalog-modal').classList.contains('hidden')) {
    renderCatalog();
  }
}

function bindEvents(): void {
  // Sidebar
  el<HTMLInputElement>('sidebar-filter').addEventListener('input', (e) => {
    state.sidebarFilterQuery = (e.target as HTMLInputElement).value;
    renderSidebar();
  });

  el<HTMLButtonElement>('btn-open-catalog').addEventListener('click', () => void openCatalogModal());
  el<HTMLButtonElement>('btn-empty-add').addEventListener('click', () => void openCatalogModal());

  el<HTMLButtonElement>('btn-lock-app').addEventListener('click', async () => {
    await omniApi.setLocked(true);
  });

  el<HTMLButtonElement>('btn-open-settings').addEventListener('click', () => void openSettingsModal());

  // Toolbar actions
  const runActiveAction = async (action: string) => {
    const active = getActiveInstance();
    if (!active) return;
    await omniApi.tabAction(active.instanceId, action);
  };

  el<HTMLButtonElement>('btn-back').addEventListener('click', () => void runActiveAction('back'));
  el<HTMLButtonElement>('btn-forward').addEventListener('click', () => void runActiveAction('forward'));
  el<HTMLButtonElement>('btn-reload').addEventListener('click', (e) => {
    void runActiveAction(e.shiftKey ? 'hard-reload' : 'reload');
  });
  el<HTMLButtonElement>('btn-home').addEventListener('click', () => void runActiveAction('home'));
  el<HTMLButtonElement>('btn-open-external').addEventListener('click', () => void runActiveAction('open-external'));
  el<HTMLButtonElement>('btn-toggle-ua').addEventListener('click', async () => {
    const active = getActiveInstance();
    if (!active) return;
    await omniApi.tabAction(active.instanceId, 'toggle-ua');
    showToast(active.uaMode === 'desktop' ? 'モバイル版UAへ切り替えました' : 'PC版UAへ切り替えました');
  });
  el<HTMLButtonElement>('btn-toggle-mute').addEventListener('click', () => void runActiveAction('toggle-mute'));
  el<HTMLButtonElement>('btn-zoom-out').addEventListener('click', () => void runActiveAction('zoom-out'));
  el<HTMLButtonElement>('btn-zoom-reset').addEventListener('click', () => void runActiveAction('zoom-reset'));
  el<HTMLButtonElement>('btn-zoom-in').addEventListener('click', () => void runActiveAction('zoom-in'));
  el<HTMLButtonElement>('btn-sleep-tab').addEventListener('click', async () => {
    const active = getActiveInstance();
    if (!active) return;
    await omniApi.tabAction(active.instanceId, 'sleep');
    showToast(`「${active.name}」を休止しました（メモリ解放）`);
  });
  el<HTMLButtonElement>('btn-clear-session').addEventListener('click', async () => {
    const active = getActiveInstance();
    if (!active) return;
    const ok = window.confirm(
      `「${active.name}」のCookie・ログイン情報・キャッシュをすべて削除しますか？\n（他のサービスには影響しません）`
    );
    if (!ok) return;
    await omniApi.tabAction(active.instanceId, 'clear-session');
    showToast(`「${active.name}」のセッションを初期化しました`);
  });
  el<HTMLButtonElement>('btn-gesture-settings').addEventListener('click', () => void openGestureModal());
  el<HTMLButtonElement>('btn-devtools').addEventListener('click', () => void runActiveAction('devtools'));

  // Multi-Tab Bar actions
  el<HTMLButtonElement>('btn-new-subtab').addEventListener('click', async () => {
    const active = getActiveInstance();
    if (!active) return;
    try {
      await omniApi.createSubTab(active.instanceId);
    } catch (err) {
      showToast(String(err));
    }
  });
  el<HTMLDivElement>('tab-strip').addEventListener('dblclick', (e) => {
    if (e.target !== el('tab-strip')) return;
    const active = getActiveInstance();
    if (!active) return;
    void omniApi.createSubTab(active.instanceId);
  });
  el<HTMLButtonElement>('btn-dup-subtab').addEventListener('click', async () => {
    const active = getActiveInstance();
    const rt = active ? state.runtimeMap.get(active.instanceId) : undefined;
    if (!active || !rt?.activeTabId) return;
    try {
      await omniApi.duplicateSubTab(active.instanceId, rt.activeTabId);
    } catch (err) {
      showToast(String(err));
    }
  });
  el<HTMLButtonElement>('btn-close-other-subtabs').addEventListener('click', async () => {
    const active = getActiveInstance();
    const rt = active ? state.runtimeMap.get(active.instanceId) : undefined;
    if (!active || !rt?.activeTabId) return;
    const closed = await omniApi.closeOtherSubTabs(active.instanceId, rt.activeTabId);
    if (closed > 0) showToast(`他のタブ ${closed} 枚を閉じました`);
  });
  el<HTMLButtonElement>('btn-restore-subtab').addEventListener('click', async () => {
    try {
      const msg = await omniApi.restoreClosedTab();
      showToast(msg);
    } catch (err) {
      showToast(String(err));
    }
  });

  el<HTMLButtonElement>('btn-copy-url').addEventListener('click', async () => {
    const urlText = el<HTMLSpanElement>('active-url-text').textContent || '';
    if (!urlText || urlText === '—') return;
    await omniApi.copyText(urlText);
    showToast('URLをクリップボードにコピーしました');
  });

  // Placeholder buttons
  el<HTMLButtonElement>('btn-wake-tab').addEventListener('click', () => void runActiveAction('wake'));
  el<HTMLButtonElement>('btn-error-reload').addEventListener('click', () => void runActiveAction('reload'));
  el<HTMLButtonElement>('btn-error-external').addEventListener('click', () => void runActiveAction('open-external'));

  // Catalog modal
  el<HTMLButtonElement>('btn-close-catalog').addEventListener('click', () => void closeCatalogModal());
  el<HTMLInputElement>('catalog-search').addEventListener('input', (e) => {
    state.catalogSearchQuery = (e.target as HTMLInputElement).value;
    if (state.selectedCatalogCategory === 'custom' && state.catalogSearchQuery.trim()) {
      state.selectedCatalogCategory = 'all';
    }
    renderCatalog();
  });

  el<HTMLFormElement>('custom-service-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const name = el<HTMLInputElement>('custom-name').value.trim();
    const rawUrl = el<HTMLInputElement>('custom-url').value.trim();
    const normalized = normalizeServiceUrl(rawUrl);
    if (!normalized) {
      showToast('有効な http:// または https:// URL を入力してください');
      return;
    }
    const category = el<HTMLSelectElement>('custom-category').value as ServiceCategory;
    const uaMode = el<HTMLSelectElement>('custom-ua').value as UserAgentMode;
    const color = el<HTMLInputElement>('custom-color').value;

    await addServiceAndCloseCatalog({
      serviceId: 'custom',
      name: name || 'カスタムSNS',
      category,
      url: normalized,
      color,
      badge: makeBadgeText(name || 'SN'),
      uaMode
    });
    el<HTMLFormElement>('custom-service-form').reset();
  });

  // Edit / detailed add modal
  el<HTMLButtonElement>('btn-close-edit').addEventListener('click', () => void closeEditModal());
  el<HTMLButtonElement>('btn-cancel-edit').addEventListener('click', () => void closeEditModal());
  el<HTMLFormElement>('edit-service-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const name = el<HTMLInputElement>('edit-name').value.trim();
    const normalized = normalizeServiceUrl(el<HTMLInputElement>('edit-url').value);
    if (!normalized) {
      showToast('有効なURLを入力してください');
      return;
    }
    const uaMode = el<HTMLSelectElement>('edit-ua').value as UserAgentMode;
    const color = el<HTMLInputElement>('edit-color').value;
    const notificationsEnabled = el<HTMLInputElement>('edit-notifications').checked;

    if (state.editingMode === 'create' && state.editingTemplate) {
      const tpl = state.editingTemplate;
      await addServiceAndCloseCatalog({
        serviceId: tpl.id,
        name: name || tpl.name,
        category: tpl.category,
        url: normalized,
        color,
        badge: tpl.badge,
        uaMode
      });
    } else if (state.editingMode === 'edit' && state.editingInstanceId) {
      const targetId = state.editingInstanceId;
      const existing = state.config?.instances.find((x) => x.instanceId === targetId);
      await omniApi.updateTab(targetId, {
        name: name || existing?.name || 'SNS',
        url: normalized,
        color,
        notificationsEnabled
      });
      if (existing && existing.uaMode !== uaMode) {
        await omniApi.tabAction(targetId, 'toggle-ua');
      }
      await closeEditModal();
      showToast('サービス設定を保存しました');
    }
  });

  // Settings modal
  el<HTMLButtonElement>('btn-close-settings').addEventListener('click', () => void closeSettingsModal());
  el<HTMLInputElement>('setting-sidebar-width').addEventListener('input', (e) => {
    const val = (e.target as HTMLInputElement).value;
    el<HTMLSpanElement>('setting-sidebar-width-val').textContent = val;
  });
  el<HTMLButtonElement>('btn-save-settings').addEventListener('click', async () => {
    await omniApi.updateSettings({
      theme: el<HTMLSelectElement>('setting-theme').value as 'dark' | 'light',
      minimizeToTray: el<HTMLInputElement>('setting-minimize-tray').checked,
      sidebarWidth: Number(el<HTMLInputElement>('setting-sidebar-width').value),
      lockPin: el<HTMLInputElement>('setting-lock-pin').value
    });
    await closeSettingsModal();
    showToast('アプリ設定を保存しました');
  });

  // Unlock form
  el<HTMLFormElement>('unlock-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const pin = el<HTMLInputElement>('unlock-pin-input').value;
    const res = await omniApi.setLocked(false, pin);
    if (!res.ok) {
      const errEl = el<HTMLDivElement>('unlock-error');
      errEl.textContent = res.error || '解除に失敗しました';
      errEl.classList.remove('hidden');
      el<HTMLInputElement>('unlock-pin-input').select();
    }
  });

  // Global keyboard shortcuts inside shell UI
  window.addEventListener('keydown', (e) => {
    if (gestureModal?.handleKeyDown(e)) {
      return;
    }

    if (e.key === 'Escape') {
      if (!el('edit-modal').classList.contains('hidden')) {
        void closeEditModal();
      } else if (!el('catalog-modal').classList.contains('hidden')) {
        void closeCatalogModal();
      } else if (!el('settings-modal').classList.contains('hidden')) {
        void closeSettingsModal();
      }
      return;
    }

    const ctrl = e.ctrlKey || e.metaKey;
    if (!ctrl) return;
    const key = e.key.toLowerCase();

    if (e.shiftKey && key === 'l') {
      e.preventDefault();
      if (!state.isLocked) {
        void omniApi.setLocked(true);
      } else if (!state.config?.settings.lockPin) {
        void omniApi.setLocked(false);
      } else {
        el<HTMLInputElement>('unlock-pin-input').focus();
      }
      return;
    }

    if (e.shiftKey && !e.altKey && key === 't') {
      e.preventDefault();
      void omniApi.restoreClosedTab().then(showToast).catch((err) => showToast(String(err)));
      return;
    }

    if (!e.shiftKey && !e.altKey && key === 't') {
      e.preventDefault();
      const active = getActiveInstance();
      if (active) void omniApi.createSubTab(active.instanceId);
      return;
    }

    if (!e.shiftKey && !e.altKey && key === 'w') {
      e.preventDefault();
      const active = getActiveInstance();
      const rt = active ? state.runtimeMap.get(active.instanceId) : undefined;
      if (active && rt?.activeTabId) {
        void omniApi.closeSubTab(active.instanceId, rt.activeTabId).then((msg) => {
          if (msg) showToast(msg);
        });
      }
      return;
    }

    if (!e.altKey && key === 'tab') {
      e.preventDefault();
      const active = getActiveInstance();
      const rt = active ? state.runtimeMap.get(active.instanceId) : undefined;
      if (active && rt && rt.tabs.length >= 2) {
        const curIdx = rt.tabs.findIndex((t) => t.tabId === rt.activeTabId);
        const delta = e.shiftKey ? -1 : 1;
        const nextIdx = (curIdx + delta + rt.tabs.length) % rt.tabs.length;
        void omniApi.activateSubTab(active.instanceId, rt.tabs[nextIdx].tabId);
      }
      return;
    }

    if (!e.shiftKey && !e.altKey && key === 'k') {
      e.preventDefault();
      if (el('catalog-modal').classList.contains('hidden')) {
        void openCatalogModal();
      } else {
        void closeCatalogModal();
      }
      return;
    }

    if (!e.shiftKey && !e.altKey && /^[1-9]$/.test(key)) {
      e.preventDefault();
      const idx = Number(key) - 1;
      const visible = getVisibleInstances();
      if (visible[idx]) {
        void omniApi.activateTab(visible[idx].instanceId);
      }
    }
  });
}

async function bootstrap(): Promise<void> {
  gestureModal = new GestureBoardModal({
    onToast: showToast,
    onCloseRequested: closeGestureModal
  });
  bindEvents();

  omniApi.onStateUpdated((payload) => {
    state.config = payload.config;
    state.isLocked = payload.isLocked;
    state.closedTabsCount = payload.closedTabsCount ?? 0;
    state.runtimeMap = new Map(payload.runtimeStates.map((rt) => [rt.instanceId, rt]));
    renderAll();
  });

  omniApi.onRuntimeUpdated((rt) => {
    state.runtimeMap.set(rt.instanceId, rt);
    renderSidebar();
    renderToolbarAndViewport();
    renderTabBar();
  });

  omniApi.onShortcut((payload) => {
    if (payload.action === 'open-catalog') {
      void openCatalogModal();
    } else if (payload.action === 'open-gesture-settings') {
      void openGestureModal();
    } else if (payload.action === 'switch-tab' && typeof payload.payload === 'number') {
      const visible = getVisibleInstances();
      const target = visible[payload.payload];
      if (target) {
        void omniApi.activateTab(target.instanceId);
      }
    } else if (payload.action === 'focus-pin') {
      el<HTMLInputElement>('unlock-pin-input').focus();
    }
  });

  const data = await omniApi.getBootstrap();
  state.config = data.config;
  state.catalog = data.catalog;
  state.categories = data.categories;
  state.isLocked = data.isLocked;
  state.closedTabsCount = data.closedTabsCount ?? 0;
  state.runtimeMap = new Map(data.runtimeStates.map((rt) => [rt.instanceId, rt]));

  el<HTMLSpanElement>('app-version').textContent = `v${data.appVersion} · Windows`;

  renderAll();
}

void bootstrap();
