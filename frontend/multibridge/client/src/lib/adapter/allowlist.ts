import type { Address } from "viem";
import { lzEidForChain } from "@/config/lz.config";
import type { SourceRailHints } from "@/config/adapters.config";
import type { AllowlistEntry, RouteRow } from "@/lib/adapter/state";
import type { SourceChainInfo } from "@/lib/adapter/networks";
import type { Rail } from "@/lib/adapter/send";

/**
 * Resolve the hub-local OFT/pool address used in `s_lzOftAllowed` checks.
 *
 * Inbound LayerZero compose is gated by `(srcEid, lzCompose._from)` where `_from` is the **hub-local**
 * pool/OFT that credits tokens on delivery — not the spoke endpoint the user calls `send()` on.
 */
export function inboundLzOftAddress(args: {
  rail: Extract<Rail, "oft" | "stargate">;
  source: SourceChainInfo;
  hubChainId: number;
  hints?: SourceRailHints;
  allowlists: AllowlistEntry[];
  routes: RouteRow[];
  hubStargatePool?: Address;
}): Address | undefined {
  const eid = args.source.evmChainId ? lzEidForChain(args.source.evmChainId) : undefined;
  if (!eid) return undefined;

  // Hub-local origination: the spoke endpoint is the same chain as the adapter.
  if (args.source.evmChainId === args.hubChainId) {
    return args.rail === "oft" ? args.hints?.oft?.endpoint : args.hints?.stargate?.pool;
  }

  // Remote origination: look up the hub-side pool/OFT from outbound Stargate routes or allowlist events.
  if (args.rail === "stargate") {
    const hubPool =
      args.routes.find(
        (r) =>
          r.rail === "STARGATE" &&
          r.enabled &&
          r.endpoint &&
          r.endpoint !== "0x0000000000000000000000000000000000000000",
      )?.endpoint ?? args.hubStargatePool;
    if (hubPool) return hubPool;
  }

  const allowed = args.allowlists.filter(
    (a) => a.kind === "lzOft" && a.allowed && a.id === String(eid) && a.oft,
  );
  if (allowed.length === 1) return allowed[0].oft;
  return allowed[0]?.oft;
}

/** Whether the adapter allowlists inbound messages for this source chain + LZ rail. */
export function isInboundLzAllowed(args: {
  rail: Extract<Rail, "oft" | "stargate">;
  source: SourceChainInfo;
  hubChainId: number;
  hints?: SourceRailHints;
  allowlists: AllowlistEntry[];
  routes: RouteRow[];
  hubStargatePool?: Address;
}): boolean {
  const eid = args.source.evmChainId ? lzEidForChain(args.source.evmChainId) : undefined;
  if (!eid) return false;

  const inboundOft = inboundLzOftAddress(args);
  if (inboundOft) {
    return args.allowlists.some(
      (a) =>
        a.kind === "lzOft" &&
        a.allowed &&
        a.id === String(eid) &&
        a.oft?.toLowerCase() === inboundOft.toLowerCase(),
    );
  }

  // Fallback when hub-side pool isn't discoverable yet: any allowlisted OFT for this srcEid.
  return args.allowlists.some((a) => a.kind === "lzOft" && a.allowed && a.id === String(eid));
}
