"use client";

import { useEffect } from "react";
import { useRouter } from "next/navigation";

export function BingoRefresh({ active, pending = false }: { active: boolean; pending?: boolean }) {
  const router = useRouter();
  useEffect(() => {
    if (!active) return;
    function refresh() {
      if (document.visibilityState === "visible") router.refresh();
    }
    const interval = window.setInterval(refresh, pending ? 5000 : 15000);
    window.addEventListener("focus", refresh);
    document.addEventListener("visibilitychange", refresh);
    return () => {
      window.clearInterval(interval);
      window.removeEventListener("focus", refresh);
      document.removeEventListener("visibilitychange", refresh);
    };
  }, [active, pending, router]);
  return null;
}
