// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {DeployProduction} from "../../../script/multibridge/DeployProduction.s.sol";
import {Networks} from "../../../script/multibridge/config/Networks.sol";
import {RouteRegistry} from "../../../src/multibridge/routing/RouteRegistry.sol";

/// @notice Validates the {DeployProduction} resolver: the high-level home + routes config is joined
///         against the {Networks} address book into the right selectors/EIDs/endpoints/allowlists, with
///         no broadcasting. NB: route objects must carry ONLY the struct keys — `vm.parseJson` decodes a
///         struct array positionally by alphabetical key, so an extra key (e.g. `_comment`) shifts it.
contract DeployProductionResolveTest is Test {
  DeployProduction internal s_sut;

  address internal constant OWNER = 0x00000000000000000000000000000000000000A1;
  address internal constant VAULT = 0x00000000000000000000000000000000000000b2;
  address internal constant ASSET = 0xdAC17F958D2ee523a2206206994597C13D831ec7; // ETH USDT
  address internal constant ASSET_OFT = 0x6C96dE32CEa08842dcc4058c14d3aaAD7Fa41dee; // USDT0 adapter
  address internal constant SHARE_OFT = 0x00000000000000000000000000000000000000C3;
  address internal constant DEPLOYER = 0x00000000000000000000000000000000DeaDBeef;

  function setUp() public {
    s_sut = new DeployProduction();
  }

  function _json() internal pure returns (string memory) {
    // Home = Ethereum, asset = USDT. Routes exercise every rail.
    return string.concat(
      "{\"home\":{",
      "\"network\":\"ethereum\",",
      "\"owner\":\"0x00000000000000000000000000000000000000A1\",",
      "\"vault\":\"0x00000000000000000000000000000000000000b2\",",
      "\"asset\":\"0xdAC17F958D2ee523a2206206994597C13D831ec7\",",
      "\"assetSymbol\":\"USDT\",",
      "\"assetOft\":\"0x6C96dE32CEa08842dcc4058c14d3aaAD7Fa41dee\",",
      "\"share\":\"0x00000000000000000000000000000000000000b2\",",
      "\"shareOft\":\"0x00000000000000000000000000000000000000C3\",",
      "\"fundWei\":1000,\"defaultSvmComputeUnits\":7},",
      "\"routes\":[",
      "{\"network\":\"arbitrum\",\"token\":\"asset\",\"rail\":\"LZ_OFT\"},",
      "{\"network\":\"bnb\",\"token\":\"asset\",\"rail\":\"STARGATE\"},",
      "{\"network\":\"solana\",\"token\":\"asset\",\"rail\":\"LZ_OFT\"},",
      "{\"network\":\"optimism\",\"token\":\"share\",\"rail\":\"CCIP\"},",
      "{\"network\":\"solana\",\"token\":\"share\",\"rail\":\"CCIP_SVM\"}",
      "],",
      "\"inbound\":{\"lzSrcEids\":[30110],\"lzSrcOfts\":[\"0x6C96dE32CEa08842dcc4058c14d3aaAD7Fa41dee\"],",
      "\"ccipSrcSelectors\":[]}}"
    );
  }

  function test_Resolve_Header_FromAddressBook() public view {
    DeployProduction.Plan memory p = s_sut.resolve(_json(), DEPLOYER);
    Networks.Net memory eth = Networks._get("ethereum");

    assertEq(p.cfg.ccipRouter, eth.ccipRouter, "home ccip router from address book");
    assertEq(p.cfg.lzEndpoint, eth.lzEndpoint, "home lz endpoint from address book");
    assertEq(p.cfg.owner, DEPLOYER, "temp owner = deployer");
    assertEq(p.cfg.vault, VAULT, "vault");
    assertEq(p.realOwner, OWNER, "real owner");
    assertEq(p.fundWei, 1000, "fund wei");
  }

  function test_Resolve_OftMap() public view {
    DeployProduction.Plan memory p = s_sut.resolve(_json(), DEPLOYER);
    assertEq(p.cfg.oftTokens.length, 2, "asset + share oft");
    assertEq(p.cfg.oftTokens[0], ASSET);
    assertEq(p.cfg.ofts[0], ASSET_OFT);
    assertEq(p.cfg.oftTokens[1], VAULT);
    assertEq(p.cfg.ofts[1], SHARE_OFT);
  }

  function test_Resolve_Routes_AllRails() public view {
    DeployProduction.Plan memory p = s_sut.resolve(_json(), DEPLOYER);
    assertEq(p.routes.length, 5, "five routes");

    // 0: arbitrum / asset / LZ_OFT
    assertEq(uint8(p.routes[0].route.rail), uint8(RouteRegistry.Rail.LZ_OFT));
    assertEq(p.routes[0].token, ASSET);
    assertEq(p.routes[0].destination, Networks._get("arbitrum").lzEid); // 30110
    assertEq(p.routes[0].route.endpoint, ASSET_OFT, "LZ asset endpoint = assetOft");

    // 1: bnb / asset / STARGATE -> endpoint = ETH USDT pool, dst = bnb EID
    assertEq(uint8(p.routes[1].route.rail), uint8(RouteRegistry.Rail.STARGATE));
    assertEq(p.routes[1].destination, Networks._get("bnb").lzEid); // 30102
    assertEq(p.routes[1].route.endpoint, Networks._get("ethereum").stargateUsdt, "stargate pool on home");

    // 2: solana / asset / LZ_OFT (32-byte recipient handled at send time)
    assertEq(p.routes[2].destination, Networks._get("solana").lzEid); // 30168

    // 3: optimism / share / CCIP -> selector, no endpoint
    assertEq(uint8(p.routes[3].route.rail), uint8(RouteRegistry.Rail.CCIP));
    assertEq(p.routes[3].token, VAULT, "share token");
    assertEq(p.routes[3].destination, Networks._get("optimism").ccipSelector);
    assertEq(p.routes[3].route.endpoint, address(0), "CCIP has no endpoint");

    // 4: solana / share / CCIP_SVM -> Solana selector
    assertEq(uint8(p.routes[4].route.rail), uint8(RouteRegistry.Rail.CCIP_SVM));
    assertEq(p.routes[4].destination, Networks._get("solana").ccipSelector); // 124615329519749607
  }

  function test_Resolve_OutboundAllowlists() public view {
    DeployProduction.Plan memory p = s_sut.resolve(_json(), DEPLOYER);

    // CCIP dests: optimism (CCIP) + solana (CCIP_SVM)
    assertEq(p.cfg.ccipDstSelectors.length, 2, "two ccip dests");
    // LZ dests: arbitrum + solana (two LZ_OFT routes)
    assertEq(p.cfg.lzDstEids.length, 2, "two lz dests");
    // Stargate dests: bnb
    assertEq(p.stargateDstEids.length, 1, "one stargate dest");
    assertEq(p.stargateDstEids[0], Networks._get("bnb").lzEid);
    // SVM lanes: solana CCIP_SVM, carrying the default compute units
    assertEq(p.svmCfgs.length, 1, "one svm lane");
    assertEq(p.svmCfgs[0].selector, Networks._get("solana").ccipSelector);
    assertEq(p.svmCfgs[0].computeUnits, 7, "default svm compute units");
  }

  function test_Resolve_LocalRoute() public view {
    // A LOCAL route: same-chain delivery, keyed at destination 0, no endpoint/dstId/allowlist.
    string memory j = string.concat(
      "{\"home\":{\"network\":\"ethereum\",\"owner\":\"0x00000000000000000000000000000000000000A1\",",
      "\"vault\":\"0x00000000000000000000000000000000000000b2\",",
      "\"asset\":\"0xdAC17F958D2ee523a2206206994597C13D831ec7\",\"assetSymbol\":\"USDT\",",
      "\"share\":\"0x00000000000000000000000000000000000000b2\"},",
      "\"routes\":[{\"network\":\"ethereum\",\"token\":\"share\",\"rail\":\"LOCAL\"}]}"
    );
    DeployProduction.Plan memory p = s_sut.resolve(j, DEPLOYER);

    assertEq(p.routes.length, 1, "one route");
    assertEq(uint8(p.routes[0].route.rail), uint8(RouteRegistry.Rail.LOCAL), "LOCAL rail");
    assertEq(p.routes[0].destination, 0, "keyed at LOCAL_DESTINATION (0)");
    assertEq(p.routes[0].token, VAULT, "produces the share token");
    assertEq(p.routes[0].route.endpoint, address(0), "no endpoint");
    // LOCAL contributes to no outbound allowlist.
    assertEq(p.cfg.ccipDstSelectors.length, 0, "no ccip dest");
    assertEq(p.cfg.lzDstEids.length, 0, "no lz dest");
    assertEq(p.stargateDstEids.length, 0, "no stargate dest");
    assertEq(p.svmCfgs.length, 0, "no svm lane");
  }

  function test_Resolve_ReturnLegFees() public view {
    string memory j = string.concat(
      "{\"home\":{\"network\":\"ethereum\",\"owner\":\"0x00000000000000000000000000000000000000A1\",",
      "\"vault\":\"0x00000000000000000000000000000000000000b2\",",
      "\"asset\":\"0xdAC17F958D2ee523a2206206994597C13D831ec7\",\"assetSymbol\":\"USDT\",",
      "\"share\":\"0x00000000000000000000000000000000000000b2\"},",
      "\"routes\":[{\"network\":\"optimism\",\"token\":\"share\",\"rail\":\"CCIP\"}],",
      "\"returnLegFees\":{\"requireLzReturnPrefunded\":true,",
      "\"inboundFees\":[{\"outboundToken\":\"share\",\"destination\":3734403246176062136,\"fee\":5000000}]}}"
    );
    DeployProduction.Plan memory p = s_sut.resolve(j, DEPLOYER);
    assertTrue(p.cfg.requireLzReturnPrefunded, "lz prefund");
    assertEq(p.cfg.inboundFeeOutboundTokens.length, 1, "one inbound fee");
    assertEq(p.cfg.inboundFeeOutboundTokens[0], VAULT, "share outbound");
    assertEq(p.cfg.inboundFeeDestinations[0], 3734403246176062136, "dest");
    assertEq(p.cfg.inboundFeeAmounts[0], 5_000_000, "fee");
  }

  function test_Resolve_ReturnLegFees_Optional() public view {
    DeployProduction.Plan memory p = s_sut.resolve(_json(), DEPLOYER);
    assertFalse(p.cfg.requireLzReturnPrefunded, "default off");
    assertEq(p.cfg.inboundFeeOutboundTokens.length, 0, "no fees");
  }

  function test_Resolve_Reverts_StargateShare() public {
    string memory bad = string.concat(
      "{\"home\":{\"network\":\"ethereum\",\"owner\":\"0x00000000000000000000000000000000000000A1\",",
      "\"vault\":\"0x00000000000000000000000000000000000000b2\",",
      "\"asset\":\"0xdAC17F958D2ee523a2206206994597C13D831ec7\",\"assetSymbol\":\"USDT\",",
      "\"assetOft\":\"0x6C96dE32CEa08842dcc4058c14d3aaAD7Fa41dee\",",
      "\"share\":\"0x00000000000000000000000000000000000000b2\",\"shareOft\":\"0x00000000000000000000000000000000000000C3\"},",
      "\"routes\":[{\"network\":\"bnb\",\"token\":\"share\",\"rail\":\"STARGATE\"}]}"
    );
    vm.expectRevert(abi.encodeWithSelector(DeployProduction.StargateRailNeedsAssetPool.selector, "bnb"));
    s_sut.resolve(bad, DEPLOYER);
  }
}
