import { GestureBoardModal } from './gesture-ui';
import { omniApi } from './omni-api';
import {
  AddInstancePayload,
  AppConfig,
  ArchivedInstance,
  BrowserTabInfo,
  CatalogService,
  CategoryMeta,
  ServiceCategory,
  ServiceInstance,
  TabRuntimeState,
  UserAgentMode
} from '../shared/types';
import {
  detectPlatformServiceFromUrl,
  getAccountDisplayLabel,
  getServiceGroupKey,
  makeBadgeText,
  nextDefaultAccountLabel,
  normalizeServiceUrl
} from '../shared/url-utils';

interface ServiceGroup {
  key: string;
  serviceId: string;
  displayName: string;
  color: string;
  badge: string;
  accounts: ServiceInstance[];
}

interface UiState {
  config: AppConfig | null;
  catalog: CatalogService[];
  categories: CategoryMeta[];
  runtimeMap: Map<string, TabRuntimeState>;
  lastActiveByGroup: Map<string, string>;
  closedTabsCount: number;
  gmailOpen: boolean;
  gmailRuntime: BrowserTabInfo | null;
  selectedCatalogCategory: ServiceCategory | 'all' | 'archived';
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
  lastActiveByGroup: new Map(),
  closedTabsCount: 0,
  gmailOpen: false,
  gmailRuntime: null,
  selectedCatalogCategory: 'all',
  catalogSearchQuery: '',
  sidebarFilterQuery: '',
  editingMode: null,
  editingInstanceId: null,
  editingTemplate: null
};

let toastTimer: number | null = null;
let dragSourceGroupKey: string | null = null;
let dragSourceAccountId: string | null = null;
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

let confirmResolver: ((accepted: boolean) => void) | null = null;

function isAnyModalOpen(): boolean {
  return (
    !el('catalog-modal').classList.contains('hidden') ||
    !el('edit-modal').classList.contains('hidden') ||
    !el('settings-modal').classList.contains('hidden') ||
    !el('gesture-modal').classList.contains('hidden') ||
    !el('follow-modal').classList.contains('hidden') ||
    !el('archived-pick-modal').classList.contains('hidden') ||
    !el('confirm-modal').classList.contains('hidden')
  );
}

async function syncOverlayToMain(): Promise<void> {
  await omniApi.setOverlayVisible(isAnyModalOpen());
}

async function resolveConfirmDialog(accepted: boolean): Promise<void> {
  const modal = el<HTMLDivElement>('confirm-modal');
  const dialog = modal.querySelector<HTMLDivElement>('.modal-dialog');
  modal.classList.add('hidden');
  modal.classList.remove('anchored');
  if (dialog) {
    dialog.style.left = '';
    dialog.style.top = '';
  }
  const resolver = confirmResolver;
  confirmResolver = null;
  await syncOverlayToMain();
  resolver?.(accepted);
}

async function openConfirmDialog(options: {
  title: string;
  message: string;
  confirmLabel?: string;
  cancelLabel?: string;
  danger?: boolean;
  anchorEl?: HTMLElement | null;
  anchorPoint?: { x: number; y: number } | null;
}): Promise<boolean> {
  if (confirmResolver) {
    const prev = confirmResolver;
    confirmResolver = null;
    prev(false);
  }
  el<HTMLHeadingElement>('confirm-title').textContent = options.title;
  el<HTMLParagraphElement>('confirm-message').textContent = options.message;
  const okBtn = el<HTMLButtonElement>('btn-confirm-ok');
  okBtn.textContent = options.confirmLabel ?? 'OK';
  okBtn.className = options.danger === false ? 'btn-primary' : 'btn-danger';
  const cancelBtn = el<HTMLButtonElement>('btn-confirm-cancel');
  cancelBtn.textContent = options.cancelLabel ?? 'キャンセル';

  const modal = el<HTMLDivElement>('confirm-modal');
  const dialog = modal.querySelector<HTMLDivElement>('.modal-dialog');
  const anchorRect = options.anchorEl?.getBoundingClientRect() ?? null;
  const hasAnchor = Boolean(
    (anchorRect && (anchorRect.width > 0 || anchorRect.height > 0)) || options.anchorPoint
  );

  modal.classList.toggle('anchored', hasAnchor);
  if (dialog) {
    dialog.style.left = '';
    dialog.style.top = '';
  }

  modal.classList.remove('hidden');

  if (hasAnchor && dialog) {
    const pad = 12;
    const dlgRect = dialog.getBoundingClientRect();
    const dlgW = dlgRect.width || 360;
    const dlgH = dlgRect.height || 170;
    const vw = window.innerWidth;
    const vh = window.innerHeight;

    const refLeft = anchorRect ? anchorRect.left : options.anchorPoint!.x;
    const refRight = anchorRect ? anchorRect.right : options.anchorPoint!.x;
    const refTop = anchorRect ? anchorRect.top : options.anchorPoint!.y;
    const refBottom = anchorRect ? anchorRect.bottom : options.anchorPoint!.y;

    let left: number;
    let top: number;
    const isInSidebar = Boolean(options.anchorEl?.closest('#sidebar'));
    if (isInSidebar) {
      // 左サイドバーの削除ボタン -> ボタンのすぐ右側に配置
      left = refRight + 10;
      top = refTop - 18;
    } else if (refTop < 140) {
      // 上部ヘッダー／ツールバーのボタン -> ボタン直下に配置
      left = refRight - dlgW;
      top = refBottom + 8;
    } else if (refLeft < vw * 0.5) {
      left = refRight + 10;
      top = refTop - 18;
    } else {
      left = refLeft - dlgW - 10;
      top = refTop - 18;
    }

    left = Math.max(pad, Math.min(left, vw - dlgW - pad));
    top = Math.max(pad, Math.min(top, vh - dlgH - pad));
    dialog.style.left = `${Math.round(left)}px`;
    dialog.style.top = `${Math.round(top)}px`;
  }

  await syncOverlayToMain();
  cancelBtn.focus();

  return new Promise<boolean>((resolve) => {
    confirmResolver = resolve;
  });
}

function getCatalogService(serviceId: string): CatalogService | undefined {
  return state.catalog.find((s) => s.id === serviceId);
}

function getActiveInstance(): ServiceInstance | undefined {
  if (!state.config?.settings.activeInstanceId) return undefined;
  return state.config.instances.find(
    (item) => item.instanceId === state.config?.settings.activeInstanceId
  );
}

function recordLastActiveForCurrent(): void {
  const active = getActiveInstance();
  if (!active) return;
  state.lastActiveByGroup.set(getServiceGroupKey(active), active.instanceId);
}

function getServiceGroups(): ServiceGroup[] {
  if (!state.config) return [];
  const groups: ServiceGroup[] = [];
  const groupMap = new Map<string, ServiceGroup>();

  for (const inst of state.config.instances) {
    const key = getServiceGroupKey(inst);
    const existing = groupMap.get(key);
    if (existing) {
      existing.accounts.push(inst);
    } else {
      const catSvc = inst.serviceId !== 'custom' ? getCatalogService(inst.serviceId) : undefined;
      const displayName = catSvc?.name ?? inst.name.replace(/\s*\(\d+\)\s*$/, '').trim();
      const grp: ServiceGroup = {
        key,
        serviceId: inst.serviceId,
        displayName: displayName || inst.name,
        color: inst.color,
        badge: inst.badge,
        accounts: [inst]
      };
      groupMap.set(key, grp);
      groups.push(grp);
    }
  }
  return groups;
}

function getVisibleServiceGroups(): ServiceGroup[] {
  const groups = getServiceGroups();
  const query = state.sidebarFilterQuery.trim().toLowerCase();
  if (!query) return groups;

  return groups.filter((grp) => {
    if (grp.displayName.toLowerCase().includes(query)) return true;
    return grp.accounts.some(
      (inst) =>
        inst.name.toLowerCase().includes(query) ||
        (inst.accountLabel?.toLowerCase().includes(query) ?? false) ||
        inst.url.toLowerCase().includes(query)
    );
  });
}

function getActiveGroup(): ServiceGroup | undefined {
  const active = getActiveInstance();
  if (!active) return undefined;
  const key = getServiceGroupKey(active);
  return getServiceGroups().find((g) => g.key === key);
}

function pickTargetAccountForGroup(group: ServiceGroup): ServiceInstance {
  const rememberedId = state.lastActiveByGroup.get(group.key);
  if (rememberedId) {
    const found = group.accounts.find((a) => a.instanceId === rememberedId);
    if (found) return found;
  }
  return group.accounts[0];
}

async function activateGroup(group: ServiceGroup): Promise<void> {
  const target = pickTargetAccountForGroup(group);
  await omniApi.activateTab(target.instanceId);
}

function applyThemeAndLayout(): void {
  if (!state.config) return;
  const { theme, sidebarWidth } = state.config.settings;
  const headerCollapsed = Boolean(state.config.settings.headerCollapsed);
  document.documentElement.setAttribute('data-theme', theme);
  document.documentElement.style.setProperty('--sidebar-width', `${sidebarWidth}px`);

  const mainArea = el<HTMLDivElement>('main-area');
  const active = getActiveInstance();
  const activeTabCount = active ? state.runtimeMap.get(active.instanceId)?.tabs?.length ?? 0 : 0;
  mainArea.classList.toggle('header-collapsed', headerCollapsed);
  mainArea.classList.toggle('has-multi-tabs', activeTabCount >= 2);
  const toggleHeaderBtn = el<HTMLButtonElement>('btn-toggle-header');
  toggleHeaderBtn.textContent = headerCollapsed ? '▼' : '▲';
  toggleHeaderBtn.title = headerCollapsed ? 'ヘッダー項目を展開' : 'ヘッダー項目を折り畳む';
  toggleHeaderBtn.setAttribute(
    'aria-label',
    headerCollapsed ? 'ヘッダー項目を展開' : 'ヘッダー項目を折り畳む'
  );

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
  const visibleGroups = getVisibleServiceGroups();
  const active = getActiveInstance();
  const activeGroupKey = active ? getServiceGroupKey(active) : null;

  let totalUnread = 0;
  for (const inst of state.config.instances) {
    if (!inst.notificationsEnabled) continue;
    totalUnread += state.runtimeMap.get(inst.instanceId)?.unreadCount ?? 0;
  }

  const totalBadge = el<HTMLSpanElement>('total-unread-badge');
  if (totalUnread > 0) {
    totalBadge.textContent = totalUnread > 99 ? '99+' : String(totalUnread);
    totalBadge.classList.remove('hidden');
  } else {
    totalBadge.classList.add('hidden');
  }

  const archivedCount = state.config?.archivedInstances?.length ?? 0;
  const archivedBadge = el<HTMLSpanElement>('sidebar-archived-badge');
  if (archivedCount > 0) {
    archivedBadge.textContent = archivedCount > 99 ? '99+' : String(archivedCount);
    archivedBadge.classList.remove('hidden');
  } else {
    archivedBadge.classList.add('hidden');
  }

  listEl.innerHTML = '';

  if (visibleGroups.length === 0) {
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

  visibleGroups.forEach((group) => {
    const isActiveGroup = group.key === activeGroupKey;
    const primary = isActiveGroup && active ? active : pickTargetAccountForGroup(group);
    const primaryRt = state.runtimeMap.get(primary.instanceId);
    const allSleeping = group.accounts.every(
      (a) => state.runtimeMap.get(a.instanceId)?.isSleeping !== false
    );

    const item = document.createElement('div');
    item.className = 'service-item';
    item.setAttribute('role', 'tab');
    item.setAttribute('aria-selected', String(isActiveGroup));
    item.draggable = !state.sidebarFilterQuery;
    item.dataset.groupKey = group.key;

    if (isActiveGroup) item.classList.add('active');
    if (allSleeping) item.classList.add('sleeping');

    // Drag & drop reorder by SNS group
    item.addEventListener('dragstart', (e) => {
      dragSourceGroupKey = group.key;
      item.classList.add('dragging');
      e.dataTransfer?.setData('text/plain', group.key);
    });
    item.addEventListener('dragend', () => {
      dragSourceGroupKey = null;
      item.classList.remove('dragging');
      listEl.querySelectorAll('.drag-over').forEach((node) => node.classList.remove('drag-over'));
    });
    item.addEventListener('dragover', (e) => {
      if (!dragSourceGroupKey || dragSourceGroupKey === group.key) return;
      e.preventDefault();
      item.classList.add('drag-over');
    });
    item.addEventListener('dragleave', () => {
      item.classList.remove('drag-over');
    });
    item.addEventListener('drop', async (e) => {
      e.preventDefault();
      item.classList.remove('drag-over');
      if (!dragSourceGroupKey || dragSourceGroupKey === group.key) return;

      const allGroups = getServiceGroups();
      const fromIndex = allGroups.findIndex((g) => g.key === dragSourceGroupKey);
      const toIndex = allGroups.findIndex((g) => g.key === group.key);
      if (fromIndex === -1 || toIndex === -1) return;

      const [moved] = allGroups.splice(fromIndex, 1);
      allGroups.splice(toIndex, 0, moved);
      const flattenedIds = allGroups.flatMap((g) => g.accounts.map((a) => a.instanceId));
      await omniApi.reorderTabs(flattenedIds);
    });

    item.addEventListener('click', async () => {
      await activateGroup(group);
    });

    // Avatar
    const avatar = document.createElement('div');
    avatar.className = 'service-avatar';
    avatar.style.background = primary.color;
    const groupFavicon =
      primaryRt?.faviconUrl ??
      group.accounts.map((a) => state.runtimeMap.get(a.instanceId)?.faviconUrl).find(Boolean) ??
      null;
    if (groupFavicon) {
      const img = document.createElement('img');
      img.src = groupFavicon;
      img.alt = '';
      img.onerror = () => {
        avatar.textContent = primary.badge;
      };
      avatar.appendChild(img);
    } else {
      avatar.textContent = primary.badge;
    }

    // Meta
    const meta = document.createElement('div');
    meta.className = 'service-meta';

    const nameEl = document.createElement('div');
    nameEl.className = 'service-name';
    nameEl.textContent = group.displayName;

    const subEl = document.createElement('div');
    subEl.className = 'service-sub';
    if (group.accounts.length >= 2) {
      const accTag = document.createElement('span');
      accTag.className = 'tag-mini accent-tag';
      accTag.textContent = `${group.accounts.length}垢`;
      subEl.appendChild(accTag);
    }
    if (primary.uaMode === 'mobile') {
      const uaTag = document.createElement('span');
      uaTag.className = 'tag-mini';
      uaTag.textContent = 'スマホUA';
      subEl.appendChild(uaTag);
    }
    if ((primaryRt?.tabs?.length ?? 0) >= 2) {
      const tabTag = document.createElement('span');
      tabTag.className = 'tag-mini';
      tabTag.textContent = `${primaryRt!.tabs.length}タブ`;
      subEl.appendChild(tabTag);
    }
    if (allSleeping) {
      const sleepTag = document.createElement('span');
      sleepTag.textContent = '休止中';
      subEl.appendChild(sleepTag);
    } else if (primary.muted) {
      const muteTag = document.createElement('span');
      muteTag.textContent = 'ミュート';
      subEl.appendChild(muteTag);
    }

    meta.appendChild(nameEl);
    if (subEl.childNodes.length > 0) {
      meta.appendChild(subEl);
    }

    // Right side (aggregated unread badge + hover actions)
    const right = document.createElement('div');
    right.className = 'service-right';

    let groupUnread = 0;
    for (const acc of group.accounts) {
      if (!acc.notificationsEnabled) continue;
      groupUnread += state.runtimeMap.get(acc.instanceId)?.unreadCount ?? 0;
    }
    if (groupUnread > 0) {
      const badge = document.createElement('span');
      badge.className = 'unread-badge';
      badge.textContent = groupUnread > 99 ? '99+' : String(groupUnread);
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
      void openEditModalForExisting(primary, false);
    });

    const delBtn = document.createElement('button');
    delBtn.className = 'mini-action-btn danger';
    delBtn.title =
      group.accounts.length >= 2
        ? `「${group.displayName}」の全${group.accounts.length}アカウントを削除`
        : 'サイドバーから削除';
    delBtn.textContent = '✕';
    delBtn.addEventListener('click', async (e) => {
      e.stopPropagation();
      const msg =
        group.accounts.length >= 2
          ? `「${group.displayName}」（全${group.accounts.length}アカウント）を一覧から削除しますか？\n※ ログイン記憶は保持され、「ログイン記憶」からいつでも呼び出せます。\n※ 特定のアカウントだけ消す場合はヘッダーのアカウントタブから ✕ を押してください。`
          : `「${group.displayName}」を一覧から削除しますか？\n※ ログイン記憶は保持され、「ログイン記憶」からいつでも呼び出せます。`;
      const ok = await openConfirmDialog({
        title: 'サービスを削除',
        message: msg,
        confirmLabel: '削除する',
        danger: true,
        anchorEl: delBtn,
        anchorPoint: { x: e.clientX, y: e.clientY }
      });
      if (!ok) return;
      if (group.accounts.length === 1) {
        await omniApi.removeTab(group.accounts[0].instanceId);
      } else {
        await omniApi.removeTabs(group.accounts.map((a) => a.instanceId));
      }
      showToast(`「${group.displayName}」を削除しました（ログイン記憶は保持）`);
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

function renderAccountBar(): void {
  const avatarEl = el<HTMLSpanElement>('accountbar-avatar');
  const serviceNameEl = el<HTMLSpanElement>('accountbar-service-name');
  const stripEl = el<HTMLDivElement>('account-strip');
  const addBtn = el<HTMLButtonElement>('btn-add-account');

  const active = getActiveInstance();
  const group = getActiveGroup();

  stripEl.innerHTML = '';
  if (!active || !group) {
    avatarEl.style.background = 'var(--accent)';
    avatarEl.textContent = 'O';
    serviceNameEl.textContent = 'サービス未選択';
    addBtn.disabled = true;
    return;
  }

  addBtn.disabled = false;
  addBtn.title = `「${group.displayName}」に独立セッションの別アカウントを追加`;

  const activeRt = state.runtimeMap.get(active.instanceId);
  avatarEl.innerHTML = '';
  avatarEl.style.background = active.color;
  if (activeRt?.faviconUrl) {
    const img = document.createElement('img');
    img.src = activeRt.faviconUrl;
    img.alt = '';
    img.onerror = () => {
      avatarEl.textContent = active.badge;
    };
    avatarEl.appendChild(img);
  } else {
    avatarEl.textContent = active.badge;
  }
  serviceNameEl.textContent = group.displayName;

  group.accounts.forEach((inst, idx) => {
    const rt = state.runtimeMap.get(inst.instanceId);
    const isCurrent = inst.instanceId === active.instanceId;
    const label = getAccountDisplayLabel(inst, idx, group.displayName);

    const pill = document.createElement('div');
    pill.className = 'account-pill';
    pill.setAttribute('role', 'tab');
    pill.setAttribute('aria-selected', String(isCurrent));
    if (isCurrent) pill.classList.add('active');
    pill.draggable = group.accounts.length >= 2;
    pill.title = `${group.displayName} · ${label}\nクリックで瞬時切替 / ダブルクリックで名前変更${
      idx < 9 ? ` (Ctrl+Alt+${idx + 1})` : ''
    }`;

    pill.addEventListener('click', () => {
      if (!isCurrent || rt?.isSleeping || state.gmailOpen) {
        void omniApi.activateTab(inst.instanceId);
      }
    });
    pill.addEventListener('dblclick', (e) => {
      e.stopPropagation();
      void openEditModalForExisting(inst, true);
    });

    // Drag reorder accounts within the same SNS
    if (group.accounts.length >= 2) {
      pill.addEventListener('dragstart', (e) => {
        dragSourceAccountId = inst.instanceId;
        pill.classList.add('dragging');
        e.dataTransfer?.setData('text/plain', inst.instanceId);
      });
      pill.addEventListener('dragend', () => {
        dragSourceAccountId = null;
        pill.classList.remove('dragging');
        stripEl.querySelectorAll('.drag-over').forEach((n) => n.classList.remove('drag-over'));
      });
      pill.addEventListener('dragover', (e) => {
        if (!dragSourceAccountId || dragSourceAccountId === inst.instanceId) return;
        e.preventDefault();
        pill.classList.add('drag-over');
      });
      pill.addEventListener('dragleave', () => {
        pill.classList.remove('drag-over');
      });
      pill.addEventListener('drop', async (e) => {
        e.preventDefault();
        pill.classList.remove('drag-over');
        if (!dragSourceAccountId || dragSourceAccountId === inst.instanceId) return;
        const allGroups = getServiceGroups();
        const targetGroup = allGroups.find((g) => g.key === group.key);
        if (!targetGroup) return;
        const fromIdx = targetGroup.accounts.findIndex((a) => a.instanceId === dragSourceAccountId);
        const toIdx = targetGroup.accounts.findIndex((a) => a.instanceId === inst.instanceId);
        if (fromIdx === -1 || toIdx === -1) return;
        const [moved] = targetGroup.accounts.splice(fromIdx, 1);
        targetGroup.accounts.splice(toIdx, 0, moved);
        const flattenedIds = allGroups.flatMap((g) => g.accounts.map((a) => a.instanceId));
        await omniApi.reorderTabs(flattenedIds);
      });
    }

    const dot = document.createElement('span');
    dot.className = `account-pill-dot ${
      rt?.isLoading ? 'loading' : rt?.isSleeping ? '' : 'ready'
    }`;

    const labelSpan = document.createElement('span');
    labelSpan.className = 'account-pill-label';
    labelSpan.textContent = label;

    pill.appendChild(dot);
    pill.appendChild(labelSpan);

    const subTabCount = rt?.tabs?.length ?? 0;
    if (subTabCount >= 2) {
      const tabBadge = document.createElement('span');
      tabBadge.className = 'account-pill-tabs';
      tabBadge.textContent = `${subTabCount}`;
      tabBadge.title = `このアカウントで ${subTabCount} 枚のタブを開いています`;
      pill.appendChild(tabBadge);
    }

    const unread = inst.notificationsEnabled ? rt?.unreadCount ?? 0 : 0;
    if (unread > 0) {
      const badge = document.createElement('span');
      badge.className = 'account-pill-unread';
      badge.textContent = unread > 99 ? '99+' : String(unread);
      pill.appendChild(badge);
    }

    const actions = document.createElement('span');
    actions.className = 'account-pill-actions';

    const editBtn = document.createElement('button');
    editBtn.type = 'button';
    editBtn.className = 'account-pill-btn';
    editBtn.title = 'アカウント名・設定を編集';
    editBtn.textContent = '✎';
    editBtn.addEventListener('click', (e) => {
      e.stopPropagation();
      void openEditModalForExisting(inst, true);
    });
    actions.appendChild(editBtn);

    if (group.accounts.length >= 2) {
      const delBtn = document.createElement('button');
      delBtn.type = 'button';
      delBtn.className = 'account-pill-btn danger';
      delBtn.title = `アカウント「${label}」を削除`;
      delBtn.textContent = '✕';
      delBtn.addEventListener('click', async (e) => {
        e.stopPropagation();
        const ok = await openConfirmDialog({
          title: 'アカウントを削除',
          message: `「${group.displayName} / ${label}」を削除しますか？\n※ ログイン記憶は保持され、「ログイン記憶」からいつでも呼び出せます。`,
          confirmLabel: '削除する',
          danger: true,
          anchorEl: delBtn,
          anchorPoint: { x: e.clientX, y: e.clientY }
        });
        if (!ok) return;
        await omniApi.removeTab(inst.instanceId);
        showToast(`「${group.displayName} / ${label}」を削除しました（ログイン記憶は保持）`);
      });
      actions.appendChild(delBtn);
    }

    pill.appendChild(actions);
    stripEl.appendChild(pill);
  });
}

let pendingNewAccountAction: (() => Promise<void>) | null = null;

function formatArchivedTimestamp(unixSecs: number): string {
  if (!unixSecs) return '';
  const d = new Date(unixSecs * 1000);
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, '0');
  const day = String(d.getDate()).padStart(2, '0');
  const hh = String(d.getHours()).padStart(2, '0');
  const mm = String(d.getMinutes()).padStart(2, '0');
  return `${y}/${m}/${day} ${hh}:${mm}`;
}

function getArchivedDisplayTitle(inst: ServiceInstance): string {
  const label = inst.accountLabel?.trim();
  const base = label && label !== inst.name ? `${inst.name} · ${label}` : inst.name;
  return inst.detectedHandle ? `${base} (@${inst.detectedHandle})` : base;
}

async function closeArchivedPickModal(): Promise<void> {
  pendingNewAccountAction = null;
  el('archived-pick-modal').classList.add('hidden');
  await syncOverlayToMain();
}

async function openArchivedPickModal(
  serviceName: string,
  candidates: ArchivedInstance[],
  onCreateNew: () => Promise<void>
): Promise<void> {
  pendingNewAccountAction = onCreateNew;
  el<HTMLHeadingElement>('archived-pick-title').textContent = `「${serviceName}」にアカウントを追加`;
  el<HTMLParagraphElement>('archived-pick-desc').textContent =
    `「${serviceName}」の保存済みログイン記憶が ${candidates.length} 件あります。ログイン済みのまま呼び出すか、新規アカウントを作成できます。`;

  const list = el<HTMLDivElement>('archived-pick-list');
  list.innerHTML = '';
  for (const entry of candidates) {
    const inst = entry.instance;
    const row = document.createElement('div');
    row.className = 'archived-pick-row';

    const info = document.createElement('div');
    info.className = 'archived-pick-row-info';

    const title = document.createElement('div');
    title.className = 'archived-pick-row-title';
    title.textContent = getArchivedDisplayTitle(inst);

    const sub = document.createElement('div');
    sub.className = 'archived-pick-row-sub';
    const timeStr = formatArchivedTimestamp(entry.archivedAt);
    sub.textContent = timeStr ? `保存: ${timeStr}` : inst.url;

    info.appendChild(title);
    info.appendChild(sub);

    const restoreBtn = document.createElement('button');
    restoreBtn.type = 'button';
    restoreBtn.className = 'btn-primary btn-xs';
    restoreBtn.textContent = '呼び出す';
    restoreBtn.addEventListener('click', async () => {
      try {
        await omniApi.restoreArchivedTab(inst.instanceId);
        await closeArchivedPickModal();
        showToast(`「${getArchivedDisplayTitle(inst)}」をログイン記憶から呼び出しました`);
      } catch (err) {
        showToast(String(err));
      }
    });

    row.appendChild(info);
    row.appendChild(restoreBtn);
    list.appendChild(row);
  }

  el('archived-pick-modal').classList.remove('hidden');
  await syncOverlayToMain();
}

async function createNewAccountForActiveService(): Promise<void> {
  const active = getActiveInstance();
  const group = getActiveGroup();
  if (!active || !group) return;

  const catalogSvc = active.serviceId !== 'custom' ? getCatalogService(active.serviceId) : undefined;
  const existingLabels = group.accounts.map((acc, idx) =>
    getAccountDisplayLabel(acc, idx, group.displayName)
  );
  const nextLabel = nextDefaultAccountLabel(existingLabels);

  if (catalogSvc?.requiresCustomUrl) {
    await openEditModalForTemplate(catalogSvc, group.accounts.length, nextLabel);
    return;
  }

  await omniApi.addTab({
    serviceId: active.serviceId,
    name: group.displayName,
    accountLabel: nextLabel,
    category: active.category,
    url: catalogSvc?.url ?? active.url,
    color: active.color,
    badge: active.badge,
    uaMode: active.uaMode
  });
  showToast(`「${group.displayName} / ${nextLabel}」を追加しました（独立セッション）`);
}

async function addAccountForActiveService(): Promise<void> {
  const active = getActiveInstance();
  const group = getActiveGroup();
  if (!active || !group) return;

  const archivedForGroup = (state.config?.archivedInstances ?? []).filter(
    (a) => getServiceGroupKey(a.instance) === group.key
  );
  if (archivedForGroup.length > 0) {
    await openArchivedPickModal(group.displayName, archivedForGroup, createNewAccountForActiveService);
    return;
  }

  await createNewAccountForActiveService();
}

const ICON_VOLUME_ON =
  '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5"/><path d="M15.54 8.46a5 5 0 0 1 0 7.07"/><path d="M19.07 4.93a10 10 0 0 1 0 14.14"/></svg>';
const ICON_VOLUME_OFF =
  '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5"/><line x1="23" y1="9" x2="17" y2="15"/><line x1="17" y1="9" x2="23" y2="15"/></svg>';

function getInstanceDisplayTitle(inst: ServiceInstance): string {
  const key = getServiceGroupKey(inst);
  const group = getServiceGroups().find((g) => g.key === key);
  if (!group) return inst.name;
  const idx = Math.max(
    0,
    group.accounts.findIndex((a) => a.instanceId === inst.instanceId)
  );
  const label = getAccountDisplayLabel(inst, idx, group.displayName);
  return `${group.displayName} · ${label}`;
}

function getActiveDisplayTitle(): string {
  const active = getActiveInstance();
  if (!active) return 'サービス未選択';
  return getInstanceDisplayTitle(active);
}

interface CounterTargetInfo {
  target: ServiceInstance | undefined;
  isCrossSite: boolean;
  effectiveService: string | null;
}

/**
 * Threads タブ内で Instagram を開いている場合など、現在表示中URLのSNSに合わせて
 * フォロー・アンフォローカウンターの表示／操作対象インスタンスを解決する。
 */
function getCounterTargetInfo(): CounterTargetInfo {
  const active = getActiveInstance();
  if (!active || !state.config) {
    return { target: undefined, isCrossSite: false, effectiveService: null };
  }
  const rt = state.runtimeMap.get(active.instanceId);
  const detectedService = detectPlatformServiceFromUrl(rt?.currentUrl);
  if (!detectedService || detectedService === active.serviceId) {
    return { target: active, isCrossSite: false, effectiveService: active.serviceId };
  }

  const candidates = state.config.instances.filter((i) => i.serviceId === detectedService);
  if (candidates.length === 0) {
    return { target: undefined, isCrossSite: true, effectiveService: detectedService };
  }

  // 1. 同一 @handle（Threads ↔ Instagram 連携アカウント）
  if (active.detectedHandle) {
    const byHandle = candidates.find((c) => c.detectedHandle === active.detectedHandle);
    if (byHandle) {
      return { target: byHandle, isCrossSite: true, effectiveService: detectedService };
    }
  }
  // 2. 対象サービスで直近アクティブだったアカウント
  const remembered = state.lastActiveByGroup.get(detectedService);
  if (remembered) {
    const byLast = candidates.find((c) => c.instanceId === remembered);
    if (byLast) {
      return { target: byLast, isCrossSite: true, effectiveService: detectedService };
    }
  }
  // 3. 同一アカウントラベル
  const activeLbl = active.accountLabel?.trim();
  if (activeLbl) {
    const byLbl = candidates.find((c) => c.accountLabel?.trim() === activeLbl);
    if (byLbl) {
      return { target: byLbl, isCrossSite: true, effectiveService: detectedService };
    }
  }
  return { target: candidates[0], isCrossSite: true, effectiveService: detectedService };
}

function renderToolbarAndViewport(): void {
  const active = getActiveInstance();
  const rt = active ? state.runtimeMap.get(active.instanceId) : undefined;

  const backBtn = el<HTMLButtonElement>('btn-back');
  const fwdBtn = el<HTMLButtonElement>('btn-forward');
  const dotEl = el<HTMLSpanElement>('active-service-dot');
  const nameEl = el<HTMLSpanElement>('active-service-name');
  const urlInput = el<HTMLInputElement>('active-url-input');
  const copyUrlBtn = el<HTMLButtonElement>('btn-copy-url');
  const uaBtn = el<HTMLButtonElement>('btn-toggle-ua');
  const muteBtn = el<HTMLButtonElement>('btn-toggle-mute');
  const zoomResetBtn = el<HTMLButtonElement>('btn-zoom-reset');

  const followBtn = el<HTMLButtonElement>('btn-follow-counter');
  const followLabelEl = el<HTMLElement>('follow-pill-label');
  const followTodayEl = el<HTMLElement>('follow-today-count');
  const unfollowSepEl = el<HTMLElement>('unfollow-pill-sep');
  const unfollowLabelEl = el<HTMLElement>('unfollow-pill-label');
  const unfollowTodayEl = el<HTMLElement>('unfollow-today-count');
  const collapsedNewTabBtn = el<HTMLButtonElement>('btn-collapsed-new-subtab');
  const collapsedFollowBtn = el<HTMLButtonElement>('btn-collapsed-follow');
  const collapsedFollowEl = el<HTMLSpanElement>('collapsed-follow-count');
  const collapsedReloadBtn = el<HTMLButtonElement>('btn-collapsed-reload');
  const gmailBtn = el<HTMLButtonElement>('btn-open-gmail');
  const gmailLabelEl = el<HTMLSpanElement>('open-gmail-label');
  const collapsedGmailBtn = el<HTMLButtonElement>('btn-collapsed-gmail');
  const collapsedGmailLabelEl = el<HTMLSpanElement>('collapsed-gmail-label');

  gmailBtn.classList.toggle('active', state.gmailOpen);
  collapsedGmailBtn.classList.toggle('active', state.gmailOpen);
  gmailLabelEl.textContent = state.gmailOpen ? 'Gmail ✕' : 'Gmail';
  collapsedGmailLabelEl.textContent = state.gmailOpen ? 'Gmail ✕' : 'Gmail';
  const gmailTip = state.gmailOpen
    ? 'Gmailを閉じて元のSNSへ戻る'
    : 'アプリ内で Gmail を開く（SNS認証メール確認用）';
  gmailBtn.title = gmailTip;
  collapsedGmailBtn.title = gmailTip;

  const emptyEl = el<HTMLDivElement>('empty-state');
  const sleepingEl = el<HTMLDivElement>('sleeping-state');
  const errorEl = el<HTMLDivElement>('error-state');

  emptyEl.classList.add('hidden');
  sleepingEl.classList.add('hidden');
  errorEl.classList.add('hidden');

  if (state.gmailOpen) {
    const grt = state.gmailRuntime;
    backBtn.disabled = !grt?.canGoBack;
    fwdBtn.disabled = !grt?.canGoForward;
    collapsedReloadBtn.disabled = false;
    copyUrlBtn.disabled = false;
    urlInput.disabled = false;
    dotEl.className = `status-dot ${grt?.isLoading ? 'loading' : 'ready'}`;
    nameEl.textContent = 'Gmail（アプリ内）';
    const gmailUrl = grt?.currentUrl || 'https://mail.google.com/';
    if (document.activeElement !== urlInput) {
      urlInput.value = gmailUrl;
    }
    if (grt?.loadError) {
      el<HTMLParagraphElement>('error-detail').textContent = grt.loadError;
      errorEl.classList.remove('hidden');
    }
    if (!active) {
      followBtn.disabled = true;
      collapsedNewTabBtn.disabled = true;
      collapsedFollowBtn.disabled = true;
      followTodayEl.textContent = '0';
      unfollowTodayEl.textContent = '0';
      unfollowSepEl.classList.add('hidden');
      unfollowLabelEl.classList.add('hidden');
      unfollowTodayEl.classList.add('hidden');
      collapsedFollowEl.textContent = '0';
      followBtn.classList.remove('has-count');
      collapsedFollowBtn.classList.remove('has-count');
      uaBtn.textContent = 'PC版';
      uaBtn.classList.remove('mobile-mode');
      muteBtn.innerHTML = ICON_VOLUME_ON;
      zoomResetBtn.textContent = '100%';
    }
    return;
  }

  if (!active) {
    backBtn.disabled = true;
    fwdBtn.disabled = true;
    followBtn.disabled = true;
    collapsedNewTabBtn.disabled = true;
    collapsedFollowBtn.disabled = true;
    collapsedReloadBtn.disabled = true;
    copyUrlBtn.disabled = true;
    urlInput.disabled = true;
    urlInput.value = '';
    followTodayEl.textContent = '0';
    unfollowTodayEl.textContent = '0';
    unfollowSepEl.classList.add('hidden');
    unfollowLabelEl.classList.add('hidden');
    unfollowTodayEl.classList.add('hidden');
    collapsedFollowEl.textContent = '0';
    followBtn.classList.remove('has-count');
    collapsedFollowBtn.classList.remove('has-count');
    dotEl.className = 'status-dot';
    nameEl.textContent = 'サービス未選択';
    uaBtn.textContent = 'PC版';
    uaBtn.classList.remove('mobile-mode');
    muteBtn.innerHTML = ICON_VOLUME_ON;
    zoomResetBtn.textContent = '100%';
    emptyEl.classList.remove('hidden');
    return;
  }

  const displayTitle = getActiveDisplayTitle();
  const counterInfo = getCounterTargetInfo();
  const counterInst = counterInfo.target;
  const todayFollow = counterInst?.followCountToday ?? 0;
  const todayUnfollow = counterInst?.unfollowCountToday ?? 0;
  followBtn.disabled = !counterInst;
  collapsedNewTabBtn.disabled = false;
  collapsedFollowBtn.disabled = !counterInst;
  collapsedReloadBtn.disabled = false;
  copyUrlBtn.disabled = false;
  urlInput.disabled = false;
  followLabelEl.textContent =
    counterInfo.isCrossSite && counterInst ? `${counterInst.badge} フォロー` : 'フォロー';
  followTodayEl.textContent = String(todayFollow);
  unfollowTodayEl.textContent = String(todayUnfollow);
  const showUnfollowPill = todayUnfollow > 0;
  unfollowSepEl.classList.toggle('hidden', !showUnfollowPill);
  unfollowLabelEl.classList.toggle('hidden', !showUnfollowPill);
  unfollowTodayEl.classList.toggle('hidden', !showUnfollowPill);
  const crossPrefix = counterInfo.isCrossSite && counterInst ? `${counterInst.badge} ` : '';
  collapsedFollowEl.textContent = showUnfollowPill
    ? `${crossPrefix}${todayFollow}/-${todayUnfollow}`
    : `${crossPrefix}${todayFollow}`;
  followBtn.classList.toggle('has-count', todayFollow > 0 || todayUnfollow > 0);
  collapsedFollowBtn.classList.toggle('has-count', todayFollow > 0 || todayUnfollow > 0);
  if (counterInst) {
    const liveParts: string[] = [];
    if (counterInfo.isCrossSite) {
      liveParts.push(`${getInstanceDisplayTitle(counterInst)} を表示中`);
    }
    if (counterInst.detectedHandle) liveParts.push(`@${counterInst.detectedHandle}`);
    if (typeof counterInst.snsFollowingCount === 'number') {
      liveParts.push(`SNS実フォロー中 ${counterInst.snsFollowingCount.toLocaleString()}人`);
    }
    if (typeof counterInst.snsFollowersCount === 'number') {
      liveParts.push(`フォロワー ${counterInst.snsFollowersCount.toLocaleString()}人`);
    }
    const baseTip = `フォロー: 今日 ${todayFollow} / 累計 ${counterInst.followCountTotal ?? 0} · アンフォロー: 今日 ${todayUnfollow} / 累計 ${counterInst.unfollowCountTotal ?? 0}`;
    const followTip = liveParts.length > 0 ? `${baseTip}\n${liveParts.join(' · ')}` : baseTip;
    followBtn.title = followTip;
    collapsedFollowBtn.title = followTip;
  } else if (counterInfo.isCrossSite && counterInfo.effectiveService) {
    const svcName =
      getCatalogService(counterInfo.effectiveService)?.name ?? counterInfo.effectiveService;
    const tip = `${svcName} を表示中（サービス一覧に ${svcName} を追加するとカウントできます）`;
    followBtn.title = tip;
    collapsedFollowBtn.title = tip;
  }
  if (!el('follow-modal').classList.contains('hidden')) {
    renderFollowModal();
  }
  backBtn.disabled = !rt?.canGoBack;
  fwdBtn.disabled = !rt?.canGoForward;
  dotEl.className = `status-dot ${rt?.isLoading ? 'loading' : rt?.isSleeping ? '' : 'ready'}`;
  nameEl.textContent = displayTitle;
  const resolvedUrl = rt?.currentUrl || active.url;
  if (document.activeElement !== urlInput) {
    urlInput.value = resolvedUrl;
  }

  const isMobile = active.uaMode === 'mobile';
  uaBtn.textContent = isMobile ? 'スマホ版' : 'PC版';
  uaBtn.classList.toggle('mobile-mode', isMobile);

  muteBtn.innerHTML = active.muted ? ICON_VOLUME_OFF : ICON_VOLUME_ON;
  zoomResetBtn.textContent = `${Math.round(active.zoomFactor * 100)}%`;

  if (rt?.isSleeping) {
    el<HTMLHeadingElement>('sleeping-title').textContent = `「${displayTitle}」は休止中です`;
    sleepingEl.classList.remove('hidden');
  } else if (rt?.loadError) {
    el<HTMLParagraphElement>('error-detail').textContent = rt.loadError;
    errorEl.classList.remove('hidden');
  }
}

function renderArchivedLoginsPanel(): void {
  const listEl = el<HTMLDivElement>('archived-logins-list');
  const purgeAllBtn = el<HTMLButtonElement>('btn-purge-all-archived');
  const allArchived = state.config?.archivedInstances ?? [];

  purgeAllBtn.classList.toggle('hidden', allArchived.length === 0);

  const q = state.catalogSearchQuery.trim().toLowerCase();
  const filtered = allArchived.filter((entry) => {
    if (!q) return true;
    const inst = entry.instance;
    return (
      inst.name.toLowerCase().includes(q) ||
      (inst.accountLabel ?? '').toLowerCase().includes(q) ||
      (inst.detectedHandle ?? '').toLowerCase().includes(q) ||
      inst.serviceId.toLowerCase().includes(q) ||
      inst.url.toLowerCase().includes(q)
    );
  });

  listEl.innerHTML = '';
  if (filtered.length === 0) {
    const empty = document.createElement('div');
    empty.className = 'archived-empty';
    empty.textContent =
      allArchived.length === 0
        ? '保存済みのログイン記憶はまだありません。\nサイドバーやヘッダーからタブ／アカウントを削除すると、ログイン状態が自動的にここへ保存されます。'
        : '検索条件に一致するログイン記憶が見つかりません。';
    listEl.appendChild(empty);
    return;
  }

  for (const entry of filtered) {
    const inst = entry.instance;
    const card = document.createElement('div');
    card.className = 'archived-card';

    const avatar = document.createElement('div');
    avatar.className = 'catalog-card-avatar';
    avatar.style.background = inst.color;
    avatar.textContent = inst.badge;

    const meta = document.createElement('div');
    meta.className = 'archived-card-meta';

    const title = document.createElement('div');
    title.className = 'archived-card-title';
    title.textContent = getArchivedDisplayTitle(inst);
    title.title = `${getArchivedDisplayTitle(inst)}\n${inst.url}`;

    const sub = document.createElement('div');
    sub.className = 'archived-card-sub';
    const timeStr = formatArchivedTimestamp(entry.archivedAt);
    sub.textContent = timeStr ? `保存: ${timeStr} · ${inst.url}` : inst.url;

    meta.appendChild(title);
    meta.appendChild(sub);

    const actions = document.createElement('div');
    actions.className = 'archived-card-actions';

    const restoreBtn = document.createElement('button');
    restoreBtn.type = 'button';
    restoreBtn.className = 'btn-primary btn-xs';
    restoreBtn.textContent = '呼び出す';
    restoreBtn.title = 'ログイン記憶を保ったまま一覧へ復元して開く';
    restoreBtn.addEventListener('click', async () => {
      try {
        await omniApi.restoreArchivedTab(inst.instanceId);
        await closeCatalogModal();
        showToast(`「${getArchivedDisplayTitle(inst)}」を呼び出しました`);
      } catch (err) {
        showToast(String(err));
      }
    });

    const purgeBtn = document.createElement('button');
    purgeBtn.type = 'button';
    purgeBtn.className = 'btn-secondary btn-xs danger-text';
    purgeBtn.textContent = '完全削除';
    purgeBtn.title = 'このログイン記憶（Cookie・プロファイル）を完全に消去';
    purgeBtn.addEventListener('click', async (e) => {
      const ok = await openConfirmDialog({
        title: 'ログイン記憶を完全削除',
        message: `「${getArchivedDisplayTitle(inst)}」のログイン記憶（Cookie・セッション）を完全に消去しますか？\n※ この操作は取り消せません。`,
        confirmLabel: '完全削除する',
        danger: true,
        anchorEl: purgeBtn,
        anchorPoint: { x: e.clientX, y: e.clientY }
      });
      if (!ok) return;
      await omniApi.purgeArchivedTab(inst.instanceId);
      showToast(`「${getArchivedDisplayTitle(inst)}」のログイン記憶を完全削除しました`);
    });

    actions.appendChild(restoreBtn);
    actions.appendChild(purgeBtn);
    card.appendChild(avatar);
    card.appendChild(meta);
    card.appendChild(actions);
    listEl.appendChild(card);
  }
}

function renderCatalog(): void {
  const catTabs = el<HTMLDivElement>('catalog-categories');
  const grid = el<HTMLDivElement>('catalog-grid');
  const archivedPanel = el<HTMLDivElement>('archived-logins-panel');
  const customForm = el<HTMLFormElement>('custom-service-form');
  const archivedList = state.config?.archivedInstances ?? [];

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

  // 保存済みログイン記憶タブ
  const archivedTab = document.createElement('button');
  archivedTab.type = 'button';
  archivedTab.className = `cat-tab archived-tab${archivedList.length > 0 ? ' has-items' : ''}${
    state.selectedCatalogCategory === 'archived' ? ' active' : ''
  }`;
  archivedTab.textContent = `ログイン記憶 (${archivedList.length})`;
  archivedTab.title = '削除したタブのログイン記憶を呼び出す・管理する';
  archivedTab.addEventListener('click', () => {
    state.selectedCatalogCategory = 'archived';
    renderCatalog();
  });
  catTabs.appendChild(archivedTab);

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

  if (state.selectedCatalogCategory === 'archived') {
    grid.classList.add('hidden');
    customForm.classList.add('hidden');
    archivedPanel.classList.remove('hidden');
    renderArchivedLoginsPanel();
    return;
  }

  if (state.selectedCatalogCategory === 'custom') {
    grid.classList.add('hidden');
    archivedPanel.classList.add('hidden');
    customForm.classList.remove('hidden');
    return;
  }

  grid.classList.remove('hidden');
  archivedPanel.classList.add('hidden');
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

  // Count how many times each service is already added / archived
  const addedCounts = new Map<string, number>();
  for (const inst of state.config?.instances ?? []) {
    addedCounts.set(inst.serviceId, (addedCounts.get(inst.serviceId) ?? 0) + 1);
  }
  const archivedByService = new Map<string, ArchivedInstance[]>();
  for (const entry of archivedList) {
    const arr = archivedByService.get(entry.instance.serviceId) ?? [];
    arr.push(entry);
    archivedByService.set(entry.instance.serviceId, arr);
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

  const ICON_CUSTOMIZE_SLIDERS =
    '<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><line x1="4" y1="21" x2="4" y2="14"/><line x1="4" y1="10" x2="4" y2="3"/><line x1="12" y1="21" x2="12" y2="12"/><line x1="12" y1="8" x2="12" y2="3"/><line x1="20" y1="21" x2="20" y2="16"/><line x1="20" y1="12" x2="20" y2="3"/><line x1="1" y1="14" x2="7" y2="14"/><line x1="9" y1="8" x2="15" y2="8"/><line x1="17" y1="16" x2="23" y2="16"/></svg>';

  for (const svc of filtered) {
    const count = addedCounts.get(svc.id) ?? 0;
    const svcArchived = archivedByService.get(svc.id) ?? [];
    const card = document.createElement('div');
    card.className = 'catalog-card';
    card.title = svc.note
      ? `${svc.name} (${svc.url})\n${svc.description}\n※ ${svc.note}`
      : `${svc.name} (${svc.url})\n${svc.description}`;

    const avatar = document.createElement('div');
    avatar.className = 'catalog-card-avatar';
    avatar.style.background = svc.color;
    avatar.textContent = svc.badge;

    const titleWrap = document.createElement('div');
    titleWrap.className = 'catalog-card-title-wrap';

    const title = document.createElement('div');
    title.className = 'catalog-card-title';

    const nameText = document.createElement('span');
    nameText.className = 'catalog-card-name';
    nameText.textContent = svc.name;
    title.appendChild(nameText);

    if (count > 0) {
      const chip = document.createElement('span');
      chip.className = 'added-chip';
      chip.textContent = count === 1 ? '済' : `${count}垢`;
      chip.title = count === 1 ? '追加済み' : `${count}個追加済み`;
      title.appendChild(chip);
    }

    if (svcArchived.length > 0) {
      const archChip = document.createElement('button');
      archChip.type = 'button';
      archChip.className = 'archived-chip';
      archChip.textContent = svcArchived.length === 1 ? '記憶あり' : `記憶${svcArchived.length}`;
      archChip.title = `削除済みのログイン記憶が ${svcArchived.length} 件あります（クリックで呼び出し）`;
      archChip.addEventListener('click', (e) => {
        e.stopPropagation();
        state.selectedCatalogCategory = 'archived';
        state.catalogSearchQuery = svc.name;
        el<HTMLInputElement>('catalog-search').value = svc.name;
        renderCatalog();
      });
      title.appendChild(archChip);
    }

    titleWrap.appendChild(title);

    const actions = document.createElement('div');
    actions.className = 'catalog-card-actions';

    const addBtn = document.createElement('button');
    addBtn.type = 'button';
    addBtn.className = 'btn-primary catalog-add-btn';
    addBtn.textContent = count > 0 ? '＋別垢' : '＋追加';
    addBtn.title = count > 0 ? `「${svc.name}」の別アカウントを追加して開く` : `「${svc.name}」を追加して開く`;
    addBtn.addEventListener('click', async () => {
      const doCreate = async () => {
        const existingForSvc = (state.config?.instances ?? []).filter((i) => i.serviceId === svc.id);
        const existingLabels = existingForSvc.map((acc, idx) =>
          getAccountDisplayLabel(acc, idx, svc.name)
        );
        const nextLabel = nextDefaultAccountLabel(existingLabels);
        if (svc.requiresCustomUrl) {
          await openEditModalForTemplate(svc, count, nextLabel);
          return;
        }
        await addServiceAndCloseCatalog({
          serviceId: svc.id,
          name: svc.name,
          accountLabel: nextLabel,
          category: svc.category,
          url: svc.url,
          color: svc.color,
          badge: svc.badge,
          uaMode: svc.defaultUa
        });
      };
      if (svcArchived.length > 0) {
        await closeCatalogModal();
        await openArchivedPickModal(svc.name, svcArchived, doCreate);
        return;
      }
      await doCreate();
    });

    const customizeBtn = document.createElement('button');
    customizeBtn.type = 'button';
    customizeBtn.className = 'btn-secondary catalog-custom-btn';
    customizeBtn.innerHTML = ICON_CUSTOMIZE_SLIDERS;
    customizeBtn.title = '詳細設定（アカウント名やURLを変更してから追加）';
    customizeBtn.setAttribute('aria-label', `${svc.name} の詳細設定`);
    customizeBtn.addEventListener('click', () => {
      const existingForSvc = (state.config?.instances ?? []).filter((i) => i.serviceId === svc.id);
      const existingLabels = existingForSvc.map((acc, idx) =>
        getAccountDisplayLabel(acc, idx, svc.name)
      );
      const nextLabel = nextDefaultAccountLabel(existingLabels);
      void openEditModalForTemplate(svc, count, nextLabel);
    });

    actions.appendChild(addBtn);
    actions.appendChild(customizeBtn);
    card.appendChild(avatar);
    card.appendChild(titleWrap);
    card.appendChild(actions);
    grid.appendChild(card);
  }
}

let isAddingService = false;

async function addServiceAndCloseCatalog(payload: AddInstancePayload): Promise<void> {
  if (isAddingService) return;
  isAddingService = true;
  try {
    await omniApi.addTab(payload);
    el('catalog-modal').classList.add('hidden');
    el('edit-modal').classList.add('hidden');
    await syncOverlayToMain();
    const labelSuffix = payload.accountLabel ? ` / ${payload.accountLabel}` : '';
    showToast(`「${payload.name}${labelSuffix}」を追加しました`);
  } finally {
    isAddingService = false;
  }
}

async function openCatalogModal(
  initialCategory?: ServiceCategory | 'all' | 'archived'
): Promise<void> {
  if (initialCategory) {
    state.selectedCatalogCategory = initialCategory;
    if (initialCategory === 'archived') {
      state.catalogSearchQuery = '';
      el<HTMLInputElement>('catalog-search').value = '';
    }
  }
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

async function openEditModalForTemplate(
  svc: CatalogService,
  existingCount: number,
  suggestedAccountLabel?: string
): Promise<void> {
  state.editingMode = 'create';
  state.editingInstanceId = null;
  state.editingTemplate = svc;

  el<HTMLHeadingElement>('edit-modal-title').textContent = `${svc.name} を詳細追加`;
  el<HTMLInputElement>('edit-account-label').value =
    suggestedAccountLabel ?? (existingCount > 0 ? `アカウント ${existingCount + 1}` : 'メイン');
  el<HTMLInputElement>('edit-name').value = svc.name;
  el<HTMLInputElement>('edit-url').value = svc.url;
  el<HTMLSelectElement>('edit-ua').value = svc.defaultUa;
  el<HTMLInputElement>('edit-color').value = svc.color;
  el<HTMLInputElement>('edit-notifications').checked = true;

  el('edit-modal').classList.remove('hidden');
  await syncOverlayToMain();
  const accInput = el<HTMLInputElement>('edit-account-label');
  accInput.focus();
  accInput.select();
}

async function openEditModalForExisting(
  inst: ServiceInstance,
  focusAccountLabel = true
): Promise<void> {
  state.editingMode = 'edit';
  state.editingInstanceId = inst.instanceId;
  state.editingTemplate = null;

  const group = getServiceGroups().find((g) => g.key === getServiceGroupKey(inst));
  const siblingIdx = group
    ? Math.max(
        0,
        group.accounts.findIndex((a) => a.instanceId === inst.instanceId)
      )
    : 0;
  const currentLabel = getAccountDisplayLabel(inst, siblingIdx, group?.displayName);

  el<HTMLHeadingElement>('edit-modal-title').textContent = `「${group?.displayName ?? inst.name} · ${currentLabel}」の設定`;
  el<HTMLInputElement>('edit-account-label').value = currentLabel;
  el<HTMLInputElement>('edit-name').value = inst.name;
  el<HTMLInputElement>('edit-url').value = inst.url;
  el<HTMLSelectElement>('edit-ua').value = inst.uaMode;
  el<HTMLInputElement>('edit-color').value = inst.color;
  el<HTMLInputElement>('edit-notifications').checked = inst.notificationsEnabled;

  el('edit-modal').classList.remove('hidden');
  await syncOverlayToMain();
  const focusEl = el<HTMLInputElement>(focusAccountLabel ? 'edit-account-label' : 'edit-name');
  focusEl.focus();
  focusEl.select();
}

async function closeEditModal(): Promise<void> {
  el('edit-modal').classList.add('hidden');
  state.editingMode = null;
  state.editingInstanceId = null;
  state.editingTemplate = null;
  await syncOverlayToMain();
}

async function openSettingsModal(): Promise<void> {
  if (!state.config) return;
  const s = state.config.settings;
  el<HTMLSelectElement>('setting-theme').value = s.theme;
  el<HTMLInputElement>('setting-minimize-tray').checked = s.minimizeToTray;
  el<HTMLInputElement>('setting-sidebar-width').value = String(s.sidebarWidth);
  el<HTMLSpanElement>('setting-sidebar-width-val').textContent = String(s.sidebarWidth);

  el('settings-modal').classList.remove('hidden');
  await syncOverlayToMain();
}

function formatSyncTime(unixSecs?: number): string {
  if (!unixSecs) return '';
  const d = new Date(unixSecs * 1000);
  const hh = String(d.getHours()).padStart(2, '0');
  const mm = String(d.getMinutes()).padStart(2, '0');
  return `${hh}:${mm}`;
}

function parseSharedSyncConfig(raw: string): { token: string; gistId: string } | null {
  const trimmed = raw.trim();
  if (!trimmed) return null;
  const jsonPart = trimmed.startsWith('OMNISNS_SYNC_V1:')
    ? trimmed.slice('OMNISNS_SYNC_V1:'.length).trim()
    : trimmed;
  if (!jsonPart.startsWith('{')) return null;
  try {
    const parsed = JSON.parse(jsonPart) as { token?: unknown; gistId?: unknown };
    const token = typeof parsed.token === 'string' ? parsed.token.trim() : '';
    const gistId = typeof parsed.gistId === 'string' ? parsed.gistId.trim() : '';
    if (!token && !gistId) return null;
    return { token, gistId };
  } catch {
    return null;
  }
}

function renderFollowModal(): void {
  const counterInfo = getCounterTargetInfo();
  const active = counterInfo.target;
  if (!active || !state.config) return;
  const todayCount = active.followCountToday ?? 0;
  const totalCount = active.followCountTotal ?? 0;
  const unfollowTodayCount = active.unfollowCountToday ?? 0;
  const unfollowTotalCount = active.unfollowCountTotal ?? 0;

  const baseTitle = getInstanceDisplayTitle(active);
  const withHandle = active.detectedHandle
    ? `${baseTitle} (@${active.detectedHandle})`
    : baseTitle;
  const accountSubtitle = counterInfo.isCrossSite
    ? `${withHandle}（${getActiveDisplayTitle()}タブ内で表示中）`
    : withHandle;
  el<HTMLParagraphElement>('follow-modal-account').textContent = accountSubtitle;
  el<HTMLElement>('follow-modal-today').textContent = String(todayCount);
  el<HTMLElement>('follow-modal-total').textContent = String(totalCount);
  el<HTMLButtonElement>('btn-follow-dec').disabled = todayCount <= 0 && totalCount <= 0;
  el<HTMLButtonElement>('btn-follow-reset-today').disabled = todayCount <= 0;
  el<HTMLButtonElement>('btn-follow-reset-all').disabled = todayCount <= 0 && totalCount <= 0;

  el<HTMLElement>('unfollow-modal-today').textContent = String(unfollowTodayCount);
  el<HTMLElement>('unfollow-modal-total').textContent = String(unfollowTotalCount);
  el<HTMLButtonElement>('btn-unfollow-dec').disabled =
    unfollowTodayCount <= 0 && unfollowTotalCount <= 0;
  el<HTMLButtonElement>('btn-unfollow-reset-today').disabled = unfollowTodayCount <= 0;
  el<HTMLButtonElement>('btn-unfollow-reset-all').disabled =
    unfollowTodayCount <= 0 && unfollowTotalCount <= 0;

  // SNS サーバー側の実フォロー中／フォロワー数
  const snsLiveBar = el<HTMLDivElement>('follow-sns-live-bar');
  const snsLiveText = el<HTMLSpanElement>('follow-sns-live-text');
  const hasFlwng = typeof active.snsFollowingCount === 'number';
  const hasFlwrs = typeof active.snsFollowersCount === 'number';
  if (hasFlwng || hasFlwrs) {
    const parts: string[] = [];
    if (hasFlwng) parts.push(`フォロー中 ${active.snsFollowingCount!.toLocaleString()} 人`);
    if (hasFlwrs) parts.push(`フォロワー ${active.snsFollowersCount!.toLocaleString()} 人`);
    snsLiveText.textContent = parts.join(' · ');
    snsLiveBar.classList.remove('hidden');
  } else {
    snsLiveBar.classList.add('hidden');
  }

  // 同期用ハンドル入力（入力中は上書きしない）
  const handleInput = el<HTMLInputElement>('follow-handle-input');
  if (document.activeElement !== handleInput) {
    handleInput.value = active.detectedHandle ?? '';
  }

  // PC・スマホ同期設定
  const fs = state.config.settings.followSync;
  if (fs) {
    const tokenInput = el<HTMLInputElement>('follow-sync-token');
    const gistInput = el<HTMLInputElement>('follow-sync-gist');
    const badge = el<HTMLSpanElement>('follow-sync-badge');
    const statusEl = el<HTMLDivElement>('follow-sync-status');

    if (document.activeElement !== tokenInput) {
      tokenInput.value = fs.githubToken ?? '';
    }
    if (document.activeElement !== gistInput) {
      gistInput.value = fs.gistId ?? '';
    }

    const hasCloud = Boolean(fs.githubToken?.trim());
    badge.textContent = hasCloud ? 'クラウド同期' : '未設定';

    const timeStr = formatSyncTime(fs.lastSyncAt);
    if (fs.lastSyncStatus) {
      statusEl.textContent = timeStr
        ? `${fs.lastSyncStatus}（最終: ${timeStr}）`
        : fs.lastSyncStatus;
    } else if (hasCloud) {
      statusEl.textContent = 'GitHub 非公開 Gist で PC・スマホ間を自動同期します';
    } else {
      statusEl.textContent = 'GitHub Token を設定すると PC・スマホ間で自動同期されます';
    }
  }

  const summaryBox = el<HTMLDivElement>('follow-summary-box');
  const summaryList = el<HTMLDivElement>('follow-summary-list');
  const instances = state.config.instances;
  if (instances.length >= 2) {
    let allToday = 0;
    let allUnfollowToday = 0;
    summaryList.innerHTML = '';
    const groups = getServiceGroups();
    for (const grp of groups) {
      grp.accounts.forEach((inst, idx) => {
        const c = inst.followCountToday ?? 0;
        const u = inst.unfollowCountToday ?? 0;
        allToday += c;
        allUnfollowToday += u;
        if (c > 0 || u > 0 || inst.instanceId === active.instanceId) {
          const row = document.createElement('div');
          row.className = 'follow-summary-row';
          const lbl = getAccountDisplayLabel(inst, idx, grp.displayName);
          const nameSpan = document.createElement('span');
          nameSpan.textContent = inst.detectedHandle
            ? `${grp.displayName} · ${lbl} (@${inst.detectedHandle})`
            : `${grp.displayName} · ${lbl}`;
          const cntSpan = document.createElement('strong');
          cntSpan.textContent = u > 0 ? `+${c} / -${u} 回` : `${c} 回`;
          row.appendChild(nameSpan);
          row.appendChild(cntSpan);
          summaryList.appendChild(row);
        }
      });
    }
    el<HTMLElement>('follow-all-today').textContent =
      allUnfollowToday > 0 ? `フォロー ${allToday} / 解除 ${allUnfollowToday} 回` : `${allToday} 回`;
    summaryBox.classList.remove('hidden');
  } else {
    summaryBox.classList.add('hidden');
  }
}

async function openFollowModal(): Promise<void> {
  if (!getCounterTargetInfo().target) return;
  renderFollowModal();
  el('follow-modal').classList.remove('hidden');
  await syncOverlayToMain();
}

async function closeFollowModal(): Promise<void> {
  el('follow-modal').classList.add('hidden');
  await syncOverlayToMain();
}

async function toggleHeaderCollapsed(): Promise<void> {
  if (!state.config) return;
  const next = !Boolean(state.config.settings.headerCollapsed);
  await omniApi.updateSettings({ headerCollapsed: next });
}

async function focusAddressBar(): Promise<void> {
  if (!state.config || !getActiveInstance()) return;
  if (state.config.settings.headerCollapsed) {
    await omniApi.updateSettings({ headerCollapsed: false });
  }
  const urlInput = el<HTMLInputElement>('active-url-input');
  urlInput.focus();
  urlInput.select();
}

async function closeSettingsModal(): Promise<void> {
  el('settings-modal').classList.add('hidden');
  await syncOverlayToMain();
}

async function openGestureModal(): Promise<void> {
  if (!state.config || !gestureModal) return;
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
  el<HTMLDivElement>('main-area').classList.toggle('has-multi-tabs', tabs.length >= 2);

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
      if (!isCurrent || tab.isSleeping || state.gmailOpen) {
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
  recordLastActiveForCurrent();
  applyThemeAndLayout();
  renderSidebar();
  renderAccountBar();
  renderToolbarAndViewport();
  renderTabBar();
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

  el<HTMLButtonElement>('btn-open-catalog').addEventListener('click', () => void openCatalogModal('all'));
  el<HTMLButtonElement>('btn-empty-add').addEventListener('click', () => void openCatalogModal('all'));
  el<HTMLButtonElement>('btn-open-archived').addEventListener('click', () =>
    void openCatalogModal('archived')
  );
  el<HTMLButtonElement>('btn-open-settings').addEventListener('click', () => void openSettingsModal());

  // Archived logins modals & purge-all
  el<HTMLButtonElement>('btn-purge-all-archived').addEventListener('click', async (e) => {
    const count = state.config?.archivedInstances?.length ?? 0;
    if (count === 0) return;
    const btn = e.currentTarget as HTMLElement | null;
    const ok = await openConfirmDialog({
      title: 'ログイン記憶をすべて完全削除',
      message: `保存されている ${count} 件のログイン記憶（Cookie・プロファイル）をすべて完全削除しますか？\n※ この操作は取り消せません。`,
      confirmLabel: 'すべて完全削除',
      danger: true,
      anchorEl: btn,
      anchorPoint: { x: e.clientX, y: e.clientY }
    });
    if (!ok) return;
    const removed = await omniApi.purgeAllArchivedTabs();
    showToast(`ログイン記憶 ${removed} 件を完全削除しました`);
  });

  el<HTMLButtonElement>('btn-close-archived-pick').addEventListener('click', () =>
    void closeArchivedPickModal()
  );
  el<HTMLButtonElement>('btn-archived-pick-cancel').addEventListener('click', () =>
    void closeArchivedPickModal()
  );
  el<HTMLDivElement>('archived-pick-modal').addEventListener('click', (e) => {
    if (e.target === el('archived-pick-modal')) {
      void closeArchivedPickModal();
    }
  });
  el<HTMLButtonElement>('btn-archived-pick-new').addEventListener('click', async () => {
    const action = pendingNewAccountAction;
    await closeArchivedPickModal();
    if (action) {
      await action();
    }
  });

  // Header account switcher add button
  el<HTMLButtonElement>('btn-add-account').addEventListener('click', () => {
    void addAccountForActiveService();
  });

  // Toolbar actions
  const runActiveAction = async (action: string) => {
    if (
      state.gmailOpen &&
      (action === 'back' ||
        action === 'forward' ||
        action === 'reload' ||
        action === 'hard-reload' ||
        action === 'home' ||
        action === 'open-external' ||
        action === 'devtools')
    ) {
      await omniApi.gmailAction(action);
      return;
    }
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
    const title = getActiveDisplayTitle();
    await omniApi.tabAction(active.instanceId, 'sleep');
    showToast(`「${title}」を休止しました（メモリ解放）`);
  });
  el<HTMLButtonElement>('btn-clear-session').addEventListener('click', async (e) => {
    const active = getActiveInstance();
    if (!active) return;
    const title = getActiveDisplayTitle();
    const clearBtn = e.currentTarget as HTMLElement | null;
    const ok = await openConfirmDialog({
      title: 'ログイン情報を初期化',
      message: `「${title}」のCookie・ログイン情報・キャッシュをすべて削除しますか？\n（他のアカウント・サービスには影響しません）`,
      confirmLabel: '初期化する',
      danger: true,
      anchorEl: clearBtn,
      anchorPoint: { x: e.clientX, y: e.clientY }
    });
    if (!ok) return;
    await omniApi.tabAction(active.instanceId, 'clear-session');
    showToast(`「${title}」のセッションを初期化しました`);
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

  el<HTMLButtonElement>('btn-hisator-ad').addEventListener('click', () => {
    void omniApi.openExternalUrl('https://hisator-notebook.com/');
  });

  const toggleGmail = () => {
    void omniApi.toggleGmail();
  };
  el<HTMLButtonElement>('btn-open-gmail').addEventListener('click', toggleGmail);
  el<HTMLButtonElement>('btn-collapsed-gmail').addEventListener('click', toggleGmail);

  el<HTMLButtonElement>('btn-copy-url').addEventListener('click', async () => {
    const urlText = state.gmailOpen
      ? state.gmailRuntime?.currentUrl ||
        el<HTMLInputElement>('active-url-input').value.trim() ||
        'https://mail.google.com/'
      : (() => {
          const active = getActiveInstance();
          const rt = active ? state.runtimeMap.get(active.instanceId) : undefined;
          return rt?.currentUrl || active?.url || el<HTMLInputElement>('active-url-input').value.trim();
        })();
    if (!urlText) return;
    await omniApi.copyText(urlText);
    showToast('URLをクリップボードにコピーしました');
  });

  const urlInput = el<HTMLInputElement>('active-url-input');
  urlInput.addEventListener('focus', () => {
    urlInput.select();
  });
  urlInput.addEventListener('keydown', async (e) => {
    if (e.key === 'Escape') {
      e.preventDefault();
      e.stopPropagation();
      if (state.gmailOpen) {
        urlInput.value = state.gmailRuntime?.currentUrl || 'https://mail.google.com/';
      } else {
        const active = getActiveInstance();
        const rt = active ? state.runtimeMap.get(active.instanceId) : undefined;
        urlInput.value = rt?.currentUrl || active?.url || '';
      }
      urlInput.blur();
      return;
    }
    if (e.key === 'Enter') {
      e.preventDefault();
      const normalized = normalizeServiceUrl(urlInput.value);
      if (!normalized) {
        showToast('有効な http:// または https:// URL を入力してください');
        return;
      }
      if (state.gmailOpen) {
        try {
          await omniApi.navigateGmail(normalized);
          urlInput.blur();
        } catch (err) {
          showToast(String(err));
        }
        return;
      }
      const active = getActiveInstance();
      if (!active) return;
      const openInNewTab = e.altKey || e.ctrlKey || e.metaKey;
      try {
        if (openInNewTab) {
          await omniApi.createSubTab(active.instanceId, normalized);
          showToast('同じアカウントの新しいタブで開きました');
        } else {
          await omniApi.navigateSubTab(active.instanceId, normalized);
        }
        urlInput.blur();
      } catch (err) {
        showToast(String(err));
      }
    }
  });

  // Placeholder buttons
  el<HTMLButtonElement>('btn-wake-tab').addEventListener('click', () => void runActiveAction('wake'));
  el<HTMLButtonElement>('btn-error-reload').addEventListener('click', () => void runActiveAction('reload'));
  el<HTMLButtonElement>('btn-error-external').addEventListener('click', () => void runActiveAction('open-external'));

  // Catalog modal
  el<HTMLButtonElement>('btn-close-catalog').addEventListener('click', () => void closeCatalogModal());
  el<HTMLDivElement>('catalog-modal').addEventListener('click', (e) => {
    if (e.target === el('catalog-modal')) {
      void closeCatalogModal();
    }
  });
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
      accountLabel: 'メイン',
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
    const accountLabel = el<HTMLInputElement>('edit-account-label').value.trim();
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
        accountLabel: accountLabel || 'メイン',
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
        accountLabel,
        url: normalized,
        color,
        notificationsEnabled
      });
      if (existing && existing.uaMode !== uaMode) {
        await omniApi.tabAction(targetId, 'toggle-ua');
      }
      await closeEditModal();
      showToast('アカウント・サービス設定を保存しました');
    }
  });

  // Follow counter & collapsible header
  el<HTMLButtonElement>('btn-toggle-header').addEventListener('click', () => void toggleHeaderCollapsed());
  el<HTMLButtonElement>('btn-collapsed-new-subtab').addEventListener('click', async () => {
    const active = getActiveInstance();
    if (!active) return;
    try {
      await omniApi.createSubTab(active.instanceId);
    } catch (err) {
      showToast(String(err));
    }
  });
  el<HTMLButtonElement>('btn-collapsed-reload').addEventListener('click', (e) =>
    void runActiveAction(e.shiftKey ? 'hard-reload' : 'reload')
  );
  el<HTMLButtonElement>('btn-follow-counter').addEventListener('click', () => void openFollowModal());
  el<HTMLButtonElement>('btn-collapsed-follow').addEventListener('click', () => void openFollowModal());
  el<HTMLButtonElement>('btn-close-follow').addEventListener('click', () => void closeFollowModal());
  el<HTMLDivElement>('follow-modal').addEventListener('click', (e) => {
    if (e.target === el('follow-modal')) {
      void closeFollowModal();
    }
  });
  el<HTMLButtonElement>('btn-follow-inc').addEventListener('click', async () => {
    const target = getCounterTargetInfo().target;
    if (!target) return;
    await omniApi.adjustFollowCount(target.instanceId, 1);
  });
  el<HTMLButtonElement>('btn-follow-dec').addEventListener('click', async () => {
    const target = getCounterTargetInfo().target;
    if (!target) return;
    await omniApi.adjustFollowCount(target.instanceId, -1);
  });
  el<HTMLButtonElement>('btn-follow-reset-today').addEventListener('click', async () => {
    const target = getCounterTargetInfo().target;
    if (!target) return;
    await omniApi.resetFollowCount(target.instanceId, false);
    showToast('今日のフォロー回数をリセットしました');
  });
  el<HTMLButtonElement>('btn-follow-reset-all').addEventListener('click', async () => {
    const target = getCounterTargetInfo().target;
    if (!target) return;
    await omniApi.resetFollowCount(target.instanceId, true);
    showToast('フォロー回数をすべてリセットしました');
  });
  el<HTMLButtonElement>('btn-unfollow-inc').addEventListener('click', async () => {
    const target = getCounterTargetInfo().target;
    if (!target) return;
    await omniApi.adjustUnfollowCount(target.instanceId, 1);
  });
  el<HTMLButtonElement>('btn-unfollow-dec').addEventListener('click', async () => {
    const target = getCounterTargetInfo().target;
    if (!target) return;
    await omniApi.adjustUnfollowCount(target.instanceId, -1);
  });
  el<HTMLButtonElement>('btn-unfollow-reset-today').addEventListener('click', async () => {
    const target = getCounterTargetInfo().target;
    if (!target) return;
    await omniApi.resetUnfollowCount(target.instanceId, false);
    showToast('今日のアンフォロー回数をリセットしました');
  });
  el<HTMLButtonElement>('btn-unfollow-reset-all').addEventListener('click', async () => {
    const target = getCounterTargetInfo().target;
    if (!target) return;
    await omniApi.resetUnfollowCount(target.instanceId, true);
    showToast('アンフォロー回数をすべてリセットしました');
  });

  const saveFollowHandle = async () => {
    const target = getCounterTargetInfo().target;
    if (!target) return;
    const raw = el<HTMLInputElement>('follow-handle-input').value.trim();
    try {
      const updated = await omniApi.setFollowHandle(target.instanceId, raw);
      showToast(
        updated.detectedHandle
          ? `同期アカウントを @${updated.detectedHandle} に設定しました`
          : '同期アカウントIDをクリアしました'
      );
    } catch (err) {
      showToast(String(err));
    }
  };
  el<HTMLButtonElement>('btn-follow-save-handle').addEventListener('click', () => void saveFollowHandle());
  el<HTMLInputElement>('follow-handle-input').addEventListener('keydown', (e) => {
    if (e.key === 'Enter') {
      e.preventDefault();
      void saveFollowHandle();
    }
  });

  el<HTMLButtonElement>('btn-follow-open-github-token').addEventListener('click', () => {
    void omniApi.openExternalUrl(
      'https://github.com/settings/tokens/new?scopes=gist&description=OmniSNS%20Follow%20Sync'
    );
  });

  el<HTMLInputElement>('follow-sync-token').addEventListener('input', (e) => {
    const inp = e.target as HTMLInputElement;
    const parsed = parseSharedSyncConfig(inp.value);
    if (parsed) {
      inp.value = parsed.token;
      el<HTMLInputElement>('follow-sync-gist').value = parsed.gistId;
      showToast('コピーした同期設定を自動入力しました');
    }
  });

  el<HTMLButtonElement>('btn-follow-sync-now').addEventListener('click', async () => {
    const btn = el<HTMLButtonElement>('btn-follow-sync-now');
    const githubToken = el<HTMLInputElement>('follow-sync-token').value.trim();
    const gistId = el<HTMLInputElement>('follow-sync-gist').value.trim();
    btn.disabled = true;
    btn.textContent = '同期中...';
    try {
      await omniApi.updateFollowSyncSettings({ githubToken, gistId });
      const res = await omniApi.syncFollowNow();
      showToast(res.lastSyncStatus || '同期が完了しました');
    } catch (err) {
      showToast(String(err));
    } finally {
      btn.disabled = false;
      btn.textContent = '保存して今すぐ同期';
    }
  });

  el<HTMLButtonElement>('btn-follow-sync-copy').addEventListener('click', async () => {
    const token = el<HTMLInputElement>('follow-sync-token').value.trim();
    const gistId = el<HTMLInputElement>('follow-sync-gist').value.trim();
    if (!token) {
      showToast('先に GitHub Token を入力・同期してからコピーしてください');
      return;
    }
    const payload = `OMNISNS_SYNC_V1:${JSON.stringify({ token, gistId })}`;
    await omniApi.copyText(payload);
    showToast('同期設定をコピーしました（スマホ側の「貼付して適用」で反映できます）');
  });

  el<HTMLButtonElement>('btn-follow-sync-paste').addEventListener('click', async () => {
    try {
      const clip = await navigator.clipboard.readText();
      const parsed = parseSharedSyncConfig(clip);
      if (!parsed) {
        showToast('クリップボードに有効な同期設定がありません');
        return;
      }
      el<HTMLInputElement>('follow-sync-token').value = parsed.token;
      el<HTMLInputElement>('follow-sync-gist').value = parsed.gistId;
      await omniApi.updateFollowSyncSettings({
        githubToken: parsed.token,
        gistId: parsed.gistId
      });
      const res = await omniApi.syncFollowNow();
      showToast(res.lastSyncStatus || '同期設定を適用しました');
    } catch (err) {
      showToast(`貼付に失敗しました: ${String(err)}`);
    }
  });

  // Confirm modal
  el<HTMLButtonElement>('btn-confirm-ok').addEventListener('click', () => void resolveConfirmDialog(true));
  el<HTMLButtonElement>('btn-confirm-cancel').addEventListener('click', () => void resolveConfirmDialog(false));
  el<HTMLButtonElement>('btn-close-confirm').addEventListener('click', () => void resolveConfirmDialog(false));
  el<HTMLDivElement>('confirm-modal').addEventListener('click', (e) => {
    if (e.target === el('confirm-modal')) {
      void resolveConfirmDialog(false);
    }
  });

  // Settings modal
  el<HTMLButtonElement>('btn-close-settings').addEventListener('click', () => void closeSettingsModal());
  el<HTMLDivElement>('settings-modal').addEventListener('click', (e) => {
    if (e.target === el('settings-modal')) {
      void closeSettingsModal();
    }
  });
  el<HTMLDivElement>('gesture-modal').addEventListener('click', (e) => {
    if (e.target === el('gesture-modal')) {
      void closeGestureModal();
    }
  });
  el<HTMLInputElement>('setting-sidebar-width').addEventListener('input', (e) => {
    const val = (e.target as HTMLInputElement).value;
    el<HTMLSpanElement>('setting-sidebar-width-val').textContent = val;
  });
  el<HTMLButtonElement>('btn-save-settings').addEventListener('click', async () => {
    await omniApi.updateSettings({
      theme: el<HTMLSelectElement>('setting-theme').value as 'dark' | 'light',
      minimizeToTray: el<HTMLInputElement>('setting-minimize-tray').checked,
      sidebarWidth: Number(el<HTMLInputElement>('setting-sidebar-width').value)
    });
    await closeSettingsModal();
    showToast('アプリ設定を保存しました');
  });

  // Global keyboard shortcuts inside shell UI
  window.addEventListener('keydown', (e) => {
    if (gestureModal?.handleKeyDown(e)) {
      return;
    }

    if (e.key === 'Escape') {
      if (!el('confirm-modal').classList.contains('hidden')) {
        void resolveConfirmDialog(false);
      } else if (!el('archived-pick-modal').classList.contains('hidden')) {
        void closeArchivedPickModal();
      } else if (!el('follow-modal').classList.contains('hidden')) {
        void closeFollowModal();
      } else if (!el('edit-modal').classList.contains('hidden')) {
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

    // モーダル表示中は Ctrl+K（カタログ開閉）以外のグローバルショートカットを抑止
    if (isAnyModalOpen()) {
      if (!e.shiftKey && !e.altKey && key === 'k' && !el('catalog-modal').classList.contains('hidden')) {
        e.preventDefault();
        void closeCatalogModal();
      }
      return;
    }

    // Ctrl + Alt + 1..9 -> 同一SNS内のアカウント切替
    if (!e.shiftKey && e.altKey && /^[1-9]$/.test(key)) {
      e.preventDefault();
      const idx = Number(key) - 1;
      const group = getActiveGroup();
      const target = group?.accounts[idx];
      if (target) {
        void omniApi.activateTab(target.instanceId);
      }
      return;
    }

    // Ctrl + Alt + ArrowLeft / ArrowRight -> 同一SNS内の前/次アカウント切替
    if (!e.shiftKey && e.altKey && (e.key === 'ArrowLeft' || e.key === 'ArrowRight')) {
      e.preventDefault();
      const active = getActiveInstance();
      const group = getActiveGroup();
      if (active && group && group.accounts.length >= 2) {
        const curIdx = group.accounts.findIndex((a) => a.instanceId === active.instanceId);
        const delta = e.key === 'ArrowLeft' ? -1 : 1;
        const nextIdx = (curIdx + delta + group.accounts.length) % group.accounts.length;
        void omniApi.activateTab(group.accounts[nextIdx].instanceId);
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

    if (!e.shiftKey && !e.altKey && key === 'l') {
      e.preventDefault();
      void focusAddressBar();
      return;
    }

    const activeEl = document.activeElement;
    const isTypingInput =
      activeEl instanceof HTMLInputElement ||
      activeEl instanceof HTMLTextAreaElement ||
      activeEl instanceof HTMLSelectElement;

    if (!isTypingInput && !e.altKey) {
      if (e.code === 'Minus' || e.code === 'NumpadSubtract' || key === '-' || key === '_') {
        e.preventDefault();
        void runActiveAction('zoom-out');
        return;
      }
      if (key === '+' || key === '=' || key === ';' || e.code === 'Equal' || e.code === 'NumpadAdd') {
        e.preventDefault();
        void runActiveAction('zoom-in');
        return;
      }
      if (!e.shiftKey && (key === '0' || e.code === 'Digit0' || e.code === 'Numpad0')) {
        e.preventDefault();
        void runActiveAction('zoom-reset');
        return;
      }
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
      const visibleGroups = getVisibleServiceGroups();
      if (visibleGroups[idx]) {
        void activateGroup(visibleGroups[idx]);
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
    state.closedTabsCount = payload.closedTabsCount ?? 0;
    state.gmailOpen = Boolean(payload.gmailOpen);
    state.gmailRuntime = payload.gmailRuntime ?? null;
    state.runtimeMap = new Map(payload.runtimeStates.map((rt) => [rt.instanceId, rt]));
    renderAll();
  });

  omniApi.onRuntimeUpdated((rt) => {
    state.runtimeMap.set(rt.instanceId, rt);
    renderSidebar();
    renderAccountBar();
    renderToolbarAndViewport();
    renderTabBar();
  });

  omniApi.onShortcut((payload) => {
    if (payload.action === 'open-catalog') {
      void openCatalogModal();
    } else if (payload.action === 'open-gesture-settings') {
      void openGestureModal();
    } else if (payload.action === 'focus-address-bar') {
      void focusAddressBar();
    } else if (payload.action === 'switch-tab' && typeof payload.payload === 'number') {
      const visibleGroups = getVisibleServiceGroups();
      const target = visibleGroups[payload.payload];
      if (target) {
        void activateGroup(target);
      }
    }
  });

  const data = await omniApi.getBootstrap();
  state.config = data.config;
  state.catalog = data.catalog;
  state.categories = data.categories;
  state.closedTabsCount = data.closedTabsCount ?? 0;
  state.gmailOpen = Boolean(data.gmailOpen);
  state.gmailRuntime = data.gmailRuntime ?? null;
  state.runtimeMap = new Map(data.runtimeStates.map((rt) => [rt.instanceId, rt]));

  el<HTMLSpanElement>('app-version').textContent = `v${data.appVersion} · Windows`;

  renderAll();
}

void bootstrap();
