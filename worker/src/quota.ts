import { DurableObject } from "cloudflare:workers";
import type { Env } from "./common";

export const DAILY_BYTES_PER_OWNER = 2 * 1024 * 1024 * 1024;
export const DAILY_OBJECTS_PER_OWNER = 500;

/**
 * Library traffic gets its own, much higher daily ceilings (F57): the share-link numbers do not
 * describe a library, and a first sync at 2 GB/day would take weeks.
 */
export const DAILY_LIBRARY_BYTES = 50 * 1024 * 1024 * 1024;
export const DAILY_LIBRARY_OBJECTS = 20_000;

/**
 * What an owner may keep (F57). With one tenant (D2) this is not a product limit but a personal
 * guardrail: it exists so a runaway sync fails loudly instead of arriving as a bill.
 */
export const STORED_BYTES_PER_OWNER = 100 * 1024 * 1024 * 1024;

export interface Usage { bytes: number; objects: number }
interface DailyUsage extends Usage { day: string }
export interface StoredUsage { storedBytes: number; storedObjects: number }

/** One instance per owner. A transaction covers the limit check AND reservation, including
 * concurrent requests from different locations. Only one day's counter is retained. */
export class QuotaCounter extends DurableObject<Env> {
  private async current(storage: DurableObjectTransaction, owner: string): Promise<DailyUsage> {
    const day = new Date().toISOString().slice(0, 10);
    const stored = await storage.get<DailyUsage>("usage");
    if (stored?.day === day) return stored;
    // Carry forward the legacy counter on the deployment day. After the migration, all writes
    // and reads use this object; KV is only consulted once per owner/day for old usage.
    const legacy = await this.env.QUOTAS.get<Partial<Usage>>(`quota:${owner}:${day}`, "json");
    const finite = (n: unknown): number => typeof n === "number" && Number.isFinite(n) && n > 0 ? n : 0;
    return { day, bytes: finite(legacy?.bytes), objects: finite(legacy?.objects) };
  }

  async charge(owner: string, bytes: number): Promise<string | null> {
    if (!Number.isSafeInteger(bytes) || bytes < 0) throw new Error("invalid quota charge");
    return this.ctx.storage.transaction(async (storage) => {
      const used = await this.current(storage, owner);
      const error = used.bytes + bytes > DAILY_BYTES_PER_OWNER ? "daily byte quota reached"
        : used.objects + 1 > DAILY_OBJECTS_PER_OWNER ? "daily object quota reached" : null;
      if (error) {
        // Even a denied first request completes the legacy migration; a later KV read must
        // never lower a limit we have already observed.
        await storage.put("usage", used);
        return error;
      }
      await storage.put("usage", { day: used.day, bytes: used.bytes + bytes, objects: used.objects + 1 });
      return null;
    });
  }

  async usage(owner: string): Promise<Usage> {
    return this.ctx.storage.transaction(async (storage) => {
      const used = await this.current(storage, owner);
      await storage.put("usage", used);
      return { bytes: used.bytes, objects: used.objects };
    });
  }

  /**
   * Charge library traffic: against the stored ceiling, which persists, and against a daily one,
   * which bounds the damage from a leaked credential (F56).
   *
   * F75: there is no carry-forward here. The `lib/` prefix does not exist before M6, so every
   * owner's stored bytes are genuinely zero on the deployment day — the counters simply start.
   */
  async chargeLibrary(bytes: number): Promise<string | null> {
    if (!Number.isSafeInteger(bytes) || bytes < 0) throw new Error("invalid quota charge");
    return this.ctx.storage.transaction(async (storage) => {
      const day = new Date().toISOString().slice(0, 10);
      const stored = (await storage.get<StoredUsage>("stored")) ?? { storedBytes: 0, storedObjects: 0 };
      const daily = (await storage.get<DailyUsage>("libraryDaily")) ?? { day, bytes: 0, objects: 0 };
      const today = daily.day === day ? daily : { day, bytes: 0, objects: 0 };

      if (stored.storedBytes + bytes > STORED_BYTES_PER_OWNER) {
        return `stored quota reached (${STORED_BYTES_PER_OWNER} bytes)`;
      }
      if (today.bytes + bytes > DAILY_LIBRARY_BYTES) return "daily library byte quota reached";
      if (today.objects + 1 > DAILY_LIBRARY_OBJECTS) return "daily library object quota reached";

      await storage.put("stored", {
        storedBytes: stored.storedBytes + bytes,
        storedObjects: stored.storedObjects + 1,
      });
      await storage.put("libraryDaily", {
        day, bytes: today.bytes + bytes, objects: today.objects + 1,
      });
      return null;
    });
  }

  /** Deleting returns the space (F56). Never below zero, whatever the caller claims. */
  async creditLibrary(bytes: number, objects = 1): Promise<void> {
    await this.ctx.storage.transaction(async (storage) => {
      const stored = (await storage.get<StoredUsage>("stored")) ?? { storedBytes: 0, storedObjects: 0 };
      await storage.put("stored", {
        storedBytes: Math.max(0, stored.storedBytes - bytes),
        storedObjects: Math.max(0, stored.storedObjects - objects),
      });
    });
  }

  async storedUsage(): Promise<StoredUsage> {
    return (await this.ctx.storage.get<StoredUsage>("stored"))
      ?? { storedBytes: 0, storedObjects: 0 };
  }

  /**
   * Recompute from what R2 actually holds (F76). Counters drift when a delete or a multipart
   * upload fails partway, and this is the only supported repair.
   */
  async reconcileStored(owner: string): Promise<StoredUsage> {
    let storedBytes = 0;
    let storedObjects = 0;
    let cursor: string | undefined;
    for (let page = 0; page < 100; page++) {
      const listed = await this.env.BUCKET.list({ prefix: `lib/${owner}/`, limit: 1000, cursor });
      for (const object of listed.objects) {
        storedBytes += object.size;
        storedObjects += 1;
      }
      if (!listed.truncated) break;
      cursor = listed.cursor;
    }
    await this.ctx.storage.put("stored", { storedBytes, storedObjects });
    return { storedBytes, storedObjects };
  }
}

export function quotaFor(env: Env, owner: string): DurableObjectStub<QuotaCounter> {
  return env.QUOTA_COUNTERS.get(env.QUOTA_COUNTERS.idFromName(owner));
}
