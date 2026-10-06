import { formatUnits } from "viem";

export function shortAddr(address?: string, head = 6, tail = 4): string {
  if (!address) return "";
  if (address.length <= head + tail + 2) return address;
  return `${address.slice(0, head)}...${address.slice(-tail)}`;
}

export function fmtUnits(value: bigint, decimals: number, maxFrac = 6): string {
  const s = formatUnits(value, decimals);
  if (!s.includes(".")) return s;
  const [whole, frac] = s.split(".");
  const trimmed = frac.slice(0, maxFrac).replace(/0+$/, "");
  return trimmed ? `${whole}.${trimmed}` : whole;
}

export function fmtCompact(value: bigint, decimals: number): string {
  const num = Number(formatUnits(value, decimals));
  if (!isFinite(num)) return "0";
  if (num === 0) return "0";
  if (num < 0.0001) return "<0.0001";
  if (num >= 1_000_000) return `${(num / 1_000_000).toFixed(2)}M`;
  if (num >= 1_000) return `${(num / 1_000).toFixed(2)}K`;
  return num.toLocaleString(undefined, { maximumFractionDigits: 4 });
}

export function parseAmount(input: string, decimals: number): bigint {
  if (!input || isNaN(Number(input))) return 0n;
  const [whole, frac = ""] = input.split(".");
  const fracPadded = (frac + "0".repeat(decimals)).slice(0, decimals);
  const combined = `${whole}${fracPadded}`.replace(/^0+/, "") || "0";
  return BigInt(combined);
}

export function relativeTime(ts: number): string {
  const diff = Date.now() - ts;
  const s = Math.floor(diff / 1000);
  if (s < 60) return `${s}s ago`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m ago`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}h ago`;
  return `${Math.floor(h / 24)}d ago`;
}
