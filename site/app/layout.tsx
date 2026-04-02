import type { Metadata } from "next";
import { Newsreader, Outfit, JetBrains_Mono } from "next/font/google";
import "./globals.css";

const newsreader = Newsreader({
  variable: "--font-newsreader",
  subsets: ["latin"],
  style: ["normal", "italic"],
  weight: ["400", "600", "700"],
});

const outfit = Outfit({
  variable: "--font-outfit",
  subsets: ["latin"],
  weight: ["300", "400", "500", "600"],
});

const jetbrainsMono = JetBrains_Mono({
  variable: "--font-jetbrains-mono",
  subsets: ["latin"],
  weight: ["400", "500"],
});

export const metadata: Metadata = {
  title: "VoiceLayer — Native Voice I/O for AI Coding Assistants",
  description:
    "macOS menu bar app with F6 push-to-talk, on-device whisper.cpp transcription, Hebrew & English support. Works with Claude Code, Cursor, and any MCP client.",
  metadataBase: new URL("https://voicelayer.etanheyman.com"),
  alternates: {
    canonical: "/",
  },
  openGraph: {
    title: "VoiceLayer — Native Voice I/O for AI Coding Assistants",
    description:
      "Press F6. Speak. Ship. On-device whisper.cpp STT, edge-tts cloud TTS, Qwen3-TTS cloned voices. Works with any MCP client.",
    type: "website",
    url: "https://voicelayer.etanheyman.com",
    siteName: "VoiceLayer",
    images: [
      {
        url: "/og.png",
        width: 1200,
        height: 630,
        alt: "VoiceLayer — Voice I/O for AI agents",
      },
    ],
  },
  twitter: {
    card: "summary_large_image",
    title: "VoiceLayer — Native Voice I/O for AI Coding Assistants",
    description:
      "Press F6. Speak. Ship. On-device whisper.cpp STT, edge-tts cloud TTS. Works with any MCP client.",
    creator: "@EtanHey",
    images: ["/og.png"],
  },
  icons: {
    icon: {
      url: "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 64 64'%3E%3Crect x='4' y='20' width='8' height='10' rx='3' fill='%237DD3FC'/%3E%3Crect x='4' y='34' width='8' height='10' rx='3' fill='%2338BDF8'/%3E%3Crect x='16' y='14' width='8' height='16' rx='3' fill='%237DD3FC'/%3E%3Crect x='16' y='34' width='8' height='16' rx='3' fill='%2338BDF8'/%3E%3Crect x='28' y='6' width='8' height='24' rx='3' fill='%237DD3FC'/%3E%3Crect x='28' y='34' width='8' height='24' rx='3' fill='%2338BDF8'/%3E%3Crect x='40' y='14' width='8' height='16' rx='3' fill='%237DD3FC'/%3E%3Crect x='40' y='34' width='8' height='16' rx='3' fill='%2338BDF8'/%3E%3Crect x='52' y='20' width='8' height='10' rx='3' fill='%237DD3FC'/%3E%3Crect x='52' y='34' width='8' height='10' rx='3' fill='%2338BDF8'/%3E%3C/svg%3E",
      type: "image/svg+xml",
    },
  },
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html
      lang="en"
      className={`${newsreader.variable} ${outfit.variable} ${jetbrainsMono.variable} antialiased`}
    >
      <body className="min-h-screen">{children}</body>
    </html>
  );
}
