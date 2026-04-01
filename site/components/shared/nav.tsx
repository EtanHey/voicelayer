"use client";

import { useState, useEffect } from "react";

type Product = "voicelayer" | "brainlayer" | "cmuxlayer";

const PRODUCTS: Record<Product, { name: string; color: string; url: string }> =
  {
    voicelayer: {
      name: "VoiceLayer",
      color: "#38BDF8",
      url: "https://voicelayer.etanheyman.com",
    },
    brainlayer: {
      name: "BrainLayer",
      color: "#d4956a",
      url: "https://brainlayer.etanheyman.com",
    },
    cmuxlayer: {
      name: "cmuxLayer",
      color: "#22c55e",
      url: "https://cmuxlayer.etanheyman.com",
    },
  };

interface NavProps {
  product: Product;
  links: { label: string; href: string }[];
  githubUrl: string;
}

export function Nav({ product, links, githubUrl }: NavProps) {
  const [scrolled, setScrolled] = useState(false);

  useEffect(() => {
    const onScroll = () => setScrolled(window.scrollY > 20);
    window.addEventListener("scroll", onScroll, { passive: true });
    return () => window.removeEventListener("scroll", onScroll);
  }, []);

  const current = PRODUCTS[product];

  return (
    <nav
      className={`fixed top-0 left-0 right-0 z-50 px-0 py-4 backdrop-blur-2xl transition-[border-color] duration-300 ${
        scrolled ? "border-b border-border" : "border-b border-transparent"
      }`}
      style={{ background: "rgba(9, 9, 11, 0.8)" }}
    >
      <div className="mx-auto max-w-[960px] px-6 flex items-center justify-between">
        <a
          href="#"
          className="flex items-center gap-2.5 no-underline text-text font-sans font-semibold text-base tracking-tight opacity-90 hover:opacity-100 transition-opacity"
        >
          <VoiceLayerLogo />
          {current.name}
        </a>
        <div className="flex items-center gap-6">
          {links.map((link) => (
            <a
              key={link.href}
              href={link.href}
              className="text-text-secondary no-underline text-sm hover:text-text transition-colors hidden md:inline"
            >
              {link.label}
            </a>
          ))}
          <a
            href={githubUrl}
            className="inline-flex items-center gap-1.5 text-text-secondary no-underline text-sm hover:text-text transition-colors"
          >
            GitHub{" "}
            <span className="inline-block transition-transform group-hover:translate-x-0.5">
              {"\u2197"}
            </span>
          </a>
        </div>
      </div>
    </nav>
  );
}

function VoiceLayerLogo() {
  return (
    <svg viewBox="0 0 64 64" fill="none" className="w-6 h-6 shrink-0">
      <rect x="4" y="20" width="8" height="10" rx="3" fill="#7DD3FC" />
      <rect x="4" y="34" width="8" height="10" rx="3" fill="#38BDF8" />
      <rect x="16" y="14" width="8" height="16" rx="3" fill="#7DD3FC" />
      <rect x="16" y="34" width="8" height="16" rx="3" fill="#38BDF8" />
      <rect x="28" y="6" width="8" height="24" rx="3" fill="#7DD3FC" />
      <rect x="28" y="34" width="8" height="24" rx="3" fill="#38BDF8" />
      <rect x="40" y="14" width="8" height="16" rx="3" fill="#7DD3FC" />
      <rect x="40" y="34" width="8" height="16" rx="3" fill="#38BDF8" />
      <rect x="52" y="20" width="8" height="10" rx="3" fill="#7DD3FC" />
      <rect x="52" y="34" width="8" height="10" rx="3" fill="#38BDF8" />
    </svg>
  );
}
