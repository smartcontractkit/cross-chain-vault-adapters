import { ConfigError, loadConfig, runMain } from "./shared";
import { ReportWriter, formatScenarioError } from "./report";
import { SCENARIOS, type ScenarioDef, type SuiteProfile, hasSolanaEnv, scenariosForProfile } from "./scenarios";
import { loadSolanaConfig } from "./solana-shared";

const ALLOWED_PROFILES: SuiteProfile[] = ["ccip-v1", "happy", "failure", "recovery", "all"];

type CliOptions = {
  profile: SuiteProfile;
  wait: boolean;
  skipSolana: boolean;
  list: boolean;
  help: boolean;
  only?: string;
};

const USAGE = `Usage: pnpm e2e:ccip suite [options]

Options:
  --profile=<name>   ccip-v1 (default) | happy | failure | recovery | all
  --only=<ids>       comma-separated scenario ids (see --list)
  --wait             poll the CCIP API until each message is terminal and check the adapter outcome
  --skip-solana      skip Solana-source scenarios
  --list             print the scenario catalog and exit (no env or network needed)
  --help             print this help`;

function parseCli(argv: string[]): CliOptions {
  let profile: SuiteProfile = "ccip-v1";
  let wait = false;
  let skipSolana = false;
  let list = false;
  let help = false;
  let only: string | undefined;

  for (let i = 0; i < argv.length; i++) {
    let arg = argv[i]!;
    if ((arg === "--profile" || arg === "--only") && argv[i + 1] !== undefined) {
      arg = `${arg}=${argv[++i]}`;
    }
    if (arg === "--wait") {
      wait = true;
      continue;
    }
    if (arg === "--skip-solana") {
      skipSolana = true;
      continue;
    }
    if (arg === "--list") {
      list = true;
      continue;
    }
    if (arg.startsWith("--profile=")) {
      profile = arg.slice("--profile=".length) as SuiteProfile;
      continue;
    }
    if (arg === "--help" || arg === "-h") {
      help = true;
      continue;
    }
    if (arg.startsWith("--only=")) {
      only = arg.slice("--only=".length);
      continue;
    }
    throw new ConfigError(`unknown suite argument ${arg}\n${USAGE}`);
  }

  if (!ALLOWED_PROFILES.includes(profile)) {
    throw new ConfigError(`unknown profile ${profile}; use one of ${ALLOWED_PROFILES.join(", ")}`);
  }

  return { profile, wait, skipSolana, list, help, only };
}

function printCatalog(): void {
  console.log("CCIP E2E scenario catalog\n");
  for (const scenario of SCENARIOS) {
    console.log(`- ${scenario.id}`);
    console.log(`  ${scenario.name}`);
    console.log(`  category=${scenario.category} family=${scenario.family} profiles=${scenario.profiles.join(",")}`);
    console.log(`  expected: ${scenario.expectedOutcome}`);
    console.log("");
  }
  console.log("Profiles:");
  console.log("  ccip-v1   happy + failure sends (default, no wait)");
  console.log("  happy     deposit/redeem EVM + Solana");
  console.log("  failure   invalid target + minimumOut failures");
  console.log("  recovery  multi-step refund / local recovery (requires --wait)");
  console.log("  all       every automated scenario");
  console.log("");
  console.log(USAGE);
}

function selectScenarios(options: CliOptions): ScenarioDef[] {
  let selected = scenariosForProfile(options.profile);
  if (options.only) {
    const ids = new Set(options.only.split(",").map((id) => id.trim()).filter(Boolean));
    const unknown = [...ids].filter((id) => !SCENARIOS.some((scenario) => scenario.id === id));
    if (unknown.length > 0) {
      throw new ConfigError(`--only contains unknown scenario id(s): ${unknown.join(", ")} (see --list)`);
    }
    selected = selected.filter((scenario) => ids.has(scenario.id));
    if (selected.length === 0) {
      throw new ConfigError(`--only=${options.only} matched no scenario in profile ${options.profile}; try --profile=all`);
    }
  }
  return selected;
}

async function main(): Promise<void> {
  const options = parseCli(process.argv.slice(2));

  if (options.help) {
    console.log(USAGE);
    return;
  }

  if (options.list) {
    printCatalog();
    return;
  }

  const selected = selectScenarios(options);

  // Validate configuration before creating a report or sending anything.
  printSuitePreflight(options, selected);

  const report = new ReportWriter();
  console.log(`Running ${selected.length} scenario(s); profile=${options.profile}; wait=${options.wait}; report=${report.filePath}\n`);

  let failures = 0;
  for (const scenario of selected) {
    const record = await runScenario(scenario, options);
    report.add(record);
    if (record.status === "failed") {
      failures += 1;
    }
  }

  report.finalize({
    profile: options.profile,
    wait: options.wait,
    skipSolana: options.skipSolana
  });

  if (failures > 0) {
    process.exitCode = 1;
  }
}

/** A throw outside a scenario's own try/catch (e.g. RPC connection) becomes a failed record instead of aborting the suite. */
async function runScenario(scenario: ScenarioDef, options: CliOptions) {
  const startedAt = Date.now();
  try {
    return await scenario.run({ wait: options.wait, skipSolana: options.skipSolana }, scenario);
  } catch (error) {
    const finishedAt = Date.now();
    return {
      id: scenario.id,
      name: scenario.name,
      category: scenario.category,
      family: scenario.family,
      status: "failed" as const,
      expectedOutcome: scenario.expectedOutcome,
      startedAt: new Date(startedAt).toISOString(),
      finishedAt: new Date(finishedAt).toISOString(),
      durationMs: finishedAt - startedAt,
      notes: [],
      error: formatScenarioError(error)
    };
  }
}

function printSuitePreflight(options: CliOptions, selected: ScenarioDef[]): void {
  const warnings: string[] = [];
  const needsEvmSource = selected.some((scenario) => scenario.family !== "svm");
  const solanaSelected = selected.some((scenario) => scenario.family === "svm");

  if (needsEvmSource) {
    const config = loadConfig();
    if (process.env.E2E_OUTBOUND_REQUESTED_FINALITY?.trim() === "0x00000000") {
      warnings.push(
        "E2E_OUTBOUND_REQUESTED_FINALITY=0x00000000 is ignored (treated as unset). Remove it for CCIP V1 lanes."
      );
    } else if (config.outboundRequestedFinality) {
      warnings.push(
        `E2E_OUTBOUND_REQUESTED_FINALITY=${config.outboundRequestedFinality} enables GenericExtraArgsV3 sends; use only on CCIP lanes whose OnRamp accepts GenericExtraArgsV3.`
      );
    }
    if (config.sourceChain.name.startsWith("avalanche")) {
      warnings.push("EVM sends from Fuji need enough AVAX for CCIP fees (~0.35+ AVAX per message at current gas limits).");
    }
  }

  if (solanaSelected && !options.skipSolana) {
    if (hasSolanaEnv()) {
      loadSolanaConfig();
    } else {
      warnings.push("Solana env not configured; Solana scenarios will be skipped (see E2E_SOLANA_* in .env.example).");
    }
  }

  if (!options.wait && selected.some((scenario) => scenario.category === "recovery")) {
    warnings.push("Recovery scenarios need --wait; they will be skipped without it.");
  }

  if (process.env.E2E_SOURCE_VAULT_TOKEN_ADDRESS && !process.env.E2E_SOURCE_VAULT_TOKEN_DECIMALS) {
    warnings.push(
      "E2E_SOURCE_VAULT_TOKEN_ADDRESS is set without E2E_SOURCE_VAULT_TOKEN_DECIMALS; redeem reads decimals() on-chain and is skipped if that fails."
    );
  }

  if (warnings.length > 0) {
    console.log("Preflight notes:");
    for (const warning of warnings) {
      console.log(`- ${warning}`);
    }
    console.log("");
  }
}

runMain(main);
