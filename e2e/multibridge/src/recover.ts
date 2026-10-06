import { decodeAbiParameters, type Hex } from 'viem'
import { ADAPTER_ABI, INBOUND_PARAM, MESSAGE_FAILED_EVENT } from './abi.js'
import { hubClients } from './clients.js'
import { loadHubConfig } from './config.js'
import { emitResult } from './emit.js'
import { nativeTxUrl } from './explorers.js'

/**
 * Permissionless recovery: reconstruct the captured Inbound from the adapter's MessageFailed event
 * (the contract stores only a fixed-size hash commitment) and call refundToSource(inbound) on the hub
 * adapter to bounce tokens back to the source chain sender.
 *
 *   GUID=0x… pnpm run recover:refund
 *   GUID=0x… CHECK_ONLY=1 pnpm run recover:status
 *
 * Wait until the cross-chain message has been relayed and the hub adapter emitted MessageFailed before
 * running recover. Set FROM_BLOCK to bound the event scan on RPCs with a getLogs range limit.
 */
async function main(): Promise<void> {
  const guidRaw = process.env.GUID ?? process.env.MESSAGE_ID
  if (!guidRaw) {
    throw new Error('set GUID (or MESSAGE_ID) to the CCIP messageId / LayerZero guid from initiate output')
  }
  const guid = guidRaw as Hex

  const cfg = loadHubConfig()
  const rpcUrl = process.env.HUB_RPC_URL ?? process.env[cfg.hub.rpcUrlEnv]
  if (!rpcUrl) throw new Error(`missing hub RPC — set HUB_RPC_URL or ${cfg.hub.rpcUrlEnv}`)

  const adapter = cfg.deployment.app
  const { publicClient, walletClient, chain } = hubClients(cfg, rpcUrl)

  const failed = (await publicClient.readContract({
    address: adapter,
    abi: ADAPTER_ABI,
    functionName: 'isFailed',
    args: [guid],
  })) as boolean
  const refunded = (await publicClient.readContract({
    address: adapter,
    abi: ADAPTER_ABI,
    functionName: 'isRefunded',
    args: [guid],
  })) as boolean

  console.log(`adapter: ${adapter}`)
  console.log(`guid:    ${guid}`)
  console.log(`isFailed:   ${failed}`)
  console.log(`isRefunded: ${refunded}`)

  if (process.env.CHECK_ONLY === '1') {
    if (!failed && !refunded) {
      console.log('\nMessage not captured yet — wait for hub delivery (MessageFailed on the adapter).')
    }
    emitResult('E2E_RECOVER_RESULT', {
      ok: true,
      kind: 'status',
      guid,
      isFailed: failed,
      isRefunded: refunded,
    })
    return
  }

  if (refunded) {
    console.log('\nAlready refunded — nothing to do.')
    emitResult('E2E_RECOVER_RESULT', {
      ok: true,
      kind: 'refund',
      guid,
      isFailed: failed,
      isRefunded: true,
      skipped: true,
    })
    return
  }
  if (!failed) {
    throw new Error('message is not in FAILED state on the hub — wait for delivery or check GUID')
  }

  // The contract stores only keccak256(abi.encode(inbound)); reconstruct the full Inbound from the
  // MessageFailed event's `message` field and pass it to refundToSource (hash-verified on-chain).
  const fromBlock = process.env.FROM_BLOCK ? BigInt(process.env.FROM_BLOCK) : 'earliest'
  const failedLogs = await publicClient.getLogs({
    address: adapter,
    event: MESSAGE_FAILED_EVENT,
    args: { guid },
    fromBlock,
    toBlock: 'latest',
  })
  const failedLog = failedLogs.at(-1)
  if (!failedLog?.args.message) {
    throw new Error('MessageFailed event not found for GUID — set FROM_BLOCK near the capture block')
  }
  const [inbound] = decodeAbiParameters([INBOUND_PARAM], failedLog.args.message)

  console.log(`\nfailed inbound (reconstructed from MessageFailed):`)
  console.log(`  channel: ${inbound.channel} (${inbound.channel === 0 ? 'CCIP' : 'LayerZero'})`)
  console.log(`  srcId:   ${inbound.srcId}`)
  console.log(`  tokens:  ${inbound.tokens.map((t) => `${t.token} × ${t.amount}`).join(', ')}`)

  const refundValue = BigInt(process.env.REFUND_VALUE_WEI ?? '50000000000000000')
  console.log(`\ncalling refundToSource(<inbound ${guid}>) with ${refundValue} wei ...`)

  const hash = await walletClient.writeContract({
    address: adapter,
    abi: ADAPTER_ABI,
    functionName: 'refundToSource',
    args: [inbound],
    value: refundValue,
    chain,
  })
  const receipt = await publicClient.waitForTransactionReceipt({ hash })
  console.log(`✔ refundToSource confirmed`)
  console.log(`  tx: ${receipt.transactionHash}`)

  const refundedAfter = (await publicClient.readContract({
    address: adapter,
    abi: ADAPTER_ABI,
    functionName: 'isRefunded',
    args: [guid],
  })) as boolean
  console.log(`isRefunded: ${refundedAfter}`)

  emitResult('E2E_RECOVER_RESULT', {
    ok: true,
    kind: 'refund',
    guid,
    isFailed: false,
    isRefunded: refundedAfter,
    refundTxHash: receipt.transactionHash,
    links: { hubTx: nativeTxUrl(cfg.hub.chainId, receipt.transactionHash) },
  })
}

main().catch((err) => {
  // Set E2E_DEBUG=1 for the full stack trace.
  console.error(process.env.E2E_DEBUG ? err : `error: ${err instanceof Error ? err.message : String(err)}`)
  process.exit(1)
})
