// Gives `env` from cloudflare:test the worker's own bindings instead of an empty ProvidedEnv.
import type { Env } from "../src/index";

declare module "cloudflare:test" {
  interface ProvidedEnv extends Env {}
}
