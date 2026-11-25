import { createServerClient } from "@supabase/ssr";
import { cookies, headers } from "next/headers";
import { isIP } from "node:net";
import { supabaseConfig } from "./config";

export async function createSupabase() {
  const config = supabaseConfig();
  if (!config) throw new Error("Supabase configuration is missing");

  const store = await cookies();
  const incoming = await headers();
  // Vercel overwrites this header. Local/direct API callers are labelled separately in the audit record.
  const ip = process.env.VERCEL ? incoming.get("x-vercel-forwarded-for")?.split(",")[0].trim() : undefined;
  return createServerClient(config.url, config.key, {
    global: { headers: ip && isIP(ip) ? { "x-gwayook-client-ip": ip } : {} },
    cookies: {
      getAll: () => store.getAll(),
      setAll(values) {
        try {
          for (const { name, value, options } of values) store.set(name, value, options);
        } catch {
          // Server Components rely on the proxy to refresh cookies.
        }
      },
    },
  });
}
