/** Minimal ERC-20 approve ABI. */
export const ERC20_ABI = [
  {
    type: 'function',
    name: 'approve',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'spender', type: 'address' },
      { name: 'amount', type: 'uint256' },
    ],
    outputs: [{ name: '', type: 'bool' }],
  },
  {
    type: 'function',
    name: 'allowance',
    stateMutability: 'view',
    inputs: [
      { name: 'owner', type: 'address' },
      { name: 'spender', type: 'address' },
    ],
    outputs: [{ name: '', type: 'uint256' }],
  },
] as const

/** Minimal LayerZero V2 OFT ABI (quoteSend / send / approvalRequired / token). */
export const OFT_ABI = [
  {
    type: 'function',
    name: 'token',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ name: '', type: 'address' }],
  },
  {
    type: 'function',
    name: 'approvalRequired',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ name: '', type: 'bool' }],
  },
  {
    type: 'function',
    name: 'quoteSend',
    stateMutability: 'view',
    inputs: [
      {
        name: 'sendParam',
        type: 'tuple',
        components: [
          { name: 'dstEid', type: 'uint32' },
          { name: 'to', type: 'bytes32' },
          { name: 'amountLD', type: 'uint256' },
          { name: 'minAmountLD', type: 'uint256' },
          { name: 'extraOptions', type: 'bytes' },
          { name: 'composeMsg', type: 'bytes' },
          { name: 'oftCmd', type: 'bytes' },
        ],
      },
      { name: 'payInLzToken', type: 'bool' },
    ],
    outputs: [
      {
        name: 'fee',
        type: 'tuple',
        components: [
          { name: 'nativeFee', type: 'uint256' },
          { name: 'lzTokenFee', type: 'uint256' },
        ],
      },
    ],
  },
  {
    type: 'function',
    name: 'send',
    stateMutability: 'payable',
    inputs: [
      {
        name: 'sendParam',
        type: 'tuple',
        components: [
          { name: 'dstEid', type: 'uint32' },
          { name: 'to', type: 'bytes32' },
          { name: 'amountLD', type: 'uint256' },
          { name: 'minAmountLD', type: 'uint256' },
          { name: 'extraOptions', type: 'bytes' },
          { name: 'composeMsg', type: 'bytes' },
          { name: 'oftCmd', type: 'bytes' },
        ],
      },
      {
        name: 'fee',
        type: 'tuple',
        components: [
          { name: 'nativeFee', type: 'uint256' },
          { name: 'lzTokenFee', type: 'uint256' },
        ],
      },
      { name: 'refundAddress', type: 'address' },
    ],
    outputs: [
      {
        name: 'receipt',
        type: 'tuple',
        components: [
          { name: 'guid', type: 'bytes32' },
          { name: 'nonce', type: 'uint64' },
          {
            name: 'fee',
            type: 'tuple',
            components: [
              { name: 'nativeFee', type: 'uint256' },
              { name: 'lzTokenFee', type: 'uint256' },
            ],
          },
        ],
      },
      {
        name: 'oftReceipt',
        type: 'tuple',
        components: [
          { name: 'amountSentLD', type: 'uint256' },
          { name: 'amountReceivedLD', type: 'uint256' },
        ],
      },
    ],
  },
  {
    type: 'event',
    name: 'OFTSent',
    inputs: [
      { name: 'guid', type: 'bytes32', indexed: true },
      { name: 'dstEid', type: 'uint32', indexed: false },
      { name: 'from', type: 'address', indexed: false },
      { name: 'amountSentLD', type: 'uint256', indexed: false },
      { name: 'amountReceivedLD', type: 'uint256', indexed: false },
    ],
  },
] as const

/** The Inbound struct as an ABI parameter (used to decode MessageFailed.message and to call recovery). */
export const INBOUND_PARAM = {
  name: 'inbound',
  type: 'tuple',
  components: [
    { name: 'channel', type: 'uint8' },
    { name: 'srcId', type: 'uint64' },
    { name: 'sender', type: 'bytes32' },
    { name: 'guid', type: 'bytes32' },
    {
      name: 'tokens',
      type: 'tuple[]',
      components: [
        { name: 'token', type: 'address' },
        { name: 'amount', type: 'uint256' },
      ],
    },
    { name: 'data', type: 'bytes' },
    { name: 'lzOft', type: 'address' },
  ],
} as const

/** MessageFailed event: `message` is the ABI-encoded Inbound (the contract stores only its hash). */
export const MESSAGE_FAILED_EVENT = {
  type: 'event',
  name: 'MessageFailed',
  inputs: [
    { name: 'guid', type: 'bytes32', indexed: true },
    { name: 'channel', type: 'uint8', indexed: true },
    { name: 'message', type: 'bytes', indexed: false },
    { name: 'reason', type: 'bytes', indexed: false },
  ],
} as const

/** Hub adapter: failure capture + permissionless bounce-back. The contract stores a fixed-size hash
 *  commitment per failed guid; recovery callers reconstruct the Inbound from the MessageFailed event
 *  and pass it to refundToSource, which verifies it against the commitment. */
export const ADAPTER_ABI = [
  {
    type: 'function',
    name: 'isFailed',
    stateMutability: 'view',
    inputs: [{ name: 'guid', type: 'bytes32' }],
    outputs: [{ name: '', type: 'bool' }],
  },
  {
    type: 'function',
    name: 'isRefunded',
    stateMutability: 'view',
    inputs: [{ name: 'guid', type: 'bytes32' }],
    outputs: [{ name: '', type: 'bool' }],
  },
  {
    type: 'function',
    name: 'failedMessageHash',
    stateMutability: 'view',
    inputs: [{ name: 'guid', type: 'bytes32' }],
    outputs: [{ name: '', type: 'bytes32' }],
  },
  {
    type: 'function',
    name: 'refundToSource',
    stateMutability: 'payable',
    inputs: [INBOUND_PARAM],
    outputs: [],
  },
  MESSAGE_FAILED_EVENT,
] as const
