import { Options } from '@layerzerolabs/lz-v2-utilities'
import { decodeEventLog, pad, type Address, type Hex } from 'viem'
import { ERC20_ABI, OFT_ABI } from './abi.js'
import { spokeClients } from './clients.js'
import { type Loaded } from './config.js'
import { type OriginateResult } from './types.js'

/**
 * Originates a LayerZero OFT send from the spoke toward the hub adapter, carrying the token AND a
 * compose payload (the encoded VaultMessage). On the hub the OFT credits the adapter and the endpoint
 * invokes `lzCompose` on it with the payload — driving the deposit/redeem.
 *
 * Uses the LayerZero options SDK (`@layerzerolabs/lz-v2-utilities`) to build the executor options:
 *  - `addExecutorLzReceiveOption` — gas for the OFT's lzReceive (token credit) on the hub.
 *  - `addExecutorLzComposeOption(0, ...)` — gas for the adapter's lzCompose at compose index 0.
 */
export async function originateLz(cfg: Loaded, data: Hex): Promise<OriginateResult> {
  const { hub, scenario, deployment } = cfg
  const amount = BigInt(scenario.amount)
  const oft = scenario.srcOft

  const { publicClient, walletClient, chain } = spokeClients(cfg)

  // The compose option's third arg is `value`: native delivered to the hub adapter's lzCompose. When
  // `requireLzReturnPrefunded` is true on the hub adapter, this MUST be non-zero for bridged return
  // legs — the message originator pays the outbound native fee in ETH; surplus is refunded to sender.
  const returnLegValue = BigInt(scenario.returnLegValueWei)
  const extraOptions = Options.newOptions()
    .addExecutorLzReceiveOption(scenario.lzReceiveGasLimit, 0)
    .addExecutorComposeOption(0, scenario.inboundGasLimit, returnLegValue)
    .toHex() as Hex

  const sendParam = {
    dstEid: hub.lzEid,
    to: pad(deployment.app as Address, { size: 32 }),
    amountLD: amount,
    minAmountLD: 0n, // tighten for production; 0 tolerates OFT shared-decimals dust in testing
    extraOptions,
    composeMsg: data,
    oftCmd: '0x' as Hex,
  } as const

  // Quote the native fee for the send (+compose).
  const fee = (await publicClient.readContract({
    address: oft,
    abi: OFT_ABI,
    functionName: 'quoteSend',
    args: [sendParam, false],
  })) as { nativeFee: bigint; lzTokenFee: bigint }
  console.log(`lz native fee: ${fee.nativeFee} wei`)
  if (returnLegValue > 0n) {
    console.log(`lz compose prefund: ${returnLegValue} wei ETH (originator pays return-leg native via OFT options)`)
  }

  // Approve the underlying token to the OFT adapter if it requires it (OFTAdapter does; native OFT does not).
  const approvalRequired = (await publicClient.readContract({
    address: oft,
    abi: OFT_ABI,
    functionName: 'approvalRequired',
  })) as boolean
  if (approvalRequired) {
    console.log(`approving ${amount} of ${scenario.srcToken} to OFT ${oft} ...`)
    const approveHash = await walletClient.writeContract({
      address: scenario.srcToken,
      abi: ERC20_ABI,
      functionName: 'approve',
      args: [oft, amount],
    })
    await publicClient.waitForTransactionReceipt({ hash: approveHash })
  }

  const sendHash = await walletClient.writeContract({
    address: oft,
    abi: OFT_ABI,
    functionName: 'send',
    args: [sendParam, { nativeFee: fee.nativeFee, lzTokenFee: 0n }, cfg.account.address],
    value: fee.nativeFee,
    chain,
  })
  const receipt = await publicClient.waitForTransactionReceipt({ hash: sendHash })

  let guid = extractGuidFromReceipt(receipt.logs)
  if (!guid) {
    guid = await fetchGuidFromLzScan(receipt.transactionHash)
  }
  if (!guid) {
    console.warn(`⚠ guid not indexed yet — tx was sent successfully`)
    console.warn(`  tx: ${receipt.transactionHash}`)
    console.warn(`  scan: https://testnet.layerzeroscan.com/tx/${receipt.transactionHash}`)
  }

  console.log(`✔ Stargate / LayerZero OFT send sent`)
  console.log(`  tx:     ${receipt.transactionHash}`)
  if (guid) console.log(`  guid:   ${guid}`)
  console.log(`  → Relay to hub adapter ${deployment.app}; watch LayerZero Scan / hub for lzCompose.`)

  return {
    txHash: receipt.transactionHash,
    messageId: guid ?? receipt.transactionHash,
  }
}

/** Try OFTSent on any log; Stargate pools may emit from a different contract than the OFT ABI target. */
function extractGuidFromReceipt(logs: { data: Hex; topics: readonly Hex[] }[]): `0x${string}` | undefined {
  for (const log of logs) {
    try {
      const ev = decodeEventLog({
        abi: OFT_ABI,
        data: log.data,
        topics: log.topics as [Hex, ...Hex[]],
      })
      if (ev.eventName === 'OFTSent') {
        const g = (ev.args as { guid?: `0x${string}` }).guid
        if (g) return g
      }
    } catch {
      /* try next log */
    }
  }
  return undefined
}

/** LayerZero Scan testnet API — fallback when local log decode misses the guid. Polls briefly (indexing lag). */
async function fetchGuidFromLzScan(txHash: `0x${string}`): Promise<`0x${string}` | undefined> {
  const url = `https://scan-testnet.layerzero-api.com/v1/messages/tx/${txHash}`
  for (let attempt = 0; attempt < 8; attempt++) {
    try {
      const res = await fetch(url)
      if (res.ok) {
        const body = (await res.json()) as { data?: Array<{ guid?: string }> }
        const guid = body.data?.[0]?.guid
        if (guid?.startsWith('0x')) return guid as `0x${string}`
      }
    } catch {
      /* retry */
    }
    if (attempt < 7) await new Promise((r) => setTimeout(r, 3000))
  }
  return undefined
}
