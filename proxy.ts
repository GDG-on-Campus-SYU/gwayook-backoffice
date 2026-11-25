import { createServerClient } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";
import { supabaseConfig } from "./lib/supabase/config";

export async function proxy(request: NextRequest) {
  let response = NextResponse.next({ request });
  const config = supabaseConfig();
  if (config) {
    const supabase = createServerClient(config.url, config.key, {
      cookies: {
        getAll: () => request.cookies.getAll(),
        setAll(values, headers) {
          for (const { name, value } of values) request.cookies.set(name, value);
          response = NextResponse.next({ request });
          for (const { name, value, options } of values) response.cookies.set(name, value, options);
          for (const [name, value] of Object.entries(headers)) response.headers.set(name, value);
        },
      },
    });
    await supabase.auth.getClaims();
  }
  if (!response.headers.has("Cache-Control")) response.headers.set("Cache-Control", "private, no-store");
  return response;
}

export const config = { matcher: ["/", "/login", "/team", "/schedule", "/gsa", "/guide/:path*", "/vote", "/bingo/:path*", "/presentations/:path*", "/admin/:path*"] };
