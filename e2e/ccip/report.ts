import { appendFileSync, mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";

export type ScenarioStatus = "passed" | "failed" | "skipped" | "sent";

export type ScenarioRecord = {
  id: string;
  name: string;
  category: string;
  family: "evm" | "svm" | "multi";
  status: ScenarioStatus;
  expectedOutcome: string;
  startedAt: string;
  finishedAt: string;
  durationMs: number;
  sendTxHash?: string;
  sendTxExplorerUrl?: string;
  messageId?: string;
  ccipExplorerUrl?: string;
  finalMessageStatus?: string;
  followUpTxHash?: string;
  followUpTxExplorerUrl?: string;
  notes: string[];
  error?: string;
};

const CCIP_EXPLORER_MSG_BASE = "https://ccip.chain.link/msg";

const CHAIN_TX_EXPLORER: Record<string, string> = {
  "ethereum-testnet-sepolia": "https://sepolia.etherscan.io/tx/",
  "avalanche-testnet-fuji": "https://testnet.snowtrace.io/tx/",
  "ethereum-testnet-sepolia-base-1": "https://sepolia.basescan.org/tx/",
  "solana-devnet": "https://explorer.solana.com/tx/",
  "solana-mainnet": "https://explorer.solana.com/tx/"
};

export function ccipExplorerUrl(messageId: string): string {
  return `${CCIP_EXPLORER_MSG_BASE}/${messageId}`;
}

/** Short, actionable error text for suite reports (ethers errors are very verbose). */
export function formatScenarioError(error: unknown): string {
  if (!(error instanceof Error)) {
    return String(error);
  }

  const msg = error.message;
  if (msg.includes("insufficient funds")) {
    const match = msg.match(/have (\d+) want (\d+)/);
    if (match) {
      return (
        `insufficient native balance on source chain for CCIP fee + gas ` +
        `(have ${match[1]} wei, need ${match[2]} wei) — fund the E2E wallet on ${process.env.E2E_SOURCE_CHAIN ?? "source"}`
      );
    }
    return "insufficient native balance on source chain for CCIP fee + gas";
  }

  if (msg.includes("0x5247fdce")) {
    return (
      "router getFee/ccipSend reverted 0x5247fdce — usually incompatible outbound extraArgs. " +
      "For CCIP V1 lanes, unset E2E_OUTBOUND_REQUESTED_FINALITY (do not use GenericExtraArgsV3)."
    );
  }

  if (msg.includes("could not decode result data") && msg.includes("symbol")) {
    return (
      "token metadata unavailable (symbol/decimals). For redeem, set E2E_SOURCE_VAULT_TOKEN_DECIMALS " +
      "and verify E2E_SOURCE_VAULT_TOKEN_ADDRESS is the bridged vault share on the source chain."
    );
  }

  if (msg.includes("not configured in registry")) {
    return (
      `${msg} — the source vault token must be CCIP-registered on ${process.env.E2E_SOURCE_CHAIN ?? "source"} ` +
      "for the destination lane. Redeem E2E requires a prior successful deposit that bridged vault shares back."
    );
  }

  const short = msg.split(" (action=")[0]?.split(" (info=")[0] ?? msg;
  return short.length > 400 ? `${short.slice(0, 400)}…` : short;
}

export function chainTxExplorerUrl(chainName: string, txHash: string): string | undefined {
  const base = CHAIN_TX_EXPLORER[chainName];
  if (!base) {
    return undefined;
  }
  return `${base}${txHash}`;
}

export class ReportWriter {
  readonly filePath: string;
  private readonly records: ScenarioRecord[] = [];

  constructor(reportDir = path.resolve(__dirname, "reports")) {
    mkdirSync(reportDir, { recursive: true });
    const stamp = new Date().toISOString().replace(/[:.]/g, "-");
    this.filePath = path.join(reportDir, `suite-${stamp}.md`);
    writeFileSync(this.filePath, `# CCIP E2E Suite Report\n\nStarted: ${new Date().toISOString()}\n\n`);
  }

  add(record: ScenarioRecord): void {
    this.records.push(record);
    appendFileSync(this.filePath, formatScenarioMarkdown(record));
    console.log(`[${record.status.toUpperCase()}] ${record.id}: ${record.name}`);
    if (record.messageId) {
      console.log(`  message id: ${record.messageId}`);
      console.log(`  ccip explorer: ${record.ccipExplorerUrl ?? ccipExplorerUrl(record.messageId)}`);
    }
    if (record.sendTxHash) {
      console.log(`  send tx: ${record.sendTxHash}`);
      if (record.sendTxExplorerUrl) {
        console.log(`  send tx explorer: ${record.sendTxExplorerUrl}`);
      }
    }
    if (record.followUpTxHash) {
      console.log(`  follow-up tx: ${record.followUpTxHash}`);
      if (record.followUpTxExplorerUrl) {
        console.log(`  follow-up tx explorer: ${record.followUpTxExplorerUrl}`);
      }
    }
    if (record.error) {
      const lines = record.error.split("\n").filter(Boolean);
      console.log(`  error: ${lines[0]}`);
      for (const line of lines.slice(1)) {
        console.log(`         ${line}`);
      }
    }
  }

  finalize(meta: { profile: string; wait: boolean; skipSolana: boolean }): void {
    const passed = this.records.filter((r) => r.status === "passed").length;
    const sent = this.records.filter((r) => r.status === "sent").length;
    const failed = this.records.filter((r) => r.status === "failed").length;
    const skipped = this.records.filter((r) => r.status === "skipped").length;

    const summary = [
      "",
      "---",
      "",
      "## Summary",
      "",
      `- Profile: \`${meta.profile}\``,
      `- Wait for CCIP status: \`${meta.wait}\``,
      `- Skip Solana: \`${meta.skipSolana}\``,
      `- Passed: **${passed}**`,
      `- Sent (no wait / no follow-up): **${sent}**`,
      `- Failed: **${failed}**`,
      `- Skipped: **${skipped}**`,
      `- Finished: ${new Date().toISOString()}`,
      ""
    ].join("\n");

    appendFileSync(this.filePath, summary);
    console.log(`\nReport written to ${this.filePath}`);
    console.log(`Passed=${passed} Sent=${sent} Failed=${failed} Skipped=${skipped}`);
  }
}

function formatScenarioMarkdown(record: ScenarioRecord): string {
  const lines = [
    `## ${record.id}`,
    "",
    `- **Name:** ${record.name}`,
    `- **Category:** ${record.category}`,
    `- **Family:** ${record.family}`,
    `- **Status:** ${record.status}`,
    `- **Expected:** ${record.expectedOutcome}`,
    `- **Duration:** ${record.durationMs} ms`,
    ""
  ];

  if (record.sendTxHash) {
    lines.push(`- **Send tx:** \`${record.sendTxHash}\``);
  }
  if (record.sendTxExplorerUrl) {
    lines.push(`- **Send tx explorer:** ${record.sendTxExplorerUrl}`);
  }
  if (record.messageId) {
    lines.push(`- **Message ID:** \`${record.messageId}\``);
    lines.push(`- **CCIP explorer:** ${record.ccipExplorerUrl ?? ccipExplorerUrl(record.messageId)}`);
  }
  if (record.finalMessageStatus) {
    lines.push(`- **Final CCIP status:** \`${record.finalMessageStatus}\``);
  }
  if (record.followUpTxHash) {
    lines.push(`- **Follow-up tx:** \`${record.followUpTxHash}\``);
  }
  if (record.followUpTxExplorerUrl) {
    lines.push(`- **Follow-up tx explorer:** ${record.followUpTxExplorerUrl}`);
  }
  if (record.notes.length > 0) {
    lines.push("- **Notes:**");
    for (const note of record.notes) {
      lines.push(`  - ${note}`);
    }
  }
  if (record.error) {
    lines.push(`- **Error:** ${record.error}`);
  }

  lines.push("");
  return lines.join("\n");
}
