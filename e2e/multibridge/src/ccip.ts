import { EVMChain } from '@chainlink/ccip-sdk'
import { viemWallet } from '@chainlink/ccip-sdk/viem'
import { type Address, type Hex } from 'viem'
import { ERC20_ABI } from './abi.js'
import { originateClients } from './clients.js'
import { type Loaded } from './config.js'
import { type OriginateResult } from './types.js'

/**
 * Originates a CCIP programmable token transfer from the spoke toward the hub adapter, carrying the
 * source token AND the encoded VaultMessage, using the Chainlink CCIP SDK (`@chainlink/ccip-sdk`).
 *
 * The non-zero `extraArgs.gasLimit` is essential: it is the gas CCIP grants the adapter's
 * `ccipReceive` on the hub. With gasLimit 0, CCIP would skip the receiver callback and the deposit/
 * redeem would never run.
 *
 * Verified against `@chainlink/ccip-sdk` v1.9.0: `EVMChain.fromUrl(url)`, `getFee(SendMessageOpts)`,
 * `sendMessage(..., { wallet: viemWallet(walletClient) })` from `@chainlink/ccip-sdk/viem`, where the
 * message is a `MessageInput`
 * (`receiver`, `data`, `tokenAmounts`, `extraArgs`) and `sendMessage` resolves to a `CCIPRequest`.
 */
export async function originateCcip(cfg: Loaded, data: Hex): Promise<OriginateResult> {
  const { hub, scenario, deployment, originateRpcUrl, originateNet } = cfg
  const amount = BigInt(scenario.amount)
  const router = originateNet.ccipRouter
  const destChainSelector = BigInt(hub.ccipChainSelector)

  const { publicClient, walletClient } = originateClients(cfg)

  // 1) Approve the source token to the CCIP router (it pulls tokens during ccipSend).
  console.log(`approving ${amount} of ${scenario.srcToken} to CCIP router ${router} ...`)
  const approveHash = await walletClient.writeContract({
    address: scenario.srcToken,
    abi: ERC20_ABI,
    functionName: 'approve',
    args: [router, amount],
  })
  await publicClient.waitForTransactionReceipt({ hash: approveHash })

  // 2) Build the programmable token-transfer message.
  const message = {
    receiver: deployment.app as Address,
    data,
    tokenAmounts: [{ token: scenario.srcToken, amount }],
    extraArgs: { gasLimit: BigInt(scenario.inboundGasLimit), allowOutOfOrderExecution: true },
  }

  // 3) Originate via the CCIP SDK.
  const chain = await EVMChain.fromUrl(originateRpcUrl)
  const fee = await chain.getFee({ router, destChainSelector, message })
  console.log(`ccip native fee: ${fee} wei`)

  const request = await chain.sendMessage({
    router,
    destChainSelector,
    message,
    wallet: viemWallet(walletClient),
  })

  const txHash = request.tx.hash as `0x${string}`
  let messageId = (request.message as { messageId?: string }).messageId as `0x${string}` | undefined
  if (!messageId) {
    const fromTx = await chain.getMessagesInTx(txHash)
    messageId = fromTx[0]?.message.messageId as `0x${string}` | undefined
  }
  if (!messageId) {
    throw new Error(`could not read CCIP messageId for tx ${txHash} — check https://ccip.chain.link/tx/${txHash}`)
  }

  console.log(`✔ CCIP message sent`)
  console.log(`  tx:        ${txHash}`)
  console.log(`  messageId: ${messageId}`)
  console.log(`  → CCIP delivers it to the hub adapter ${deployment.app} on live networks; on Tenderly forks deliver it manually (docs/multibridge/development/TENDERLY_E2E.md).`)

  return { txHash, messageId }
}
