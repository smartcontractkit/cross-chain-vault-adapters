import { useState } from "react";
import { Check, Copy, ExternalLink } from "lucide-react";
import { cn } from "@/lib/utils";
import { shortAddr } from "@/lib/adapter/format";

export function CopyButton({ value, className }: { value: string; className?: string }) {
  const [copied, setCopied] = useState(false);
  return (
    <button
      type="button"
      className={cn("text-muted-foreground hover:text-foreground transition-colors", className)}
      onClick={(e) => {
        e.stopPropagation();
        navigator.clipboard.writeText(value);
        setCopied(true);
        setTimeout(() => setCopied(false), 1200);
      }}
      aria-label="Copy"
    >
      {copied ? <Check className="w-3.5 h-3.5 text-green-500" /> : <Copy className="w-3.5 h-3.5" />}
    </button>
  );
}

export function AddressChip({
  address,
  explorerUrl,
  full,
  mono = true,
}: {
  address: string;
  explorerUrl?: string;
  full?: boolean;
  mono?: boolean;
}) {
  return (
    <span className="inline-flex items-center gap-1.5">
      <span className={cn("text-sm", mono && "font-mono")}>
        {full ? address : shortAddr(address)}
      </span>
      <CopyButton value={address} />
      {explorerUrl && (
        <a
          href={`${explorerUrl}/address/${address}`}
          target="_blank"
          rel="noreferrer"
          className="text-muted-foreground hover:text-foreground"
        >
          <ExternalLink className="w-3.5 h-3.5" />
        </a>
      )}
    </span>
  );
}

export function StatPill({
  label,
  on,
  onText = "Enabled",
  offText = "Disabled",
}: {
  label: string;
  on: boolean;
  onText?: string;
  offText?: string;
}) {
  return (
    <div className="flex items-center gap-2 rounded-md border border-border bg-card px-3 py-1.5">
      <span className={cn("w-2 h-2 rounded-full", on ? "bg-green-500" : "bg-muted-foreground/40")} />
      <span className="text-xs text-muted-foreground">{label}</span>
      <span className={cn("text-xs font-medium", on ? "text-green-500" : "text-muted-foreground")}>
        {on ? onText : offText}
      </span>
    </div>
  );
}

export function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="space-y-1">
      <p className="text-[11px] uppercase tracking-wide text-muted-foreground">{label}</p>
      <div className="text-sm">{children}</div>
    </div>
  );
}

export function EmptyState({ children }: { children: React.ReactNode }) {
  return (
    <div className="rounded-lg border border-dashed border-border py-10 text-center text-sm text-muted-foreground">
      {children}
    </div>
  );
}
