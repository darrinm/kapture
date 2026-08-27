import { defineWorkersConfig } from "@cloudflare/vitest-pool-workers/config";

export default defineWorkersConfig({
  test: {
    poolOptions: {
      workers: {
        wrangler: { configPath: "./wrangler.jsonc" },
        miniflare: {
          // sha256("test-token") — the suite authenticates with that literal
          bindings: {
            TOKENS: JSON.stringify({
              darrin: "4c5dc9b7708905f77f5e5d16316b5dfb425e68cb326dcd55a860e90a7707031e",
              friend: "0000000000000000000000000000000000000000000000000000000000000000",
            }),
            ADMIN_OWNER: "darrin",
            RELEASES_BASE: "https://github.com/darrinm/kapture/releases",
          },
        },
      },
    },
  },
});
