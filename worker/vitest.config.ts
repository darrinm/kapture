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
            // wrangler.jsonc names the real Access application, and these vars come through
            // with the rest of it. Left set, every request in this suite is answered by the
            // Access branch — 403 for want of a JWT no test can mint — so the dashboard's own
            // rules would go untested. Blanked here to exercise the token fallback; the Access
            // branch is covered by test/access.test.ts against generated keys.
            ACCESS_TEAM_DOMAIN: "",
            ACCESS_AUD: "",
            ADMIN_EMAIL: "",
          },
        },
      },
    },
  },
});
