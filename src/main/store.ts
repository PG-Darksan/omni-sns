import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { SERVICE_CATALOG } from '../shared/catalog';
import {
  AddInstancePayload,
  AppConfig,
  AppSettings,
  ServiceInstance,
  UserAgentMode
} from '../shared/types';
import { makeBadgeText, normalizeServiceUrl } from '../shared/url-utils';

const CONFIG_VERSION = 1;

export function createDefaultSettings(): AppSettings {
  return {
    theme: 'dark',
    showMatchingServices: true,
    minimizeToTray: false,
    lockPin: '',
    sidebarWidth: 248,
    activeInstanceId: null
  };
}

export function createDefaultInstances(): ServiceInstance[] {
  const pinned = SERVICE_CATALOG.filter((service) => service.defaultPinned);
  return pinned.map((service, index) => ({
    instanceId: `svc-${service.id}-default`,
    serviceId: service.id,
    name: service.name,
    category: service.category,
    url: service.url,
    color: service.color,
    badge: service.badge,
    uaMode: service.defaultUa,
    muted: false,
    zoomFactor: 1.0,
    isAdultOrMatching: Boolean(service.isAdultOrMatching),
    notificationsEnabled: true,
    order: index
  }));
}

export function createDefaultConfig(): AppConfig {
  const instances = createDefaultInstances();
  const settings = createDefaultSettings();
  settings.activeInstanceId = instances[0]?.instanceId ?? null;
  return {
    version: CONFIG_VERSION,
    settings,
    instances,
    windowBounds: {
      width: 1380,
      height: 880,
      isMaximized: false
    }
  };
}

export class ConfigStore {
  private readonly filePath: string;
  private config: AppConfig;

  constructor(filePath: string) {
    this.filePath = filePath;
    this.config = this.load();
  }

  private load(): AppConfig {
    try {
      if (!fs.existsSync(this.filePath)) {
        const initial = createDefaultConfig();
        this.saveAtomic(initial);
        return initial;
      }

      const raw = fs.readFileSync(this.filePath, 'utf-8');
      const parsed = JSON.parse(raw) as Partial<AppConfig>;
      const defaults = createDefaultConfig();

      const settings: AppSettings = {
        ...defaults.settings,
        ...(parsed.settings ?? {})
      };

      // 数値の安全クランプ
      settings.sidebarWidth = Math.max(180, Math.min(360, Number(settings.sidebarWidth) || 248));

      const instances: ServiceInstance[] = Array.isArray(parsed.instances)
        ? parsed.instances
            .filter((item): item is ServiceInstance => Boolean(item && item.instanceId && item.url))
            .map((item, idx) => ({
              instanceId: String(item.instanceId),
              serviceId: String(item.serviceId || 'custom'),
              name: String(item.name || 'SNS'),
              category: item.category || 'custom',
              url: normalizeServiceUrl(item.url) ?? 'https://example.com/',
              color: typeof item.color === 'string' && /^#[0-9A-Fa-f]{6}$/.test(item.color)
                ? item.color
                : '#3B82F6',
              badge: String(item.badge || makeBadgeText(String(item.name || 'SN'))).slice(0, 2),
              uaMode: (item.uaMode === 'mobile' ? 'mobile' : 'desktop') as UserAgentMode,
              muted: Boolean(item.muted),
              zoomFactor: Math.max(0.5, Math.min(2.0, Number(item.zoomFactor) || 1.0)),
              isAdultOrMatching: Boolean(item.isAdultOrMatching),
              notificationsEnabled: item.notificationsEnabled !== false,
              order: typeof item.order === 'number' ? item.order : idx
            }))
            .sort((a, b) => a.order - b.order)
            .map((item, idx) => ({ ...item, order: idx }))
        : defaults.instances;

      const activeValid = instances.some((i) => i.instanceId === settings.activeInstanceId);
      if (!activeValid) {
        settings.activeInstanceId = instances[0]?.instanceId ?? null;
      }

      return {
        version: CONFIG_VERSION,
        settings,
        instances,
        windowBounds: parsed.windowBounds ?? defaults.windowBounds
      };
    } catch {
      const fallback = createDefaultConfig();
      this.saveAtomic(fallback);
      return fallback;
    }
  }

  private saveAtomic(data: AppConfig): void {
    const dir = path.dirname(this.filePath);
    fs.mkdirSync(dir, { recursive: true });
    const tempPath = `${this.filePath}.tmp`;
    fs.writeFileSync(tempPath, JSON.stringify(data, null, 2), 'utf-8');
    fs.renameSync(tempPath, this.filePath);
  }

  private persist(): void {
    this.saveAtomic(this.config);
  }

  public getConfig(): AppConfig {
    return structuredClone(this.config);
  }

  public getInstances(): ServiceInstance[] {
    return structuredClone(this.config.instances);
  }

  public getInstance(instanceId: string): ServiceInstance | undefined {
    const found = this.config.instances.find((item) => item.instanceId === instanceId);
    return found ? structuredClone(found) : undefined;
  }

  public getSettings(): AppSettings {
    return structuredClone(this.config.settings);
  }

  public addInstance(payload: AddInstancePayload): ServiceInstance {
    const normalizedUrl = normalizeServiceUrl(payload.url);
    if (!normalizedUrl) {
      throw new Error('有効な http:// または https:// URL を入力してください。');
    }

    const trimmedName = payload.name.trim() || 'カスタムSNS';
    const shortId = crypto.randomBytes(4).toString('hex');
    const safePrefix = payload.serviceId.replace(/[^a-zA-Z0-9_-]/g, '') || 'custom';

    const instance: ServiceInstance = {
      instanceId: `svc-${safePrefix}-${shortId}`,
      serviceId: payload.serviceId || 'custom',
      name: trimmedName,
      category: payload.category || 'custom',
      url: normalizedUrl,
      color: /^#[0-9A-Fa-f]{6}$/.test(payload.color) ? payload.color : '#3B82F6',
      badge: (payload.badge?.trim() || makeBadgeText(trimmedName)).slice(0, 2),
      uaMode: payload.uaMode === 'mobile' ? 'mobile' : 'desktop',
      muted: false,
      zoomFactor: 1.0,
      isAdultOrMatching: Boolean(payload.isAdultOrMatching),
      notificationsEnabled: true,
      order: this.config.instances.length
    };

    this.config.instances.push(instance);
    this.config.settings.activeInstanceId = instance.instanceId;
    this.persist();
    return structuredClone(instance);
  }

  public removeInstance(instanceId: string): boolean {
    const prevLength = this.config.instances.length;
    this.config.instances = this.config.instances
      .filter((item) => item.instanceId !== instanceId)
      .map((item, idx) => ({ ...item, order: idx }));

    if (this.config.instances.length === prevLength) {
      return false;
    }

    if (this.config.settings.activeInstanceId === instanceId) {
      this.config.settings.activeInstanceId = this.config.instances[0]?.instanceId ?? null;
    }

    this.persist();
    return true;
  }

  public updateInstance(
    instanceId: string,
    patch: Partial<Pick<ServiceInstance, 'name' | 'url' | 'uaMode' | 'muted' | 'zoomFactor' | 'notificationsEnabled' | 'color' | 'badge'>>
  ): ServiceInstance | undefined {
    const target = this.config.instances.find((item) => item.instanceId === instanceId);
    if (!target) return undefined;

    if (typeof patch.name === 'string' && patch.name.trim()) {
      target.name = patch.name.trim();
    }
    if (typeof patch.url === 'string') {
      const normalized = normalizeServiceUrl(patch.url);
      if (normalized) target.url = normalized;
    }
    if (patch.uaMode === 'desktop' || patch.uaMode === 'mobile') {
      target.uaMode = patch.uaMode;
    }
    if (typeof patch.muted === 'boolean') {
      target.muted = patch.muted;
    }
    if (typeof patch.zoomFactor === 'number' && Number.isFinite(patch.zoomFactor)) {
      target.zoomFactor = Math.max(0.5, Math.min(2.0, Math.round(patch.zoomFactor * 100) / 100));
    }
    if (typeof patch.notificationsEnabled === 'boolean') {
      target.notificationsEnabled = patch.notificationsEnabled;
    }
    if (typeof patch.color === 'string' && /^#[0-9A-Fa-f]{6}$/.test(patch.color)) {
      target.color = patch.color;
    }
    if (typeof patch.badge === 'string' && patch.badge.trim()) {
      target.badge = patch.badge.trim().slice(0, 2);
    }

    this.persist();
    return structuredClone(target);
  }

  public reorderInstances(orderedIds: string[]): ServiceInstance[] {
    const map = new Map(this.config.instances.map((item) => [item.instanceId, item]));
    const reordered: ServiceInstance[] = [];

    for (const id of orderedIds) {
      const item = map.get(id);
      if (item) {
        reordered.push(item);
        map.delete(id);
      }
    }
    // 残りの項目があれば末尾に追加
    for (const remaining of map.values()) {
      reordered.push(remaining);
    }

    this.config.instances = reordered.map((item, idx) => ({ ...item, order: idx }));
    this.persist();
    return this.getInstances();
  }

  public updateSettings(patch: Partial<AppSettings>): AppSettings {
    const next: AppSettings = {
      ...this.config.settings,
      ...patch
    };

    if (next.theme !== 'dark' && next.theme !== 'light') {
      next.theme = 'dark';
    }
    next.sidebarWidth = Math.max(180, Math.min(360, Number(next.sidebarWidth) || 248));
    next.lockPin = typeof next.lockPin === 'string' ? next.lockPin.slice(0, 16) : '';

    this.config.settings = next;
    this.persist();
    return this.getSettings();
  }

  public updateWindowBounds(bounds: NonNullable<AppConfig['windowBounds']>): void {
    this.config.windowBounds = {
      ...this.config.windowBounds,
      ...bounds
    };
    this.persist();
  }
}
