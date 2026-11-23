import { GestureSettings, GestureShape } from '../shared/types';
import { omniApi } from './omni-api';

export const SINGLE_SHAPES: GestureShape[] = ['L', 'R', 'U', 'D'];
export const DOUBLE_SHAPES: GestureShape[] = ['LU', 'LD', 'RU', 'RD', 'UL', 'UR', 'DL', 'DR'];
export const ALL_SHAPES: GestureShape[] = [...SINGLE_SHAPES, ...DOUBLE_SHAPES];

export const DEFAULT_GESTURES: Record<GestureShape, string> = {
  L: 'previous-tab',
  R: 'next-tab',
  U: 'scroll:up',
  D: 'scroll:down',
  LU: 'previous-service',
  LD: 'go-forward',
  RU: 'next-service',
  RD: 'reload',
  UL: 'go-back',
  UR: 'restore-closed',
  DL: 'new-tab',
  DR: 'close-tab'
};

interface ActionItem {
  id: string;
  label: string;
  badge?: string;
  svg?: string;
  hint?: string;
  keywords?: string;
}

interface ActionSection {
  title: string;
  compactFullWidth?: boolean;
  items: ActionItem[];
}

const ICON_CTRL_CLICK =
  '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M4 4l7.07 17 2.51-7.39L21 11.07z"/><line x1="16" y1="16" x2="21" y2="21"/></svg>';
const ICON_TOGGLE_UA =
  '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M13 15H4a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h11a2 2 0 0 1 2 2v2"/><line x1="6" y1="19" x2="11" y2="19"/><line x1="8.5" y1="15" x2="8.5" y2="19"/><rect x="15" y="10" width="7" height="10" rx="1.5"/><line x1="18.5" y1="17.5" x2="18.51" y2="17.5"/></svg>';
const ICON_MUTE =
  '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5"/><line x1="22" y1="9" x2="16" y2="15"/><line x1="16" y1="9" x2="22" y2="15"/></svg>';
const ICON_ZOOM_IN =
  '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="11" cy="11" r="7"/><line x1="21" y1="21" x2="16.65" y2="16.65"/><line x1="11" y1="8" x2="11" y2="14"/><line x1="8" y1="11" x2="14" y2="11"/></svg>';
const ICON_ZOOM_OUT =
  '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="11" cy="11" r="7"/><line x1="21" y1="21" x2="16.65" y2="16.65"/><line x1="8" y1="11" x2="14" y2="11"/></svg>';
const ICON_ZOOM_RESET =
  '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M4 9V6a2 2 0 0 1 2-2h3"/><path d="M15 4h3a2 2 0 0 1 2 2v3"/><path d="M20 15v3a2 2 0 0 1-2 2h-3"/><path d="M9 20H6a2 2 0 0 1-2-2v-3"/><circle cx="12" cy="12" r="2.2"/></svg>';
const ICON_OPEN_EXTERNAL =
  '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"/><polyline points="15 3 21 3 21 9"/><line x1="10" y1="14" x2="21" y2="3"/></svg>';
const ICON_GESTURE_SETTINGS =
  '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><line x1="4" y1="21" x2="4" y2="14"/><line x1="4" y1="10" x2="4" y2="3"/><line x1="12" y1="21" x2="12" y2="12"/><line x1="12" y1="8" x2="12" y2="3"/><line x1="20" y1="21" x2="20" y2="16"/><line x1="20" y1="12" x2="20" y2="3"/><line x1="1" y1="14" x2="7" y2="14"/><line x1="9" y1="8" x2="15" y2="8"/><line x1="17" y1="16" x2="23" y2="16"/></svg>';

export const ACTION_SECTIONS: ActionSection[] = [
  {
    title: '未割り当て',
    compactFullWidth: true,
    items: [{ id: 'none', label: '何もしない', badge: '—' }]
  },
  {
    title: 'タブ操作',
    items: [
      { id: 'previous-tab', label: '前のタブへ', badge: '◀', hint: 'サブタブ1枚時は前のSNSへ' },
      { id: 'next-tab', label: '次のタブへ', badge: '▶', hint: 'サブタブ1枚時は次のSNSへ' },
      { id: 'new-tab', label: '新しいタブを開く', badge: '＋' },
      {
        id: 'ctrl-click',
        label: 'Ctrl+クリック',
        svg: ICON_CTRL_CLICK,
        hint: 'ジェスチャー開始位置を Ctrl+クリック（リンクを同一アカウントの別タブで開く）',
        keywords: 'ctrl click クリック リンク 新しいタブ 別タブ バックグラウンド'
      },
      { id: 'duplicate-tab', label: '現在のタブを複製', badge: '⧉' },
      { id: 'close-tab', label: '現在のタブを閉じる', badge: '✕', hint: '最後の1枚を閉じてもサイドバーからは消えず休止します' },
      { id: 'close-other-tabs', label: 'このタブ以外を閉じる', badge: '⊘' },
      { id: 'restore-closed', label: '閉じたタブを復元', badge: '↶' }
    ]
  },
  {
    title: 'スクロール（ドラッグ中リアルタイム進行）',
    items: [
      { id: 'scroll:up', label: '上へスクロール（連続）', badge: '⇈', hint: '線を伸ばすほど高速' },
      { id: 'scroll:down', label: '下へスクロール（連続）', badge: '⇊', hint: '線を伸ばすほど高速' },
      { id: 'scroll:left', label: '左へスクロール（連続）', badge: '⇇', hint: '線を伸ばすほど高速' },
      { id: 'scroll:right', label: '右へスクロール（連続）', badge: '⇉', hint: '線を伸ばすほど高速' },
      { id: 'scroll-top', label: '一番上へスクロール', badge: '⤒' },
      { id: 'scroll-bottom', label: '一番下へスクロール', badge: '⤓' }
    ]
  },
  {
    title: 'ページ・ナビゲーション',
    items: [
      { id: 'go-back', label: '戻る', badge: '←' },
      { id: 'go-forward', label: '進む', badge: '→' },
      { id: 'reload', label: '再読み込み', badge: '↻' },
      { id: 'hard-reload', label: 'スーパーリロード', badge: '⟳' },
      { id: 'home', label: 'ホーム / DM画面へ戻る', badge: '⌂' }
    ]
  },
  {
    title: '表示・アプリ操作',
    items: [
      { id: 'toggle-ua', label: 'PC版 / スマホ版 UA切替', svg: ICON_TOGGLE_UA },
      { id: 'toggle-mute', label: 'ミュート切替', svg: ICON_MUTE },
      { id: 'zoom-in', label: '拡大', svg: ICON_ZOOM_IN },
      { id: 'zoom-out', label: '縮小', svg: ICON_ZOOM_OUT },
      { id: 'zoom-reset', label: 'ズームリセット (100%)', svg: ICON_ZOOM_RESET },
      { id: 'open-external', label: '既定のブラウザで開く', svg: ICON_OPEN_EXTERNAL },
      { id: 'gesture:settings', label: 'ジェスチャー設定を開く', svg: ICON_GESTURE_SETTINGS }
    ]
  },
  {
    title: 'SNS・アカウント切替',
    items: [
      { id: 'previous-service', label: '前のSNSサービスへ', badge: '▲' },
      { id: 'next-service', label: '次のSNSサービスへ', badge: '▼' },
      { id: 'previous-account', label: '前のアカウントへ（同一SNS）', badge: '◁' },
      { id: 'next-account', label: '次のアカウントへ（同一SNS）', badge: '▷' },
      { id: 'open-catalog', label: 'SNSカタログを開く', badge: '⊞' },
      { id: 'sleep-tab', label: 'このSNSを休止（メモリ解放）', badge: '☾' }
    ]
  }
];

const ACTION_LABEL_MAP = new Map<string, string>();
for (const sec of ACTION_SECTIONS) {
  for (const item of sec.items) {
    ACTION_LABEL_MAP.set(item.id, item.label);
  }
}

export function actionLabel(actionId: string): string {
  return ACTION_LABEL_MAP.get(actionId) ?? '何もしない';
}

export function shapeArrows(shape: string): string {
  return shape
    .split('')
    .map((c) => (c === 'L' ? '←' : c === 'R' ? '→' : c === 'U' ? '↑' : c === 'D' ? '↓' : ''))
    .join('');
}

export function shapeNameJa(shape: string): string {
  return shape
    .split('')
    .map((c) => (c === 'L' ? '左' : c === 'R' ? '右' : c === 'U' ? '上' : c === 'D' ? '下' : ''))
    .join('→');
}

/** HisatorNotebook _W246ShapeIconPainter 準拠の SVG アイコン（始点丸 + 直線 + 終点矢印） */
export function buildShapeSvg(shape: string, size = 28): string {
  const unit = (d: string): [number, number] =>
    d === 'L' ? [-1, 0] : d === 'R' ? [1, 0] : d === 'U' ? [0, -1] : [0, 1];

  const raw: [number, number][] = [[0, 0]];
  for (const d of shape) {
    const last = raw[raw.length - 1];
    const u = unit(d);
    raw.push([last[0] + u[0], last[1] + u[1]]);
  }

  let minX = 0;
  let minY = 0;
  let maxX = 0;
  let maxY = 0;
  for (const [x, y] of raw) {
    if (x < minX) minX = x;
    if (y < minY) minY = y;
    if (x > maxX) maxX = x;
    if (y > maxY) maxY = y;
  }

  const pad = 6;
  const span = Math.max(1, maxX - minX, maxY - minY);
  const scale = (size - pad * 2) / span;
  const w = (maxX - minX) * scale;
  const h = (maxY - minY) * scale;
  const ox = (size - w) / 2 - minX * scale;
  const oy = (size - h) / 2 - minY * scale;

  const pts = raw.map(([x, y]) => [x * scale + ox, y * scale + oy]);
  const lineD = pts
    .map(([x, y], idx) => `${idx === 0 ? 'M' : 'L'}${x.toFixed(1)},${y.toFixed(1)}`)
    .join(' ');

  const end = pts[pts.length - 1];
  const [dx, dy] = unit(shape[shape.length - 1]);
  const head = 4.5;
  const bx = end[0] - dx * head;
  const by = end[1] - dy * head;
  const sx = -dy * head * 0.72;
  const sy = dx * head * 0.72;
  const arrowD = `M${(bx + sx).toFixed(1)},${(by + sy).toFixed(1)} L${end[0].toFixed(1)},${end[1].toFixed(1)} L${(bx - sx).toFixed(1)},${(by - sy).toFixed(1)}`;

  const start = pts[0];
  return (
    `<svg width="${size}" height="${size}" viewBox="0 0 ${size} ${size}" fill="none" aria-hidden="true">` +
    `<path d="${lineD}" stroke="#159CAB" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/>` +
    `<path d="${arrowD}" stroke="#159CAB" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/>` +
    `<circle cx="${start[0].toFixed(1)}" cy="${start[1].toFixed(1)}" r="3.4" fill="#ffffff"/>` +
    `<circle cx="${start[0].toFixed(1)}" cy="${start[1].toFixed(1)}" r="2.4" fill="#159CAB"/>` +
    `</svg>`
  );
}

export class GestureBoardModal {
  private settings: GestureSettings | null = null;
  private selectedShape: GestureShape = 'L';
  private batchMode = false;
  private selectingClear = false;
  private clearSelection = new Set<GestureShape>();
  private searchQuery = '';
  private undoStack: Record<string, string>[] = [];
  private dragShape: GestureShape | null = null;
  private readonly onToast: (msg: string) => void;
  private readonly onCloseRequested: () => Promise<void>;

  constructor(opts: { onToast: (msg: string) => void; onCloseRequested: () => Promise<void> }) {
    this.onToast = opts.onToast;
    this.onCloseRequested = opts.onCloseRequested;
    this.bindStaticEvents();
  }

  public syncSettings(settings: GestureSettings): void {
    this.settings = structuredClone(settings);
    if (!this.isOpen()) return;
    this.render();
  }

  public isOpen(): boolean {
    const modal = document.getElementById('gesture-modal');
    return Boolean(modal && !modal.classList.contains('hidden'));
  }

  public open(current: GestureSettings): void {
    this.settings = structuredClone(current);
    this.selectingClear = false;
    this.clearSelection.clear();
    const modal = document.getElementById('gesture-modal');
    modal?.classList.remove('hidden');
    this.render();
  }

  public close(): void {
    const modal = document.getElementById('gesture-modal');
    modal?.classList.add('hidden');
    this.selectingClear = false;
    this.clearSelection.clear();
  }

  public handleKeyDown(e: KeyboardEvent): boolean {
    if (!this.isOpen()) return false;
    if (e.key === 'Escape') {
      if (this.selectingClear) {
        this.selectingClear = false;
        this.clearSelection.clear();
        this.render();
      } else {
        void this.onCloseRequested();
      }
      return true;
    }
    if ((e.ctrlKey || e.metaKey) && !e.shiftKey && !e.altKey && e.key.toLowerCase() === 'z') {
      const searchEl = document.getElementById('gesture-search') as HTMLInputElement | null;
      if (document.activeElement === searchEl && searchEl?.value) {
        return false;
      }
      if (this.undoStack.length > 0) {
        e.preventDefault();
        void this.undo();
        return true;
      }
    }
    return false;
  }

  private async commitSettings(next: GestureSettings, pushUndoMap?: Record<string, string>): Promise<void> {
    if (pushUndoMap) {
      this.undoStack.push(pushUndoMap);
      if (this.undoStack.length > 60) this.undoStack.shift();
    }
    this.settings = structuredClone(next);
    this.render();
    await omniApi.updateGestureSettings(next);
  }

  private async assignAction(actionId: string): Promise<void> {
    if (!this.settings) return;
    const prevMap = { ...this.settings.gestures };

    // 重複禁止モード時は他の方向に同じ操作が入っていたら先に外す（何もしないは除く）
    const nextMap = { ...prevMap };
    if (!this.settings.allowDup && actionId !== 'none') {
      for (const s of ALL_SHAPES) {
        if (s !== this.selectedShape && nextMap[s] === actionId) {
          nextMap[s] = 'none';
        }
      }
    }
    nextMap[this.selectedShape] = actionId;

    const assignedShape = this.selectedShape;
    if (this.batchMode) {
      const curIdx = ALL_SHAPES.indexOf(this.selectedShape);
      if (curIdx >= 0 && curIdx < ALL_SHAPES.length - 1) {
        this.selectedShape = ALL_SHAPES[curIdx + 1];
      }
    }

    await this.commitSettings({ ...this.settings, gestures: nextMap }, prevMap);
    this.onToast(`${shapeArrows(assignedShape)} (${shapeNameJa(assignedShape)}) に「${actionLabel(actionId)}」を割り当てました`);
  }

  private async unassignAction(actionId: string): Promise<void> {
    if (!this.settings || actionId === 'none') return;
    const prevMap = { ...this.settings.gestures };
    const nextMap = { ...prevMap };
    const removed: string[] = [];
    for (const s of ALL_SHAPES) {
      if (nextMap[s] === actionId) {
        nextMap[s] = 'none';
        removed.push(shapeArrows(s));
      }
    }
    if (removed.length === 0) return;
    await this.commitSettings({ ...this.settings, gestures: nextMap }, prevMap);
    this.onToast(`${removed.join(' ')} の「${actionLabel(actionId)}」を外しました`);
  }

  private async swapShapes(from: GestureShape, to: GestureShape): Promise<void> {
    if (!this.settings || from === to) return;
    const prevMap = { ...this.settings.gestures };
    const nextMap = { ...prevMap };
    const tmp = nextMap[from] ?? 'none';
    nextMap[from] = nextMap[to] ?? 'none';
    nextMap[to] = tmp;
    this.selectedShape = to;
    await this.commitSettings({ ...this.settings, gestures: nextMap }, prevMap);
    this.onToast(`${shapeArrows(from)} と ${shapeArrows(to)} の割り当てを入れ替えました`);
  }

  private async undo(): Promise<void> {
    if (!this.settings || this.undoStack.length === 0) return;
    const prevMap = this.undoStack.pop()!;
    await this.commitSettings({ ...this.settings, gestures: prevMap });
    this.onToast('直前のジェスチャー変更を取り消しました');
  }

  private bindStaticEvents(): void {
    document.getElementById('btn-close-gesture')?.addEventListener('click', () => {
      void this.onCloseRequested();
    });

    document.getElementById('gesture-enabled')?.addEventListener('change', (e) => {
      if (!this.settings) return;
      const checked = (e.target as HTMLInputElement).checked;
      void this.commitSettings({ ...this.settings, enabled: checked });
    });

    document.getElementById('gesture-search')?.addEventListener('input', (e) => {
      this.searchQuery = (e.target as HTMLInputElement).value;
      this.renderCandidates();
    });

    document.getElementById('btn-gesture-batch')?.addEventListener('click', () => {
      this.batchMode = !this.batchMode;
      this.render();
    });

    document.getElementById('btn-gesture-select-clear')?.addEventListener('click', async () => {
      if (!this.settings) return;
      if (!this.selectingClear) {
        this.selectingClear = true;
        this.clearSelection.clear();
        this.render();
        return;
      }
      if (this.clearSelection.size > 0) {
        const prevMap = { ...this.settings.gestures };
        const nextMap = { ...prevMap };
        let count = 0;
        for (const s of this.clearSelection) {
          if ((nextMap[s] ?? 'none') !== 'none') {
            nextMap[s] = 'none';
            count++;
          }
        }
        this.selectingClear = false;
        this.clearSelection.clear();
        if (count > 0) {
          await this.commitSettings({ ...this.settings, gestures: nextMap }, prevMap);
          this.onToast(`${count} 件のジェスチャー割り当てを外しました`);
        } else {
          this.render();
        }
      } else {
        this.selectingClear = false;
        this.render();
      }
    });

    document.getElementById('btn-gesture-clear-all')?.addEventListener('click', async () => {
      if (!this.settings) return;
      const prevMap = { ...this.settings.gestures };
      const nextMap: Record<string, string> = {};
      let count = 0;
      for (const s of ALL_SHAPES) {
        if ((prevMap[s] ?? 'none') !== 'none') count++;
        nextMap[s] = 'none';
      }
      if (count === 0) return;
      await this.commitSettings({ ...this.settings, gestures: nextMap }, prevMap);
      this.onToast(`${count} 件の割り当てをすべて外しました`);
    });

    document.getElementById('btn-gesture-reset')?.addEventListener('click', async () => {
      if (!this.settings) return;
      const prevMap = { ...this.settings.gestures };
      await this.commitSettings(
        { ...this.settings, gestures: { ...DEFAULT_GESTURES } },
        prevMap
      );
      this.onToast('ジェスチャー割り当てを初期値に戻しました');
    });

    document.getElementById('btn-gesture-undo')?.addEventListener('click', () => {
      void this.undo();
    });

    const bindOptToggle = (id: string, key: 'wrapTabs' | 'showTrail' | 'showFeedback' | 'allowDup') => {
      document.getElementById(id)?.addEventListener('change', (e) => {
        if (!this.settings) return;
        const checked = (e.target as HTMLInputElement).checked;
        void this.commitSettings({ ...this.settings, [key]: checked });
      });
    };
    bindOptToggle('gesture-wrap-tabs', 'wrapTabs');
    bindOptToggle('gesture-show-trail', 'showTrail');
    bindOptToggle('gesture-show-feedback', 'showFeedback');
    bindOptToggle('gesture-allow-dup', 'allowDup');

    document.getElementById('gesture-tremor')?.addEventListener('input', (e) => {
      const val = Number((e.target as HTMLInputElement).value) || 4;
      const valEl = document.getElementById('gesture-tremor-val');
      if (valEl) valEl.textContent = String(val);
    });
    document.getElementById('gesture-tremor')?.addEventListener('change', (e) => {
      if (!this.settings) return;
      const val = Math.max(1, Math.min(30, Number((e.target as HTMLInputElement).value) || 4));
      void this.commitSettings({ ...this.settings, tremor: val });
    });
  }

  private render(): void {
    if (!this.settings) return;
    const s = this.settings;

    (document.getElementById('gesture-enabled') as HTMLInputElement).checked = s.enabled;
    (document.getElementById('gesture-wrap-tabs') as HTMLInputElement).checked = s.wrapTabs;
    (document.getElementById('gesture-show-trail') as HTMLInputElement).checked = s.showTrail;
    (document.getElementById('gesture-show-feedback') as HTMLInputElement).checked = s.showFeedback;
    (document.getElementById('gesture-allow-dup') as HTMLInputElement).checked = s.allowDup;
    (document.getElementById('gesture-tremor') as HTMLInputElement).value = String(s.tremor);
    const tremorVal = document.getElementById('gesture-tremor-val');
    if (tremorVal) tremorVal.textContent = String(s.tremor);

    const batchBtn = document.getElementById('btn-gesture-batch');
    batchBtn?.classList.toggle('active', this.batchMode);

    const selBtn = document.getElementById('btn-gesture-select-clear');
    if (selBtn) {
      selBtn.classList.toggle('active', this.selectingClear);
      selBtn.textContent = this.selectingClear
        ? this.clearSelection.size > 0
          ? `選択した ${this.clearSelection.size} 件を外す`
          : '選択を終了'
        : '選んで外す';
    }

    const undoBtn = document.getElementById('btn-gesture-undo') as HTMLButtonElement | null;
    if (undoBtn) undoBtn.disabled = this.undoStack.length === 0;

    const targetBadge = document.getElementById('gesture-target-indicator');
    if (targetBadge) {
      targetBadge.textContent = `割当先: ${shapeArrows(this.selectedShape)} (${shapeNameJa(this.selectedShape)})`;
    }

    this.renderBoard();
    this.renderCandidates();
  }

  private renderBoard(): void {
    if (!this.settings) return;
    this.renderShapeGrid('gesture-grid-single', SINGLE_SHAPES);
    this.renderShapeGrid('gesture-grid-double', DOUBLE_SHAPES);
  }

  private renderShapeGrid(containerId: string, shapes: GestureShape[]): void {
    const container = document.getElementById(containerId);
    if (!container || !this.settings) return;
    container.innerHTML = '';

    for (const shape of shapes) {
      const act = this.settings.gestures[shape] ?? 'none';
      const isNone = act === 'none';
      const cell = document.createElement('button');
      cell.type = 'button';
      cell.className = 'gesture-cell';
      if (!this.selectingClear && this.selectedShape === shape) cell.classList.add('selected');
      if (this.selectingClear && this.clearSelection.has(shape)) cell.classList.add('clear-selected');
      if (isNone) cell.classList.add('unassigned');
      cell.draggable = !this.selectingClear;
      cell.title = `${shapeNameJa(shape)}: ${actionLabel(act)}（ドラッグで他の方向と入替）`;

      cell.addEventListener('click', () => {
        if (this.selectingClear) {
          if (this.clearSelection.has(shape)) {
            this.clearSelection.delete(shape);
          } else {
            this.clearSelection.add(shape);
          }
          this.render();
          return;
        }
        this.selectedShape = shape;
        this.render();
      });

      cell.addEventListener('contextmenu', (e) => {
        e.preventDefault();
        if (!this.settings || (this.settings.gestures[shape] ?? 'none') === 'none') return;
        const prevMap = { ...this.settings.gestures };
        const nextMap = { ...prevMap, [shape]: 'none' };
        void this.commitSettings({ ...this.settings, gestures: nextMap }, prevMap);
        this.onToast(`${shapeArrows(shape)} の割り当てを外しました`);
      });

      cell.addEventListener('dragstart', (e) => {
        this.dragShape = shape;
        cell.classList.add('dragging');
        e.dataTransfer?.setData('text/plain', shape);
      });
      cell.addEventListener('dragend', () => {
        this.dragShape = null;
        cell.classList.remove('dragging');
        document
          .querySelectorAll('.gesture-cell.drag-over')
          .forEach((n) => n.classList.remove('drag-over'));
      });
      cell.addEventListener('dragover', (e) => {
        if (!this.dragShape || this.dragShape === shape) return;
        e.preventDefault();
        cell.classList.add('drag-over');
      });
      cell.addEventListener('dragleave', () => cell.classList.remove('drag-over'));
      cell.addEventListener('drop', (e) => {
        e.preventDefault();
        cell.classList.remove('drag-over');
        if (this.dragShape && this.dragShape !== shape) {
          void this.swapShapes(this.dragShape, shape);
        }
      });

      cell.innerHTML =
        `<div class="gesture-cell-head">` +
        `<span class="gesture-cell-svg">${buildShapeSvg(shape, 26)}</span>` +
        `<span class="gesture-cell-dir">${shapeNameJa(shape)}</span>` +
        `</div>` +
        `<div class="gesture-cell-action">${actionLabel(act)}</div>`;

      container.appendChild(cell);
    }
  }

  private renderCandidates(): void {
    const listEl = document.getElementById('gesture-candidates');
    if (!listEl || !this.settings) return;
    listEl.innerHTML = '';

    const q = this.searchQuery.trim().toLowerCase();
    const assignedMap = new Map<string, GestureShape[]>();
    for (const s of ALL_SHAPES) {
      const act = this.settings.gestures[s] ?? 'none';
      if (act === 'none') continue;
      const arr = assignedMap.get(act) ?? [];
      arr.push(s);
      assignedMap.set(act, arr);
    }
    const currentAssigned = this.settings.gestures[this.selectedShape] ?? 'none';

    const buildSectionEl = (sec: ActionSection, filtered: ActionItem[]): HTMLDivElement => {
      const secEl = document.createElement('div');
      secEl.className = sec.compactFullWidth ? 'gesture-sec gesture-sec-compact' : 'gesture-sec';

      const heading = document.createElement('div');
      heading.className = 'gesture-sec-title';
      heading.textContent = sec.title;
      secEl.appendChild(heading);

      for (const item of filtered) {
        const shapes = assignedMap.get(item.id) ?? [];
        const row = document.createElement('div');
        row.className = 'gesture-cand-row';
        if (currentAssigned === item.id) row.classList.add('is-current');
        if (!this.settings!.allowDup && shapes.length > 0 && currentAssigned !== item.id) {
          row.classList.add('is-used-elsewhere');
        }
        if (item.hint) row.title = item.hint;

        row.addEventListener('click', () => {
          void this.assignAction(item.id);
        });
        row.addEventListener('contextmenu', (e) => {
          e.preventDefault();
          if (shapes.length > 0) {
            void this.unassignAction(item.id);
          }
        });

        const iconSpan = document.createElement('span');
        iconSpan.className = 'gesture-cand-icon';
        if (item.svg) {
          iconSpan.innerHTML = item.svg;
        } else {
          iconSpan.textContent = item.badge ?? '';
        }

        const labelSpan = document.createElement('span');
        labelSpan.className = 'gesture-cand-label';
        labelSpan.textContent = item.label;

        row.appendChild(iconSpan);
        row.appendChild(labelSpan);

        if (shapes.length > 0) {
          const right = document.createElement('span');
          right.className = 'gesture-cand-assigned';

          const chip = document.createElement('span');
          chip.className = 'gesture-arrow-chip';
          chip.textContent = shapes.map(shapeArrows).join(' ');
          right.appendChild(chip);

          const clearBtn = document.createElement('button');
          clearBtn.type = 'button';
          clearBtn.className = 'gesture-cand-clear';
          clearBtn.textContent = '✕';
          clearBtn.title = 'この割り当てを外す';
          clearBtn.addEventListener('click', (e) => {
            e.stopPropagation();
            void this.unassignAction(item.id);
          });
          right.appendChild(clearBtn);
          row.appendChild(right);
        }

        secEl.appendChild(row);
      }

      return secEl;
    };

    const columnSections: { sec: ActionSection; items: ActionItem[] }[] = [];

    for (const sec of ACTION_SECTIONS) {
      const filtered = sec.items.filter((item) => {
        if (!q) return true;
        return (
          item.label.toLowerCase().includes(q) ||
          item.id.toLowerCase().includes(q) ||
          sec.title.toLowerCase().includes(q) ||
          (item.hint?.toLowerCase().includes(q) ?? false) ||
          (item.keywords?.toLowerCase().includes(q) ?? false)
        );
      });
      if (filtered.length === 0) continue;

      if (sec.compactFullWidth) {
        listEl.appendChild(buildSectionEl(sec, filtered));
      } else {
        columnSections.push({ sec, items: filtered });
      }
    }

    if (columnSections.length > 0) {
      const colsWrap = document.createElement('div');
      colsWrap.className = 'gesture-sec-columns';
      const colLeft = document.createElement('div');
      colLeft.className = 'gesture-sec-col';
      const colRight = document.createElement('div');
      colRight.className = 'gesture-sec-col';

      let leftWeight = 0;
      let rightWeight = 0;
      for (const entry of columnSections) {
        const weight = entry.items.length + 1.5;
        const secEl = buildSectionEl(entry.sec, entry.items);
        if (leftWeight <= rightWeight) {
          colLeft.appendChild(secEl);
          leftWeight += weight;
        } else {
          colRight.appendChild(secEl);
          rightWeight += weight;
        }
      }

      colsWrap.appendChild(colLeft);
      if (colRight.childNodes.length > 0) {
        colsWrap.appendChild(colRight);
      }
      listEl.appendChild(colsWrap);
    }
  }
}
