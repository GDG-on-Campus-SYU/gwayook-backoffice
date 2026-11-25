import type { Metadata } from "next";
import type { ReactNode } from "react";
import localFont from "next/font/local";
import { Providers } from "./providers";
import "./globals.css";

const pretendard = localFont({ src: "./fonts/PretendardVariable.woff2", variable: "--font-pretendard", weight: "100 900", display: "swap" });

export const metadata: Metadata = {
  title: { default: "과육톤", template: "%s · 과육톤" },
  description: "과육톤 참가자와 운영진을 위한 행사 운영 앱",
  robots: { index: false, follow: false },
};

export default function Layout({ children }: { children: ReactNode }) {
  return <html lang="ko" className={pretendard.variable}><body><Providers>{children}</Providers></body></html>;
}
