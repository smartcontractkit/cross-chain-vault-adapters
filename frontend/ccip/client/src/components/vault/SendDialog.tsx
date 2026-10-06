import { useEffect, useMemo, useState } from "react";
import { isAddress, getAddress, type Address } from "viem";
import { useAppKitAccount, useAppKitNetwork } from "@reown/appkit/react";
import { useWallet, useConnection } from "@solana/wallet-adapter-react";
import { WalletMultiButton } from "@solana/wallet-adapter-react-ui";
import { SolanaChain } from "@chainlink/ccip-sdk";
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
import { Switch } from "@/components/ui/switch";
import { Badge } from "@/components/ui/badge";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { useToast } from "@/hooks/use-toast";
import { useSolanaNetwork } from "@/context/SolanaWalletProvider";
import type { AdapterContext, AdapterState, VaultInfo } from "@/lib/adapter/state";
import type { VaultAction } from "@/lib/adapter/send";
import {
  previewOutput,
  applySlippage,
  quoteEvmSend,
  executeEvmSend,
  readSourceToken,
  resolveSourceToken,
  DEFAULT_DEST_GAS_LIMIT,
  type SendQuote,
} from "@/lib/adapter/send";
import { encodePayload } from "@/lib/adapter/payload";
import { sourceBySelector, ccipExplorerUrl, type SourceChainInfo } from "@/lib/adapter/networks";
import { appKitNetworkById } from "@/config/web3.config";
import { vaultHintFor, findKnownAdapter } from "@/config/adapters.config";
import { fmtUnits, parseAmount } from "@/lib/adapter/format";
import { addTracked } from "@/lib/adapter/tracked";

interface Props {
  open: boolean;
  onClose: () => void;
  ctx: AdapterContext;
  state: AdapterState;
  vault: VaultInfo;
  action: VaultAction;
}

type Phase = "form" | "sending" | "sent" | "error";

export function SendDialog({ open, onClose, ctx, state, vault, action }: Props) {
  const { toast } = useToast();
  const { address: evmAddress, isConnected: evmConnected } = useAppKitAccount();
  const { chainId: evmChainId, switchNetwork } = useAppKitNetwork();
  const solana = useWallet();
  const { connection } = useConnection();
  const { setNetwork: setSolanaNetwork } = useSolanaNetwork();

  // Only source chains the adapter has configured non-NONE can deliver inbound.
  const sourceOptions = useMemo(() => {
    return state.chains
      .filter((c) => c.type === "EVM" || c.type === "SVM")
      .map((c) => ({ chain: c, source: sourceBySelector(c.selector) }))
      .filter((x): x is { chain: typeof x.chain; source: SourceChainInfo } => !!x.source);
  }, [state.chains]);

  const [sourceKey, setSourceKey] = useState<string>("");
  const source = useMemo(
    () => sourceOptions.find((o) => o.source.key === sourceKey)?.source,
    [sourceOptions, sourceKey],
  );

  const [sourceToken, setSourceToken] = useState("");
  const [sourceTokenMeta, setSourceTokenMeta] = useState<{ decimals: number; symbol: string } | null>(null);
  const [resolving, setResolving] = useState(false);
  const [autoDetected, setAutoDetected] = useState(false);
  const [resolveFailed, setResolveFailed] = useState(false);
  const [amount, setAmount] = useState("");
  const [returnToSource, setReturnToSource] = useState(true);
  const [beneficiary, setBeneficiary] = useState("");
  const [localRefund, setLocalRefund] = useState("");
  const [slippageBps, setSlippageBps] = useState(100);
  const [gasOverride, setGasOverride] = useState("");

  const [previewOut, setPreviewOut] = useState<bigint | null>(null);
  const [previewing, setPreviewing] = useState(false);
  const [previewError, setPreviewError] = useState<string | null>(null);
  const [quote, setQuote] = useState<SendQuote | null>(null);

  const [phase, setPhase] = useState<Phase>("form");
  const [result, setResult] = useState<{ txHash: string; messageId: string } | null>(null);
  const [errorMsg, setErrorMsg] = useState<string | null>(null);

  const known = findKnownAdapter(ctx.adapter, ctx.hubChainId);

  // The token delivered ON the hub for this path, and its decimals.
  const deliveredToken: Address = action === "deposit" ? vault.underlying.address : vault.target;
  const deliveredDecimals = action === "deposit" ? vault.underlying.decimals : vault.share.decimals;
  const outDecimals = action === "deposit" ? vault.share.decimals : vault.underlying.decimals;
  const outSymbol = action === "deposit" ? vault.share.symbol : vault.underlying.symbol;

  // Pick a default source when options load.
  useEffect(() => {
    if (!sourceKey && sourceOptions.length) setSourceKey(sourceOptions[0].source.key);
  }, [sourceOptions, sourceKey]);

  // When source changes: sync Solana network, then resolve the source token —
  // registry hint first, otherwise auto-discover the CCIP counterpart on the source
  // chain from the hub token's token pool.
  useEffect(() => {
    if (!source) return;
    let cancelled = false;
    if (source.family === "SVM" && source.solanaNetwork) setSolanaNetwork(source.solanaNetwork);

    setSourceTokenMeta(null);
    setPreviewOut(null);
    setQuote(null);
    setAutoDetected(false);
    setResolveFailed(false);

    const hint = vaultHintFor(known, vault.target);
    const hinted = hint?.sourceTokens?.[source.chainSelector];
    const prefill = action === "deposit" ? hinted?.assetToken : hinted?.shareToken;
    if (prefill) {
      setSourceToken(prefill);
      return;
    }

    // No hint → discover the source-chain counterpart via the CCT token-pool graph.
    setSourceToken("");
    setResolving(true);
    resolveSourceToken({
      hubChain: ctx.chain,
      router: state.meta.router,
      hubToken: deliveredToken,
      sourceChainSelector: BigInt(source.chainSelector),
    })
      .then((tok) => {
        if (cancelled) return;
        if (tok) {
          setSourceToken(tok);
          setAutoDetected(true);
        } else {
          setResolveFailed(true);
        }
      })
      .finally(() => {
        if (!cancelled) setResolving(false);
      });

    return () => {
      cancelled = true;
    };
  }, [source?.key]); // eslint-disable-line react-hooks/exhaustive-deps

  // Default beneficiary to the connected wallet.
  useEffect(() => {
    if (beneficiary) return;
    if (returnToSource && source?.family === "SVM") {
      if (solana.publicKey) setBeneficiary(solana.publicKey.toBase58());
    } else if (evmAddress) {
      setBeneficiary(evmAddress);
    }
  }, [returnToSource, source?.family, evmAddress, solana.publicKey]); // eslint-disable-line react-hooks/exhaustive-deps

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

  // Convert source amount into hub-delivered units for the preview (assumes CCT 1:1 value).
  const deliveredAmount = useMemo(() => {
    if (amountRaw === 0n) return 0n;
    if (sourceDecimals === deliveredDecimals) return amountRaw;
    return sourceDecimals < deliveredDecimals
      ? amountRaw * 10n ** BigInt(deliveredDecimals - sourceDecimals)
      : amountRaw / 10n ** BigInt(sourceDecimals - deliveredDecimals);
  }, [amountRaw, sourceDecimals, deliveredDecimals]);

  const beneficiaryType = returnToSource && source?.family === "SVM" ? "svm" : "evm";

  const minimumOut = useMemo(
    () => (previewOut && previewOut > 0n ? applySlippage(previewOut, slippageBps) : 0n),
    [previewOut, slippageBps],
  );

  // ---- Preview ----
  async function runPreview() {
    if (!source || deliveredAmount === 0n) return;
    setPreviewing(true);
    setPreviewError(null);
    setPreviewOut(null);
    setQuote(null);
    try {
      const out = await previewOutput({
        hubClient: ctx.client,
        adapter: ctx.adapter,
        deliveredToken,
        target: vault.target,
        deliveredAmount,
        returnToSourceChain: returnToSource,
        sourceChainSelector: BigInt(source.chainSelector),
      });
      setPreviewOut(out);
      if (out === 0n) setPreviewError("Preview returned 0 — trade is not viable (fee may exceed amount).");
    } catch (e: any) {
      setPreviewError(shortError(e));
    } finally {
      setPreviewing(false);
    }
  }

  // ---- Validation checklist ----
  const checks = useMemo(() => {
    const list: { ok: boolean; label: string }[] = [];
    list.push({ ok: vault.enabled, label: "Vault target is enabled" });
    list.push({
      ok: action === "deposit" ? state.processing.depositsEnabled : state.processing.redeemsEnabled,
      label: `${action === "deposit" ? "Deposits" : "Redeems"} enabled on adapter`,
    });
    list.push({ ok: !!source, label: "Source chain configured inbound (non-NONE)" });
    if (source?.family === "EVM") {
      list.push({ ok: isAddress(sourceToken), label: "Valid source token address" });
      list.push({ ok: evmConnected, label: "EVM wallet connected" });
      list.push({
        ok: evmConnected && Number(evmChainId) === source.evmChainId,
        label: `Wallet on ${source.label}`,
      });
    } else if (source?.family === "SVM") {
      list.push({ ok: !!sourceToken, label: "Source SPL token mint set" });
      list.push({ ok: !!solana.publicKey, label: "Solana wallet connected" });
    }
    list.push({ ok: amountRaw > 0n, label: "Amount greater than zero" });
    list.push({ ok: !!previewOut && previewOut > 0n, label: "Preview output is viable" });
    if (returnToSource) {
      list.push({ ok: !!beneficiary, label: "Beneficiary set" });
    } else {
      list.push({ ok: isAddress(beneficiary), label: "Local beneficiary is a valid EVM address" });
    }
    return list;
  }, [vault.enabled, action, state.processing, source, sourceToken, evmConnected, evmChainId, solana.publicKey, amountRaw, previewOut, returnToSource, beneficiary]);

  const allChecksPass = checks.every((c) => c.ok);

  // ---- Quote (EVM only; Solana fee is quoted at send) ----
  async function runQuote() {
    if (!source || source.family !== "EVM" || !evmAddress) return;
    setQuoteLoading(true);
    try {
      const q = await quoteEvmSend({
        source,
        hubChain: ctx.chain,
        adapter: ctx.adapter,
        target: vault.target,
        sourceToken: getAddress(sourceToken),
        amount: amountRaw,
        beneficiary,
        beneficiaryType,
        minimumOut,
        returnToSourceChain: returnToSource,
        localRefundAddress: localRefund || undefined,
        gasLimitOverride: gasOverride ? Number(gasOverride) : undefined,
        sender: getAddress(evmAddress),
      });
      setQuote(q);
    } catch (e: any) {
      toast({ title: "Quote failed", description: shortError(e), variant: "destructive" });
    } finally {
      setQuoteLoading(false);
    }
  }
  const [quoteLoading, setQuoteLoading] = useState(false);

  // ---- Send ----
  async function send() {
    if (!source) return;
    setPhase("sending");
    setErrorMsg(null);
    try {
      let res: { txHash: string; messageId: string };
      if (source.family === "EVM") {
        if (!evmAddress) throw new Error("Connect an EVM wallet");
        const q =
          quote ??
          (await quoteEvmSend({
            source,
            hubChain: ctx.chain,
            adapter: ctx.adapter,
            target: vault.target,
            sourceToken: getAddress(sourceToken),
            amount: amountRaw,
            beneficiary,
            beneficiaryType,
            minimumOut,
            returnToSourceChain: returnToSource,
            localRefundAddress: localRefund || undefined,
            gasLimitOverride: gasOverride ? Number(gasOverride) : undefined,
            sender: getAddress(evmAddress),
          }));
        res = await executeEvmSend(
          {
            source,
            hubChain: ctx.chain,
            adapter: ctx.adapter,
            target: vault.target,
            sourceToken: getAddress(sourceToken),
            amount: amountRaw,
            beneficiary,
            beneficiaryType,
            minimumOut,
            returnToSourceChain: returnToSource,
            localRefundAddress: localRefund || undefined,
            gasLimitOverride: gasOverride ? Number(gasOverride) : undefined,
            sender: getAddress(evmAddress),
          },
          q,
        );
      } else {
        res = await sendFromSolana();
      }
      setResult(res);
      setPhase("sent");
      addTracked({
        messageId: res.messageId,
        txHash: res.txHash,
        action,
        adapter: ctx.adapter,
        hubChainId: ctx.hubChainId,
        sourceKey: source.key,
        sourceLabel: source.label,
        vaultLabel: vault.share.symbol,
        amount,
        tokenSymbol: sourceTokenMeta?.symbol ?? (source.family === "SVM" ? "SPL" : "TOKEN"),
        returnToSourceChain: returnToSource,
        timestamp: Date.now(),
      });
      toast({ title: "Message sent", description: `messageId ${res.messageId.slice(0, 10)}…` });
    } catch (e: any) {
      setErrorMsg(shortError(e));
      setPhase("error");
    }
  }

  async function sendFromSolana(): Promise<{ txHash: string; messageId: string }> {
    if (!source?.endpoint || !source.programId) throw new Error("Solana source misconfigured");
    if (!solana.publicKey || !solana.signTransaction) throw new Error("Connect a Solana wallet");
    const chain = await SolanaChain.fromUrl(source.endpoint);
    const payload = encodePayload({
      target: vault.target,
      beneficiary,
      beneficiaryType,
      minimumOut,
      returnToSourceChain: returnToSource,
      localRefundAddress: localRefund || undefined,
    });
    const message = {
      receiver: ctx.adapter,
      data: payload,
      extraArgs: {
        gasLimit: BigInt(gasOverride ? Number(gasOverride) : DEFAULT_DEST_GAS_LIMIT),
        allowOutOfOrderExecution: true,
      },
      tokenAmounts: [{ token: sourceToken, amount: amountRaw }],
    };
    const out: any = await chain.sendMessage({
      router: source.programId,
      destChainSelector: BigInt(ctx.chain.chainSelector),
      message,
      wallet: { publicKey: solana.publicKey, signTransaction: solana.signTransaction } as any,
    });
    return { txHash: out.tx.hash, messageId: out.message.messageId };
  }

  function switchToEvm(chainId: number, label: string) {
    const net = appKitNetworkById(chainId);
    if (!net) {
      toast({
        title: "Network not registered",
        description: `${label} (chain ${chainId}) is not in the wallet's network list. Add it in web3.config.ts to enable switching.`,
        variant: "destructive",
      });
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

  return (
    <Dialog open={open} onOpenChange={(o) => !o && resetAndClose()}>
      <DialogContent className="max-w-lg max-h-[90vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle className="flex items-center gap-2 capitalize">
            <Icon className="w-5 h-5 text-primary" /> {action} · {vault.share.symbol}
          </DialogTitle>
          <DialogDescription>
            {action === "deposit"
              ? `Bridge ${vault.underlying.symbol} from a source chain → adapter deposits into the vault → you receive ${vault.share.symbol}.`
              : `Bridge ${vault.share.symbol} shares from a source chain → adapter redeems → you receive ${vault.underlying.symbol}.`}
          </DialogDescription>
        </DialogHeader>

        {phase === "sent" && result ? (
          <SentView result={result} onClose={resetAndClose} />
        ) : phase === "error" ? (
          <ErrorView message={errorMsg!} onRetry={() => setPhase("form")} />
        ) : (
          <div className="space-y-4">
            {/* Source chain */}
            <div className="space-y-2">
              <Label>Source chain (origin of the CCIP message)</Label>
              {sourceOptions.length === 0 ? (
                <div className="rounded-md border border-amber-500/40 bg-amber-500/10 px-3 py-2 text-xs text-amber-600 dark:text-amber-400">
                  No inbound source chains are configured on this adapter, so it cannot receive messages yet.
                </div>
              ) : (
                <Select value={sourceKey} onValueChange={setSourceKey}>
                  <SelectTrigger data-testid="select-source-chain">
                    <SelectValue placeholder="Select source chain" />
                  </SelectTrigger>
                  <SelectContent>
                    {sourceOptions.map(({ source: s }) => (
                      <SelectItem key={s.key} value={s.key}>
                        {s.label}{" "}
                        <span className="text-muted-foreground text-xs">({s.family})</span>
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              )}
            </div>

            {/* Source token */}
            <div className="space-y-2">
              <div className="flex items-center justify-between">
                <Label>
                  Source token ({action === "deposit" ? "vault asset" : "vault share"} on source)
                </Label>
                {resolving && (
                  <span className="text-[11px] text-muted-foreground inline-flex items-center gap-1">
                    <Loader2 className="w-3 h-3 animate-spin" /> detecting…
                  </span>
                )}
                {autoDetected && !resolving && (
                  <Badge variant="secondary" className="text-[10px]">auto-detected</Badge>
                )}
              </div>
              <Input
                data-testid="input-source-token"
                placeholder={source?.family === "SVM" ? "SPL mint address" : "0x..."}
                value={sourceToken}
                spellCheck={false}
                className="font-mono"
                onChange={(e) => {
                  setSourceToken(e.target.value.trim());
                  setAutoDetected(false);
                  setResolveFailed(false);
                }}
              />
              {sourceTokenMeta && (
                <p className="text-xs text-muted-foreground">
                  {sourceTokenMeta.symbol} · {sourceTokenMeta.decimals} decimals
                  {autoDetected && " · discovered via CCIP token pool"}
                </p>
              )}
              {resolveFailed && !sourceToken && (
                <p className="text-xs text-amber-600 dark:text-amber-400">
                  Couldn't auto-detect a CCIP lane token for this source chain — enter the
                  source token address manually.
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
                  setQuote(null);
                }}
              />
            </div>

            {/* Delivery */}
            <div className="flex items-center justify-between rounded-md border border-border px-3 py-2.5">
              <div>
                <p className="text-sm font-medium">Return to source chain</p>
                <p className="text-xs text-muted-foreground">
                  {returnToSource
                    ? "Output bridged back to the beneficiary on the source chain"
                    : "Output delivered locally to an EVM beneficiary on the hub chain"}
                </p>
              </div>
              <Switch checked={returnToSource} onCheckedChange={(v) => { setReturnToSource(v); setBeneficiary(""); setPreviewOut(null); }} data-testid="switch-return-to-source" />
            </div>

            {/* Beneficiary */}
            <div className="space-y-2">
              <Label>
                Beneficiary {returnToSource ? `(on ${source?.label ?? "source"})` : "(EVM, on hub)"}
              </Label>
              <Input
                data-testid="input-beneficiary"
                placeholder={beneficiaryType === "svm" ? "Solana address" : "0x..."}
                value={beneficiary}
                spellCheck={false}
                className="font-mono"
                onChange={(e) => setBeneficiary(e.target.value.trim())}
              />
            </div>

            {/* Advanced */}
            <div className="grid grid-cols-2 gap-3">
              <div className="space-y-2">
                <Label className="text-xs">Slippage (bps)</Label>
                <Input
                  type="number"
                  value={slippageBps}
                  onChange={(e) => setSlippageBps(Number(e.target.value) || 0)}
                  data-testid="input-slippage"
                />
              </div>
              <div className="space-y-2">
                <Label className="text-xs">Dest gas limit (optional)</Label>
                <Input
                  type="number"
                  placeholder={`${DEFAULT_DEST_GAS_LIMIT}`}
                  value={gasOverride}
                  onChange={(e) => setGasOverride(e.target.value)}
                  data-testid="input-gas-override"
                />
              </div>
            </div>

            <div className="space-y-2">
              <Label className="text-xs">Local refund address (optional, hub EVM — enables local recovery if it fails)</Label>
              <Input
                placeholder="0x..."
                value={localRefund}
                spellCheck={false}
                className="font-mono"
                onChange={(e) => setLocalRefund(e.target.value.trim())}
                data-testid="input-local-refund"
              />
            </div>

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
            {quote && (
              <div className="rounded-md border border-border p-3 text-sm space-y-1">
                <div className="flex justify-between">
                  <span className="text-muted-foreground">CCIP fee</span>
                  <span className="font-mono">{fmtUnits(quote.fee, 18)} {source?.nativeCurrency?.symbol ?? "native"}</span>
                </div>
                <div className="flex justify-between">
                  <span className="text-muted-foreground">Dest gas limit</span>
                  <span className="font-mono">{quote.gasLimit.toLocaleString()}</span>
                </div>
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
            {source?.family === "SVM" && !solana.publicKey && (
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

function SentView({ result, onClose }: { result: { txHash: string; messageId: string }; onClose: () => void }) {
  return (
    <div className="space-y-4 py-2">
      <div className="flex flex-col items-center text-center gap-2">
        <CheckCircle2 className="w-12 h-12 text-green-500" />
        <p className="font-medium">Message submitted</p>
        <p className="text-sm text-muted-foreground">Track its progress in the Messages tab.</p>
      </div>
      <div className="rounded-md border border-border p-3 space-y-2 text-xs">
        <div>
          <p className="text-muted-foreground">Message ID</p>
          <p className="font-mono break-all">{result.messageId}</p>
        </div>
        <div>
          <p className="text-muted-foreground">Source tx</p>
          <p className="font-mono break-all">{result.txHash}</p>
        </div>
      </div>
      <a href={ccipExplorerUrl(result.messageId)} target="_blank" rel="noreferrer">
        <Button variant="outline" className="w-full">
          View on CCIP Explorer <ExternalLink className="w-4 h-4 ml-2" />
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
