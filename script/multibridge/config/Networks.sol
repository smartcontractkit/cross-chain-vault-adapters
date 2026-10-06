// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title Networks
 * @notice Production mainnet address book — the "compiled" CCIP chain selectors, LayerZero EIDs,
 *         routers/endpoints, and Stargate/USDT0 endpoints per chain — consumed by the production deploy
 *         script ({DeployProduction}) so a deployment config can reference a chain by key instead of
 *         pasting raw addresses. Authoritative source for scripts; the markdown table in
 *         docs/multibridge/operator/DEPLOYMENT_CONFIG.md mirrors it for humans.
 *
 * @dev ⚠️ VERIFY BEFORE MAINNET. These were compiled from official sources (Chainlink `chain-selectors`,
 *      the CCIP directory, LayerZero metadata, the Stargate V2 + USDT0 docs) but addresses change and
 *      docs can be stale. Reconfirm every value you actually use against the official directory for that
 *      chain before broadcasting real funds. Fields that could not be cross-checked are marked VERIFY.
 *
 *      Endpoints are the contracts ON that chain (used when the chain is the deployment HOME); the
 *      selector/eid identify the chain as a DESTINATION. Solana (non-EVM / SVM) carries only its
 *      selector + eid; its EVM-address fields are zero (it is a destination, not an EVM home).
 *      Sources: https://github.com/smartcontractkit/chain-selectors,
 *      https://docs.chain.link/ccip/directory/mainnet, https://docs.layerzero.network,
 *      https://stargateprotocol.gitbook.io/stargate, https://docs.usdt0.to.
 */
library Networks {
  /// @notice The LayerZero EndpointV2, identical across these EVM chains.
  address internal constant LZ_ENDPOINT_V2 = 0x1a44076050125825900e736c501f859c50fE728c;

  /// @notice One chain's interop coordinates + the token endpoints living on it.
  /// @param key            Lowercase chain key used in the deployment config (e.g. "ethereum").
  /// @param chainId        EVM chain id (0 for non-EVM).
  /// @param svm            True for a Solana-VM (non-EVM) chain — CCIP must use the SVM encoding.
  /// @param ccipSelector   Chainlink CCIP chain selector.
  /// @param ccipRouter     CCIP Router on this chain (zero for non-EVM / unknown).
  /// @param lzEid          LayerZero V2 endpoint id.
  /// @param lzEndpoint     LayerZero EndpointV2 on this chain (zero for non-EVM).
  /// @param usdt           Native USDT token (zero if none / non-EVM).
  /// @param usdc           Native USDC token (zero if none / non-EVM).
  /// @param usdt0Oft       USDT0 OFT / OFT-adapter that bridges USDT over LayerZero (zero if none).
  /// @param stargateUsdt   Stargate V2 USDT pool (zero if none).
  /// @param stargateUsdc   Stargate V2 USDC pool (zero if none).
  // Already slot-minimal: every address needs its own slot, so the rule's byte-sum bound is unreachable.
  // solhint-disable-next-line gas-struct-packing
  struct Net {
    string key;
    uint256 chainId;
    bool svm;
    uint64 ccipSelector;
    address ccipRouter;
    uint32 lzEid;
    address lzEndpoint;
    address usdt;
    address usdc;
    address usdt0Oft;
    address stargateUsdt;
    address stargateUsdc;
  }

  error UnknownNetwork(string key);

  /// @notice Resolves a chain key (lowercase) to its {Net} coordinates. Reverts on an unknown key.
  function _get(
    string memory key
  ) internal pure returns (Net memory) {
    bytes32 k = keccak256(bytes(key));

    if (k == keccak256("ethereum")) {
      return Net({
        key: "ethereum",
        chainId: 1,
        svm: false,
        ccipSelector: 5_009_297_550_715_157_269,
        ccipRouter: 0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D,
        lzEid: 30_101,
        lzEndpoint: LZ_ENDPOINT_V2,
        usdt: 0xdAC17F958D2ee523a2206206994597C13D831ec7,
        usdc: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48,
        usdt0Oft: 0x6C96dE32CEa08842dcc4058c14d3aaAD7Fa41dee,
        stargateUsdt: 0x933597a323Eb81cAe705C5bC29985172fd5A3973,
        stargateUsdc: 0xc026395860Db2d07ee33e05fE50ed7bD583189C7
      });
    }
    if (k == keccak256("arbitrum")) {
      return Net({
        key: "arbitrum",
        chainId: 42_161,
        svm: false,
        ccipSelector: 4_949_039_107_694_359_620,
        ccipRouter: 0x141fa059441E0ca23ce184B6A78bafD2A517DdE8,
        lzEid: 30_110,
        lzEndpoint: LZ_ENDPOINT_V2,
        usdt: 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9,
        usdc: 0xaf88d065e77c8cC2239327C5EDb3A432268e5831,
        usdt0Oft: 0x14E4A1B13bf7F943c8ff7C51fb60FA964A298D92,
        stargateUsdt: 0xcE8CcA271Ebc0533920C83d39F417ED6A0abB7D0,
        stargateUsdc: 0xe8CDF27AcD73a434D661C84887215F7598e7d0d3
      });
    }
    if (k == keccak256("optimism")) {
      return Net({
        key: "optimism",
        chainId: 10,
        svm: false,
        ccipSelector: 3_734_403_246_176_062_136,
        ccipRouter: 0x3206695CaE29952f4b0c22a169725a865bc8Ce0f, // VERIFY
        lzEid: 30_111,
        lzEndpoint: LZ_ENDPOINT_V2,
        usdt: 0x01bFF41798a0BcF287b996046Ca68b395DbC1071, // USDT0 token
        usdc: 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85,
        usdt0Oft: 0xF03b4d9AC1D5d1E7c4cEf54C2A313b9fe051A0aD,
        stargateUsdt: 0x19cFCE47eD54a88614648DC3f19A5980097007dD,
        stargateUsdc: address(0) // VERIFY — official source ambiguous; set before use
      });
    }
    if (k == keccak256("base")) {
      return Net({
        key: "base",
        chainId: 8453,
        svm: false,
        ccipSelector: 15_971_525_489_660_198_786,
        ccipRouter: 0x881e3A65B4d4a04dD529061dd0071cf975F58bCD, // VERIFY
        lzEid: 30_184,
        lzEndpoint: LZ_ENDPOINT_V2,
        usdt: address(0), // Base has no canonical USDT
        usdc: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913,
        usdt0Oft: address(0),
        stargateUsdt: address(0),
        stargateUsdc: 0x27a16dc786820B16E5c9028b75B99F6f604b5d26
      });
    }
    if (k == keccak256("polygon")) {
      return Net({
        key: "polygon",
        chainId: 137,
        svm: false,
        ccipSelector: 4_051_577_828_743_386_545,
        ccipRouter: 0x849c5ED5a80F5B408Dd4969b78c2C8fdf0565Bfe, // VERIFY
        lzEid: 30_109,
        lzEndpoint: LZ_ENDPOINT_V2,
        usdt: 0xc2132D05D31c914a87C6611C10748AEb04B58e8F,
        usdc: 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359,
        usdt0Oft: 0x6BA10300f0DC58B7a1e4c0e41f5daBb7D7829e13,
        stargateUsdt: 0xd47b03ee6d86Cf251ee7860FB2ACf9f91B9fD4d7,
        stargateUsdc: 0x9Aa02D4Fae7F58b8E8f34c66E756cC734DAc7fe4
      });
    }
    if (k == keccak256("avalanche")) {
      return Net({
        key: "avalanche",
        chainId: 43_114,
        svm: false,
        ccipSelector: 6_433_500_567_565_415_381,
        ccipRouter: 0xF4c7E640EdA248ef95972845a62bdC74237805dB, // VERIFY
        lzEid: 30_106,
        lzEndpoint: LZ_ENDPOINT_V2,
        usdt: 0x9702230A8Ea53601f5cD2dc00fDBc13d4dF4A8c7,
        usdc: 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E,
        usdt0Oft: address(0),
        stargateUsdt: 0x12dC9256Acc9895B076f6638D628382881e62CeE,
        stargateUsdc: 0x5634c4a5FEd09819E3c46D86A965Dd9447d86e47
      });
    }
    if (k == keccak256("bnb")) {
      return Net({
        key: "bnb",
        chainId: 56,
        svm: false,
        ccipSelector: 11_344_663_589_394_136_015,
        ccipRouter: 0x34B03Cb9086d7D758AC55af71584F81A598759FE, // VERIFY
        lzEid: 30_102,
        lzEndpoint: LZ_ENDPOINT_V2,
        usdt: 0x55d398326f99059fF775485246999027B3197955, // 18 decimals
        usdc: 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d,
        usdt0Oft: address(0),
        stargateUsdt: 0x138EB30f73BC423c6455C53df6D89CB01d9eBc63,
        stargateUsdc: 0x962Bd449E630b0d928f308Ce63f1A21F02576057
      });
    }
    if (k == keccak256("solana")) {
      // Non-EVM: a DESTINATION only. CCIP uses the SVM encoding; LayerZero/Stargate carry a 32-byte
      // recipient. SPL token + program addresses are base58, not EVM — supply per-deployment.
      return Net({
        key: "solana",
        chainId: 0,
        svm: true,
        ccipSelector: 124_615_329_519_749_607,
        ccipRouter: address(0),
        lzEid: 30_168,
        lzEndpoint: address(0),
        usdt: address(0),
        usdc: address(0),
        usdt0Oft: address(0),
        stargateUsdt: address(0),
        stargateUsdc: address(0)
      });
    }

    revert UnknownNetwork(key);
  }
}
