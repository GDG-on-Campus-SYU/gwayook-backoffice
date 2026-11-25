export function supabaseConfig() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;
  return url && key ? { url, key } : null;
}

export function appOrigin() {
  const value = process.env.APP_URL;
  if (!value) return null;
  try {
    const url = new URL(value);
    if (url.protocol === "https:" ||
      (url.protocol === "http:" && ["localhost", "127.0.0.1"].includes(url.hostname))) {
      return url.origin;
    }
  } catch {
    return null;
  }
  return null;
}
