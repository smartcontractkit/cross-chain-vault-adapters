import { originateCcip } from './ccip.js'
import { loadConfig } from './config.js'
import { emitResult } from './emit.js'
import { crossChainLinks, layerZeroTxUrl, nativeTxUrl } from './explorers.js'
import { originateLz } from './lz.js'
import { encodeVaultMessage } from './message.js'
import { type OriginateResult } from './types.js'

/**
 * Entry point: load config, encode the VaultMessage, and originate the inbound transfer on the
 * configured rail (CCIP via the Chainlink CCIP SDK, or LayerZero via the OFT + options SDK). Tenderly
 * relays the message to the hub adapter, which performs the deposit/redeem and sends the result out
 * over `message.outChannel`.
 *
 *   pnpm run initiate         # uses scenario.channel from config/multibridge/tenderly.json
 *   CHANNEL=layerzero pnpm run initiate   # override the rail
 *
 * Fail scenarios (failSlippage) expect the hub delivery to revert (MinAmountOutNotMet, or the bridge's own minAmountLD check) → MessageFailed. After relay:
 *   GUID=<guid> pnpm run recover:status
 *   GUID=<guid> pnpm run recover:refund
 */
async function main(): Promise<void> {
  const cfg = loadConfig()
  const channel = (process.env.CHANNEL as 'ccip' | 'layerzero' | undefined) ?? cfg.scenario.channel

  const data = encodeVaultMessage(cfg.scenario.message)
  const returnTo = cfg.scenario.message.returnTo
  const inboundLabel =
    channel === 'ccip'
      ? 'CCIP (programmable token transfer)'
      : 'Stargate / LayerZero OFT (USDT pool → hub)'
  const returnLabel =
    returnTo === 'ccip'
      ? `CCIP vault shares → ${cfg.spoke.label} (selector ${cfg.scenario.message.destination})`
      : returnTo === 'stargate'
        ? `Stargate USDT → ${cfg.spoke.label} (LZ EID ${cfg.scenario.message.destination})`
        : `destination ${cfg.scenario.message.destination}`

  console.log(`hub:   ${cfg.hub.label} (chainId ${cfg.hub.chainId}) adapter ${cfg.deployment.app}`)
  console.log(
    `from:  ${cfg.originateNet.label} (chainId ${cfg.originateNet.chainId}) scenario=${process.env.SCENARIO ?? 'default'}`,
  )
  console.log(`inbound: ${inboundLabel}`)
  console.log(`return:  ${returnLabel}`)
  console.log(`amount:  ${cfg.scenario.amount}   oft/pool: ${cfg.scenario.srcOft || '(CCIP token)'}`)
  console.log(`originator: ${cfg.account.address}`)
  if (channel === 'layerzero') {
    const prefund = BigInt(cfg.scenario.returnLegValueWei)
    if (cfg.requireLzReturnPrefunded && prefund === 0n) {
      console.warn(
        `fee:  ⚠ requireLzReturnPrefunded=true but returnLegValueWei=0 — hub will revert on bridged return`,
      )
    } else if (prefund > 0n) {
      console.log(`fee:  originator prefunds return leg with ${prefund} wei ETH (LZ compose value)`)
    } else {
      console.log(`fee:  returnLegValueWei=0 (hub reserve funds bridged return leg)`)
    }
  } else if (cfg.expectedInboundFee !== '0') {
    const tokenLabel = cfg.scenario.useSpokeShareToken ? 'shares' : 'asset'
    console.log(
      `fee:  hub skims ${cfg.expectedInboundFee} ${tokenLabel} from originator on CCIP inbound (setInboundFee)`,
    )
  }
  if (cfg.scenario.failSlippage) {
    console.log(`mode:  FAIL (minAmountOut = max uint256 → expect the hub delivery to revert on minAmountOut + MessageFailed)`)
  }
  console.log(`vaultMessage (data): ${data}\n`)

  let result: OriginateResult
  if (channel === 'ccip') {
    result = await originateCcip(cfg, data)
  } else if (channel === 'layerzero') {
    result = await originateLz(cfg, data)
  } else {
    throw new Error(`unknown channel "${channel}" (expected "ccip" or "layerzero")`)
  }

  console.log(`\n--- recovery ---`)
  console.log(`Save this id for recovery after the hub captures the failure:`)
  console.log(`  GUID=${result.messageId}`)
  if (cfg.scenario.failSlippage) {
    console.log(`  CHECK_ONLY=1 GUID=${result.messageId} pnpm run recover:status`)
    console.log(`  GUID=${result.messageId} pnpm run recover:refund`)
  }

  const guidResolved = channel !== 'layerzero' || result.messageId !== result.txHash
  const links =
    channel === 'layerzero' && !guidResolved
      ? {
          nativeTx: nativeTxUrl(cfg.originateNet.chainId, result.txHash),
          crossChainTx: layerZeroTxUrl(result.txHash),
          crossChainMsg: layerZeroTxUrl(result.txHash),
        }
      : {
          nativeTx: nativeTxUrl(cfg.originateNet.chainId, result.txHash),
          ...crossChainLinks(channel, result.txHash, result.messageId),
        }

  emitResult('E2E_RESULT', {
    ok: true,
    kind: 'initiate',
    scenario: process.env.SCENARIO ?? 'default',
    channel,
    txHash: result.txHash,
    messageId: result.messageId,
    guidResolved,
    originateChainId: cfg.originateNet.chainId,
    originateLabel: cfg.originateNet.label,
    hubChainId: cfg.hub.chainId,
    failSlippage: !!cfg.scenario.failSlippage,
    adapter: cfg.deployment.app,
    links,
  })
}

main().catch((err) => {
  // Set E2E_DEBUG=1 for the full stack trace.
  console.error(process.env.E2E_DEBUG ? err : `error: ${err instanceof Error ? err.message : String(err)}`)
  process.exit(1)
})
