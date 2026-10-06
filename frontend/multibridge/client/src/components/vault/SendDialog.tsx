import { useEffect, useMemo, useState } from "react";
import { isAddress, getAddress, parseEther, type Address } from "viem";
import { useAppKitAccount, useAppKitNetwork } from "@reown/appkit/react";
import { useWallet } from "@solana/wallet-adapter-react";
import { WalletMultiButton } from "@solana/wallet-adapter-react-ui";
import {
  ArrowDownToLine,
  ArrowUpFromLine,
  Loader2,
  CheckCircle2,
  XCircle,
  AlertTriangle,
  ExternalLink,
} from "lucide-react";
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogDescription } from "@/components/ui/dialog";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Badge } from "@/components/ui/badge";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { useToast } from "@/hooks/use-toast";
import { useSolanaNetwork } from "@/context/SolanaWalletProvider";
import type { AdapterContext, AdapterState, VaultInfo } from "@/lib/adapter/state";
import {
  previewVaultOutput,
  applySlippage,
  quoteCcipSend,
  executeCcipSend,
  executeSolanaCcipSend,
  quoteLzSend,
  executeLzSend,
  readSourceToken,
  resolveSourceToken,
  DEFAULT_CCIP_INBOUND_GAS,
  DEFAULT_LZ_COMPOSE_GAS,
  DEFAULT_LZ_RECEIVE_GAS,
  type Rail,
  type VaultAction,
  type SendResult,
} from "@/lib/adapter/send";
import { encodeVaultMessage } from "@/lib/adapter/message";
import { sourceBySelector, ALL_SOURCES, ccipExplorerUrl, type SourceChainInfo } from "@/lib/adapter/networks";
import { appKitNetworkById } from "@/config/web3.config";
import { lzEidForChain } from "@/config/lz.config";
import {
  findKnownAdapter,
  sourceHintsFor,
  railsForSource,
  type ReturnDestination,
  type SourceRailHints,
} from "@/config/adapters.config";
import { fmtUnits, parseAmount } from "@/lib/adapter/format";
import { addTracked } from "@/lib/adapter/tracked";
import { isInboundLzAllowed } from "@/lib/adapter/allowlist";

interface Props {
  open: boolean;
  onClose: () => void;
  ctx: AdapterContext;
  state: AdapterState;
  vault: VaultInfo;
  action: VaultAction;
}

type Phase = "form" | "sending" | "sent" | "error";

const ZERO = "0x0000000000000000000000000000000000000000";
const RAIL_LABEL: Record<Rail, string> = { ccip: "CCIP", oft: "LayerZero OFT", stargate: "Stargate" };

export function SendDialog({ open, onClose, ctx, state, vault, action }: Props) {
  const { toast } = useToast();
  const { address: evmAddress, isConnected: evmConnected } = useAppKitAccount();
  const { chainId: evmChainId, switchNetwork } = useAppKitNetwork();
  const solana = useWallet();
  const { setNetwork: setSolanaNetwork } = useSolanaNetwork();

  const entry = findKnownAdapter(ctx.adapter, ctx.hubChainId);
  const hubCcipSelector = BigInt(entry?.hubCcipSelector ?? ctx.chain.chainSelector);
  const hubLzEid = entry?.hubLzEid ?? lzEidForChain(ctx.hubChainId);

  // Source options: for each source chain configured in the registry, the rails it offers. Falls back
  // to the CCIP inbound allowlist so any adapter still supports the CCIP rail.
  const sourceOptions = useMemo(() => {
    const opts: { source: SourceChainInfo; hints?: SourceRailHints; rails: Rail[] }[] = [];
    const seen = new Set<string>();
    if (entry?.sources) {
      for (const [chainIdStr, hints] of Object.entries(entry.sources)) {
        const src = sourceBySelectorForChainId(Number(chainIdStr));
        if (!src) continue;
        opts.push({ source: src, hints, rails: railsForSource(hints) });
        seen.add(src.key);
      }
    }
    // Add CCIP inbound-allowlisted chains not already covered.
    for (const a of state.allowlists) {
      if (a.kind !== "ccipSrc" || !a.allowed) continue;
      const src = sourceBySelector(a.id);
      if (src && !seen.has(src.key)) {
        opts.push({ source: src, rails: ["ccip"] });
        seen.add(src.key);
      }
    }
    return opts;
  }, [entry, state.allowlists]);

  const [sourceKey, setSourceKey] = useState<string>("");
  const sourceOpt = useMemo(() => sourceOptions.find((o) => o.source.key === sourceKey), [sourceOptions, sourceKey]);
  const source = sourceOpt?.source;
  const availableRails = sourceOpt?.rails ?? [];

  const [rail, setRail] = useState<Rail>("ccip");
  const [sourceToken, setSourceToken] = useState("");
  const [sourceTokenMeta, setSourceTokenMeta] = useState<{ decimals: number; symbol: string } | null>(null);
  const [resolving, setResolving] = useState(false);
  const [amount, setAmount] = useState("");
  const [destIdx, setDestIdx] = useState<string>("");
  const [beneficiary, setBeneficiary] = useState("");
  const [handler, setHandler] = useState("");
  const [onlyLocalRefund, setOnlyLocalRefund] = useState(false);
  const [slippageBps, setSlippageBps] = useState(100);
  const [returnLegValueEth, setReturnLegValueEth] = useState("");
  const [advanced, setAdvanced] = useState(false);

  const [previewOut, setPreviewOut] = useState<bigint | null>(null);
  const [previewing, setPreviewing] = useState(false);
  const [previewError, setPreviewError] = useState<string | null>(null);
  const [quoteFee, setQuoteFee] = useState<bigint | null>(null);
  const [quoteLoading, setQuoteLoading] = useState(false);

  const [phase, setPhase] = useState<Phase>("form");
  const [result, setResult] = useState<SendResult | null>(null);
  const [errorMsg, setErrorMsg] = useState<string | null>(null);

  // Return destinations: the registry entry's curated list if present, otherwise every enabled on-chain
  // route (RouteSet) for the token this action produces (shares on deposit, asset on redeem).
  const destinations: ReturnDestination[] = useMemo(() => {
    if (entry?.returnDestinations?.length) return entry.returnDestinations;
    const produced = (action === "deposit" ? vault.vault : vault.asset).toLowerCase();
    return state.routes
      .filter((r) => r.enabled && r.token.toLowerCase() === produced)
      .map((r) => ({
        destination: r.destination,
        label: `${r.destinationLabel} via ${r.rail}`,
        rail: r.rail,
        recipientKind: r.rail === "CCIP_SVM" ? ("svm" as const) : ("evm" as const),
      }));
  }, [entry, action, vault.vault, vault.asset, state.routes]);
  const dest = destinations[Number(destIdx)] as ReturnDestination | undefined;

  // Hub delivered token + decimals (asset on deposit, share on redeem).
  const deliveredDecimals = action === "deposit" ? vault.underlying.decimals : vault.share.decimals;
  const outDecimals = action === "deposit" ? vault.share.decimals : vault.underlying.decimals;
  const outSymbol = action === "deposit" ? vault.share.symbol : vault.underlying.symbol;
  const hints = sourceOpt?.hints;

  // Pick a default source when options load.
  useEffect(() => {
    if (!sourceKey && sourceOptions.length) setSourceKey(sourceOptions[0].source.key);
  }, [sourceOptions, sourceKey]);

  // Keep the selected rail valid for the source.
  useEffect(() => {
    if (availableRails.length && !availableRails.includes(rail)) setRail(availableRails[0]);
  }, [availableRails]); // eslint-disable-line react-hooks/exhaustive-deps

  // Default the return destination.
  useEffect(() => {
    if (destIdx === "" && destinations.length) setDestIdx("0");
  }, [destinations, destIdx]);

  // Resolve source token when source/rail/action changes.
  useEffect(() => {
    if (!source) return;
    let cancelled = false;
    if (source.family === "SVM" && source.solanaNetwork) setSolanaNetwork(source.solanaNetwork);
    setSourceTokenMeta(null);
    setPreviewOut(null);
    setQuoteFee(null);

    // Hint by rail.
    if (rail === "ccip") {
      const hinted = action === "deposit" ? hints?.ccip?.assetToken : hints?.ccip?.shareToken;
      if (hinted) {
        setSourceToken(hinted);
        return;
      }
      // Auto-discover the CCIP counterpart via the CCT token-pool graph.
      const hubToken = action === "deposit" ? vault.asset : vault.vault;
      setSourceToken("");
      setResolving(true);
      resolveSourceToken({
        hubChain: ctx.chain,
        router: state.meta.ccipRouter,
        hubToken,
        sourceChainSelector: BigInt(source.chainSelector),
      })
        .then((tok) => {
          if (!cancelled && tok) setSourceToken(tok);
        })
        .finally(() => {
          if (!cancelled) setResolving(false);
        });
    } else if (rail === "oft") {
      setSourceToken(hints?.oft?.token ?? "");
    } else {
      setSourceToken(hints?.stargate?.token ?? "");
    }
    return () => {
      cancelled = true;
    };
  }, [source?.key, rail, action]); // eslint-disable-line react-hooks/exhaustive-deps

  // Default beneficiary to the connected wallet.
  useEffect(() => {
    if (beneficiary) return;
    if (dest?.recipientKind === "svm") {
      if (solana.publicKey) setBeneficiary(solana.publicKey.toBase58());
    } else if (evmAddress) {
      setBeneficiary(evmAddress);
    }
  }, [dest?.recipientKind, evmAddress, solana.publicKey]); // eslint-disable-line react-hooks/exhaustive-deps

  // Read source token decimals/symbol (EVM).
  useEffect(() => {
    let cancelled = false;
    if (source?.family === "EVM" && isAddress(sourceToken)) {
      readSourceToken(source, getAddress(sourceToken)).then((m) => {
        if (!cancelled) setSourceTokenMeta(m);
      });
    } else {
      setSourceTokenMeta(null);
    }
    return () => {
      cancelled = true;
    };
  }, [source?.key, sourceToken]); // eslint-disable-line react-hooks/exhaustive-deps

  const sourceDecimals = sourceTokenMeta?.decimals ?? (source?.family === "SVM" ? 9 : deliveredDecimals);
  const amountRaw = useMemo(() => parseAmount(amount, sourceDecimals), [amount, sourceDecimals]);

  // Convert source amount into hub-delivered units for the preview (assumes CCT/OFT 1:1 value).
  const deliveredAmount = useMemo(() => {
    if (amountRaw === 0n) return 0n;
    if (sourceDecimals === deliveredDecimals) return amountRaw;
    return sourceDecimals < deliveredDecimals
      ? amountRaw * 10n ** BigInt(deliveredDecimals - sourceDecimals)
      : amountRaw / 10n ** BigInt(sourceDecimals - deliveredDecimals);
  }, [amountRaw, sourceDecimals, deliveredDecimals]);

  const minimumOut = useMemo(
    () => (previewOut && previewOut > 0n ? applySlippage(previewOut, slippageBps) : 0n),
    [previewOut, slippageBps],
  );

  // Pre-send allowlist check (avoid a guaranteed capture).
  const allowlistOk = useMemo(() => {
    if (!source) return false;
    if (rail === "ccip") {
      return state.allowlists.some((a) => a.kind === "ccipSrc" && a.allowed && a.id === source.chainSelector);
    }
    if (rail === "oft" || rail === "stargate") {
      return isInboundLzAllowed({
        rail,
        source,
        hubChainId: ctx.hubChainId,
        hints,
        allowlists: state.allowlists,
        routes: state.routes,
        hubStargatePool: entry?.hubStargatePool,
      });
    }
    return false;
  }, [source, rail, hints, state.allowlists, state.routes, ctx.hubChainId, entry?.hubStargatePool]);

  const endpoint = rail === "oft" ? hints?.oft?.endpoint : rail === "stargate" ? hints?.stargate?.pool : undefined;

  const handlerAddr = (handler && isAddress(handler) ? getAddress(handler) : ZERO) as Address;

  function buildMessage() {
    if (!dest) throw new Error("Select a return destination");
    return encodeVaultMessage({
      minAmountOut: minimumOut,
      destination: BigInt(dest.destination),
      recipient: beneficiary,
      recipientKind: dest.recipientKind,
      failedMessageHandler: handlerAddr,
      // Only meaningful with a handler; the adapter ignores it for handler-less messages.
      onlyLocalRefund: onlyLocalRefund && handlerAddr !== ZERO,
    });
  }

  async function runPreview() {
    if (deliveredAmount === 0n) return;
    setPreviewing(true);
    setPreviewError(null);
    setPreviewOut(null);
    try {
      const out = await previewVaultOutput({
        hubClient: ctx.client,
        vault: vault.vault,
        isDeposit: action === "deposit",
        amount: deliveredAmount,
      });
      setPreviewOut(out);
      if (out === 0n) setPreviewError("Preview returned 0 — trade not viable.");
    } catch (e: any) {
      setPreviewError(shortError(e));
    } finally {
      setPreviewing(false);
    }
  }

  async function runQuote() {
    if (!source) return;
    setQuoteLoading(true);
    setQuoteFee(null);
    try {
      const data = buildMessage();
      if (rail === "ccip" && source.family === "EVM") {
        const q = await quoteCcipSend({
          source,
          hubCcipSelector,
          adapter: ctx.adapter,
          sourceToken: getAddress(sourceToken),
          amount: amountRaw,
          data,
          sender: getAddress(evmAddress!),
        });
        setQuoteFee(q.fee);
      } else if ((rail === "oft" || rail === "stargate") && endpoint) {
        const q = await quoteLzSend({
          source,
          endpoint: getAddress(endpoint),
          hubLzEid: hubLzEid!,
          adapter: ctx.adapter,
          sourceToken: getAddress(sourceToken),
          amount: amountRaw,
          composeMsg: data,
          returnLegValueWei: returnLegValueEth ? parseEther(returnLegValueEth as `${number}`) : 0n,
          sender: getAddress(evmAddress!),
        });
        setQuoteFee(q.nativeFee);
      }
    } catch (e: any) {
      toast({ title: "Quote failed", description: shortError(e), variant: "destructive" });
    } finally {
      setQuoteLoading(false);
    }
  }

  const checks = useMemo(() => {
    const list: { ok: boolean; label: string }[] = [];
    list.push({ ok: !!source, label: "Source chain selected" });
    list.push({ ok: availableRails.includes(rail), label: `${RAIL_LABEL[rail]} available from source` });
    list.push({ ok: allowlistOk, label: "Source allowlisted on adapter (inbound)" });
    if (rail === "ccip") {
      list.push({ ok: source?.family === "SVM" ? !!sourceToken : isAddress(sourceToken), label: "Source token set" });
      if (source?.family === "EVM") {
        list.push({ ok: evmConnected && Number(evmChainId) === source.evmChainId, label: `Wallet on ${source?.label}` });
      } else {
        list.push({ ok: !!solana.publicKey, label: "Solana wallet connected" });
      }
    } else {
      list.push({ ok: !!endpoint, label: `${RAIL_LABEL[rail]} endpoint configured` });
      list.push({ ok: isAddress(sourceToken), label: "Source token set" });
      list.push({ ok: evmConnected && Number(evmChainId) === source?.evmChainId, label: `Wallet on ${source?.label}` });
    }
    list.push({ ok: amountRaw > 0n, label: "Amount greater than zero" });
    list.push({ ok: !!dest, label: "Return destination selected" });
    list.push({ ok: !!beneficiary, label: "Beneficiary set" });
    list.push({ ok: !!previewOut && previewOut > 0n, label: "Preview output viable" });
    return list;
  }, [source, rail, availableRails, allowlistOk, sourceToken, evmConnected, evmChainId, solana.publicKey, amountRaw, dest, beneficiary, previewOut, endpoint]);

  const allChecksPass = checks.every((c) => c.ok);

  async function send() {
    if (!source || !dest) return;
    setPhase("sending");
    setErrorMsg(null);
    try {
      const data = buildMessage();
      let res: SendResult;
      if (rail === "ccip" && source.family === "EVM") {
        res = await executeCcipSend({
          source,
          hubCcipSelector,
          adapter: ctx.adapter,
          sourceToken: getAddress(sourceToken),
          amount: amountRaw,
          data,
          sender: getAddress(evmAddress!),
        });
      } else if (rail === "ccip" && source.family === "SVM") {
        if (!solana.publicKey || !solana.signTransaction) throw new Error("Connect a Solana wallet");
        res = await executeSolanaCcipSend({
          source,
          hubCcipSelector,
          adapter: ctx.adapter,
          sourceToken,
          amount: amountRaw,
          data,
          solana: { publicKey: solana.publicKey, signTransaction: solana.signTransaction },
        });
      } else {
        if (!endpoint) throw new Error(`No ${RAIL_LABEL[rail]} endpoint configured for this source`);
        res = await executeLzSend({
          source,
          endpoint: getAddress(endpoint),
          hubLzEid: hubLzEid!,
          adapter: ctx.adapter,
          sourceToken: getAddress(sourceToken),
          amount: amountRaw,
          composeMsg: data,
          returnLegValueWei: returnLegValueEth ? parseEther(returnLegValueEth as `${number}`) : 0n,
          sender: getAddress(evmAddress!),
        });
      }
      setResult(res);
      setPhase("sent");
      addTracked({
        messageId: res.messageId,
        txHash: res.txHash,
        rail,
        action,
        adapter: ctx.adapter,
        hubChainId: ctx.hubChainId,
        sourceKey: source.key,
        sourceLabel: source.label,
        vaultLabel: vault.share.symbol,
        amount,
        tokenSymbol: sourceTokenMeta?.symbol ?? (source.family === "SVM" ? "SPL" : "TOKEN"),
        destinationLabel: dest.label,
        timestamp: Date.now(),
      });
      toast({ title: "Message sent", description: `${res.messageId.slice(0, 10)}…` });
    } catch (e: any) {
      setErrorMsg(shortError(e));
      setPhase("error");
    }
  }

  function switchToEvm(chainId: number, label: string) {
    const net = appKitNetworkById(chainId);
    if (!net) {
      toast({ title: "Network not registered", description: `${label} (chain ${chainId}) not in wallet list.`, variant: "destructive" });
      return;
    }
    switchNetwork?.(net);
  }

  function resetAndClose() {
    setPhase("form");
    setResult(null);
    setErrorMsg(null);
    onClose();
  }

  const Icon = action === "deposit" ? ArrowDownToLine : ArrowUpFromLine;
  const nativeSym = source?.nativeCurrency?.symbol ?? "native";

  return (
    <Dialog open={open} onOpenChange={(o) => !o && resetAndClose()}>
      <DialogContent className="max-w-lg max-h-[90vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle className="flex items-center gap-2 capitalize">
            <Icon className="w-5 h-5 text-primary" /> {action} · {vault.share.symbol}
          </DialogTitle>
          <DialogDescription>
            {action === "deposit"
              ? `Bridge ${vault.underlying.symbol} to the adapter → it deposits into the vault → the produced ${vault.share.symbol} is delivered to your chosen return destination.`
              : `Bridge ${vault.share.symbol} shares to the adapter → it redeems → the produced ${vault.underlying.symbol} is delivered to your chosen return destination.`}
          </DialogDescription>
        </DialogHeader>

        {phase === "sent" && result ? (
          <SentView result={result} rail={rail} onClose={resetAndClose} />
        ) : phase === "error" ? (
          <ErrorView message={errorMsg!} onRetry={() => setPhase("form")} />
        ) : (
          <div className="space-y-4">
            {/* Source chain */}
            <div className="space-y-2">
              <Label>Source chain</Label>
              {sourceOptions.length === 0 ? (
                <div className="rounded-md border border-amber-500/40 bg-amber-500/10 px-3 py-2 text-xs text-amber-600 dark:text-amber-400">
                  No inbound sources are configured for this adapter yet.
                </div>
              ) : (
                <Select value={sourceKey} onValueChange={setSourceKey}>
                  <SelectTrigger data-testid="select-source-chain">
                    <SelectValue placeholder="Select source chain" />
                  </SelectTrigger>
                  <SelectContent>
                    {sourceOptions.map(({ source: s, rails }) => (
                      <SelectItem key={s.key} value={s.key}>
                        {s.label} <span className="text-muted-foreground text-xs">({rails.map((r) => RAIL_LABEL[r]).join(", ")})</span>
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              )}
            </div>

            {/* Rail selector */}
            <div className="space-y-2">
              <Label>Bridge rail (source → adapter)</Label>
              <div className="grid grid-cols-3 gap-2">
                {(["ccip", "oft", "stargate"] as Rail[]).map((r) => {
                  const enabled = availableRails.includes(r);
                  return (
                    <Button
                      key={r}
                      type="button"
                      variant={rail === r ? "default" : "outline"}
                      disabled={!enabled}
                      onClick={() => setRail(r)}
                      data-testid={`rail-${r}`}
                      className="text-xs"
                    >
                      {RAIL_LABEL[r]}
                    </Button>
                  );
                })}
              </div>
            </div>

            {/* Source token */}
            <div className="space-y-2">
              <div className="flex items-center justify-between">
                <Label>Source token ({action === "deposit" ? "vault asset" : "vault share"} on source)</Label>
                {resolving && (
                  <span className="text-[11px] text-muted-foreground inline-flex items-center gap-1">
                    <Loader2 className="w-3 h-3 animate-spin" /> detecting…
                  </span>
                )}
              </div>
              <Input
                data-testid="input-source-token"
                placeholder={source?.family === "SVM" ? "SPL mint address" : "0x..."}
                value={sourceToken}
                spellCheck={false}
                className="font-mono"
                onChange={(e) => setSourceToken(e.target.value.trim())}
              />
              {sourceTokenMeta && (
                <p className="text-xs text-muted-foreground">
                  {sourceTokenMeta.symbol} · {sourceTokenMeta.decimals} decimals
                </p>
              )}
              {endpoint && (
                <p className="text-[11px] text-muted-foreground font-mono">
                  {RAIL_LABEL[rail]} endpoint: {endpoint}
                </p>
              )}
            </div>

            {/* Amount */}
            <div className="space-y-2">
              <Label>Amount</Label>
              <Input
                data-testid="input-amount"
                placeholder="0.0"
                value={amount}
                inputMode="decimal"
                onChange={(e) => {
                  setAmount(e.target.value);
                  setPreviewOut(null);
                  setQuoteFee(null);
                }}
              />
            </div>

            {/* Return destination */}
            <div className="space-y-2">
              <Label>Return destination (where the produced token is delivered)</Label>
              {destinations.length === 0 ? (
                <div className="rounded-md border border-amber-500/40 bg-amber-500/10 px-3 py-2 text-xs text-amber-600 dark:text-amber-400">
                  No return destinations: the adapter has no enabled route for this token and the registry has no entry for it.
                </div>
              ) : (
                <Select value={destIdx} onValueChange={(v) => { setDestIdx(v); setBeneficiary(""); }}>
                  <SelectTrigger data-testid="select-destination">
                    <SelectValue placeholder="Select return destination" />
                  </SelectTrigger>
                  <SelectContent>
                    {destinations.map((d, i) => (
                      <SelectItem key={i} value={String(i)}>
                        {d.label} <span className="text-muted-foreground text-xs">({d.rail})</span>
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              )}
            </div>

            {/* Beneficiary */}
            <div className="space-y-2">
              <Label>Beneficiary {dest?.recipientKind === "svm" ? "(Solana)" : "(EVM)"}</Label>
              <Input
                data-testid="input-beneficiary"
                placeholder={dest?.recipientKind === "svm" ? "Solana address" : "0x..."}
                value={beneficiary}
                spellCheck={false}
                className="font-mono"
                onChange={(e) => setBeneficiary(e.target.value.trim())}
              />
            </div>

            {/* Advanced */}
            <button type="button" className="text-xs text-primary" onClick={() => setAdvanced((v) => !v)}>
              {advanced ? "Hide" : "Show"} advanced
            </button>
            {advanced && (
              <div className="space-y-3 rounded-md border border-border p-3">
                <div className="grid grid-cols-2 gap-3">
                  <div className="space-y-1">
                    <Label className="text-xs">Slippage (bps)</Label>
                    <Input type="number" value={slippageBps} onChange={(e) => setSlippageBps(Number(e.target.value) || 0)} data-testid="input-slippage" />
                  </div>
                  {(rail === "oft" || rail === "stargate") && (
                    <div className="space-y-1">
                      <Label className="text-xs">Return-leg prefund ({nativeSym})</Label>
                      <Input
                        type="text"
                        inputMode="decimal"
                        placeholder={state.policy.requireLzReturnPrefunded ? "required for bridged return" : "0.0"}
                        value={returnLegValueEth}
                        onChange={(e) => setReturnLegValueEth(e.target.value)}
                        data-testid="input-return-prefund"
                      />
                    </div>
                  )}
                </div>
                <div className="space-y-1">
                  <Label className="text-xs">Failed-message handler (optional, hub EVM)</Label>
                  <Input placeholder="0x… (enables retry / refund-local)" value={handler} className="font-mono" onChange={(e) => setHandler(e.target.value.trim())} data-testid="input-handler" />
                </div>
                <label className="flex items-start gap-2 text-xs">
                  <input
                    type="checkbox"
                    className="mt-0.5"
                    checked={onlyLocalRefund}
                    disabled={handlerAddr === ZERO}
                    onChange={(e) => setOnlyLocalRefund(e.target.checked)}
                    data-testid="input-only-local-refund"
                  />
                  <span className="text-muted-foreground">
                    Local refund only: on failure, disable the permissionless bounce-to-source and leave recovery
                    (retry / refund-local) to the handler. Requires a handler.
                  </span>
                </label>
                <p className="text-[11px] text-muted-foreground">
                  Gas defaults: CCIP inbound {DEFAULT_CCIP_INBOUND_GAS.toLocaleString()}, LZ compose{" "}
                  {Number(DEFAULT_LZ_COMPOSE_GAS).toLocaleString()}, LZ receive {Number(DEFAULT_LZ_RECEIVE_GAS).toLocaleString()}.
                </p>
              </div>
            )}

            {/* Allowlist warning */}
            {source && !allowlistOk && (
              <div className="rounded-md border border-amber-500/40 bg-amber-500/10 px-3 py-2 text-xs text-amber-600 dark:text-amber-400 flex items-start gap-2">
                <AlertTriangle className="w-3.5 h-3.5 mt-0.5 shrink-0" />
                This source/rail is not inbound-allowlisted on the adapter. A send would be captured as a failed
                message on the hub (recoverable). Verify the adapter config before sending.
              </div>
            )}

            {/* Preview */}
            <div className="rounded-md border border-border p-3 space-y-2">
              <div className="flex items-center justify-between">
                <span className="text-sm font-medium">Preview</span>
                <Button size="sm" variant="outline" onClick={runPreview} disabled={previewing || deliveredAmount === 0n} data-testid="button-preview">
                  {previewing ? <Loader2 className="w-3.5 h-3.5 animate-spin" /> : "Preview output"}
                </Button>
              </div>
              {previewOut !== null && previewOut > 0n && (
                <div className="text-sm space-y-1">
                  <div className="flex justify-between">
                    <span className="text-muted-foreground">Estimated output</span>
                    <span className="font-mono">{fmtUnits(previewOut, outDecimals)} {outSymbol}</span>
                  </div>
                  <div className="flex justify-between">
                    <span className="text-muted-foreground">Minimum out ({slippageBps} bps)</span>
                    <span className="font-mono">{fmtUnits(minimumOut, outDecimals)} {outSymbol}</span>
                  </div>
                </div>
              )}
              {previewError && (
                <p className="text-xs text-destructive flex items-center gap-1">
                  <AlertTriangle className="w-3.5 h-3.5" /> {previewError}
                </p>
              )}
            </div>

            {/* Fee quote */}
            {quoteFee !== null && (
              <div className="rounded-md border border-border p-3 text-sm flex justify-between">
                <span className="text-muted-foreground">{RAIL_LABEL[rail]} native fee</span>
                <span className="font-mono">{fmtUnits(quoteFee, 18)} {nativeSym}</span>
              </div>
            )}

            {/* Validation checklist */}
            <div className="space-y-1.5">
              {checks.map((c, i) => (
                <div key={i} className="flex items-center gap-2 text-xs">
                  {c.ok ? (
                    <CheckCircle2 className="w-3.5 h-3.5 text-green-500 shrink-0" />
                  ) : (
                    <XCircle className="w-3.5 h-3.5 text-muted-foreground/50 shrink-0" />
                  )}
                  <span className={c.ok ? "text-foreground" : "text-muted-foreground"}>{c.label}</span>
                </div>
              ))}
            </div>

            {/* Wallet actions */}
            {source?.family === "EVM" && evmConnected && Number(evmChainId) !== source.evmChainId && (
              <Button variant="outline" className="w-full" onClick={() => switchToEvm(source.evmChainId!, source.label)} data-testid="button-switch-network">
                Switch wallet to {source.label}
              </Button>
            )}
            {rail === "ccip" && source?.family === "SVM" && !solana.publicKey && (
              <div className="flex justify-center"><WalletMultiButton /></div>
            )}

            <div className="flex gap-2">
              {source?.family === "EVM" && (
                <Button variant="outline" className="flex-1" onClick={runQuote} disabled={!allChecksPass || quoteLoading} data-testid="button-quote">
                  {quoteLoading ? <Loader2 className="w-4 h-4 animate-spin" /> : "Quote fee"}
                </Button>
              )}
              <Button className="flex-1" onClick={send} disabled={!allChecksPass || phase === "sending"} data-testid="button-send">
                {phase === "sending" ? (
                  <><Loader2 className="w-4 h-4 mr-2 animate-spin" /> Sending...</>
                ) : (
                  <>Send {action}</>
                )}
              </Button>
            </div>
          </div>
        )}
      </DialogContent>
    </Dialog>
  );
}

/** Resolve a SourceChainInfo for an EVM chain id. */
function sourceBySelectorForChainId(chainId: number): SourceChainInfo | undefined {
  return ALL_SOURCES.find((s) => s.evmChainId === chainId);
}

function SentView({ result, rail, onClose }: { result: SendResult; rail: Rail; onClose: () => void }) {
  const href =
    rail === "ccip" ? ccipExplorerUrl(result.messageId) : `https://testnet.layerzeroscan.com/tx/${result.txHash}`;
  return (
    <div className="space-y-4 py-2">
      <div className="flex flex-col items-center text-center gap-2">
        <CheckCircle2 className="w-12 h-12 text-green-500" />
        <p className="font-medium">Message submitted</p>
        <p className="text-sm text-muted-foreground">Track transport + on-chain outcome in the Messages tab.</p>
      </div>
      <div className="rounded-md border border-border p-3 space-y-2 text-xs">
        <div>
          <p className="text-muted-foreground">{rail === "ccip" ? "Message ID" : "GUID"}</p>
          <p className="font-mono break-all">{result.messageId}</p>
        </div>
        <div>
          <p className="text-muted-foreground">Source tx</p>
          <p className="font-mono break-all">{result.txHash}</p>
        </div>
      </div>
      <a href={href} target="_blank" rel="noreferrer">
        <Button variant="outline" className="w-full">
          View on {rail === "ccip" ? "CCIP" : "LayerZero"} Explorer <ExternalLink className="w-4 h-4 ml-2" />
        </Button>
      </a>
      <Button className="w-full" onClick={onClose}>Done</Button>
    </div>
  );
}

function ErrorView({ message, onRetry }: { message: string; onRetry: () => void }) {
  return (
    <div className="space-y-4 py-2">
      <div className="flex flex-col items-center text-center gap-2">
        <XCircle className="w-12 h-12 text-destructive" />
        <p className="font-medium">Send failed</p>
        <p className="text-sm text-muted-foreground break-words">{message}</p>
      </div>
      <Button className="w-full" onClick={onRetry}>Back to form</Button>
    </div>
  );
}

function shortError(e: any): string {
  const msg = e?.shortMessage || e?.details || e?.message || String(e);
  return msg.length > 240 ? msg.slice(0, 240) + "…" : msg;
}
