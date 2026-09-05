import { DurableObject } from "cloudflare:workers";
import type { Env } from "./common";

export const DAILY_BYTES_PER_OWNER = 2 * 1024 * 1024 * 1024;
export const DAILY_OBJECTS_PER_OWNER = 500;
export interface Usage { bytes: number; objects: number }
interface DailyUsage extends Usage { day: string }

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
}

export function quotaFor(env: Env, owner: string): DurableObjectStub<QuotaCounter> {
  return env.QUOTA_COUNTERS.get(env.QUOTA_COUNTERS.idFromName(owner));
}
