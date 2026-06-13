import { z } from 'zod';

/**
 * Environment contract for the guardian. Fail fast at boot if misconfigured.
 * No secret has a default; URLs default to the public endpoints verified in docs/VERSIONS.md.
 */
const Env = z.object({
  NODE_ENV: z.enum(['development', 'production', 'test']).default('development'),
  PORT: z.coerce.number().int().positive().default(8080),

  // Solana / MagicBlock / Flash endpoints (see docs/VERSIONS.md "Live endpoints").
  BASE_RPC_URL: z.string().url().default('https://api.devnet.solana.com'),
  FLASH_ER_RPC_URL: z.string().url().default('https://flash.magicblock.xyz'),
  FLASH_API_URL: z.string().url().default('https://flashapi.trade/v2'),
  PYTH_HERMES_URL: z.string().url().default('https://hermes.pyth.network'),

  // Secret upstream RPC the guardian proxies for the client (web especially). Optional in dev.
  HELIUS_RPC_URL: z.string().url().optional(),

  // FCM push relay (firebase-admin). Optional until push is wired (M5).
  FCM_SERVICE_ACCOUNT_JSON: z.string().optional(),

  // Comma-separated origins allowed to call the proxy/incident endpoints.
  ALLOWED_ORIGINS: z.string().default('*'),
});

export type Config = z.infer<typeof Env>;

export function loadConfig(): Config {
  const parsed = Env.safeParse(process.env);
  if (!parsed.success) {
    // Surface every misconfiguration at once.
    const issues = parsed.error.issues.map((i) => `  ${i.path.join('.')}: ${i.message}`).join('\n');
    throw new Error(`Invalid guardian environment:\n${issues}`);
  }
  return parsed.data;
}
