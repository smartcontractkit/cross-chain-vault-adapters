// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReturnLegFeeConfig} from "../../../script/multibridge/config/ReturnLegFeeConfig.sol";
import {CrossChainVaultAdapterFactory} from "../../../src/multibridge/CrossChainVaultAdapterFactory.sol";
import {DeployConfig} from "../../../src/multibridge/VaultAdapterFactoryBase.sol";
import {CrossChainVaultAdapter} from "../../../src/multibridge/examples/CrossChainVaultAdapter.sol";
import {RouteRegistry} from "../../../src/multibridge/routing/RouteRegistry.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {Test} from "forge-std/Test.sol";

contract SepoliaDeployConfigReader is ReturnLegFeeConfig {
  function loadReturnLegFees(
    DeployConfig memory cfg,
    string memory json,
    string memory basePath,
    address asset,
    address share
  ) external view returns (DeployConfig memory) {
    return _readReturnLegFees(cfg, json, basePath, asset, share);
  }
}

contract SepoliaFactoryDeployTest is Test {
  using stdJson for string;

  function test_DeployViaFactoryOnSepoliaFork() public {
    vm.createSelectFork(vm.envOr("HUB_RPC_URL", string("https://ethereum-sepolia-rpc.publicnode.com")));
    string memory json = vm.readFile("config/multibridge/sepolia.json");
    address deployer = vm.envOr("DEPLOYER", address(0x2945c29Bfea4e9C03B5AAb2283CB49792dEb2a62));
    vm.deal(deployer, 1 ether);

    // Deploy a fresh factory + implementation on the fork — the pinned on-chain factory ABI
    // may lag behind the local {DeployConfig} (e.g. when a config field is added or removed).
    CrossChainVaultAdapter implementation = new CrossChainVaultAdapter();
    address factory = address(new CrossChainVaultAdapterFactory(address(implementation)));

    DeployConfig memory cfg;
    cfg.ccipRouter = json.readAddress(".hub.ccipRouter");
    cfg.lzEndpoint = json.readAddress(".hub.lzEndpoint");
    cfg.owner = deployer;
    cfg.vault = json.readAddress(".vaultAdapter.vault");
    cfg.lzSrcEids = _u32(json.readUintArray(".vaultAdapter.lzSrcEids"));
    cfg.lzSrcOfts = json.readAddressArray(".vaultAdapter.lzSrcOfts");
    cfg.ccipSrcSelectors = _u64(json.readUintArray(".vaultAdapter.ccipSrcSelectors"));
    cfg.ccipDstSelectors = _u64(json.readUintArray(".vaultAdapter.ccipDstSelectors"));
    cfg.lzDstEids = _u32(json.readUintArray(".vaultAdapter.lzDstEids"));
    cfg.oftTokens = json.readAddressArray(".vaultAdapter.oftTokens");
    cfg.ofts = json.readAddressArray(".vaultAdapter.ofts");
    cfg = SepoliaDeployConfigReader(address(new SepoliaDeployConfigReader()))
      .loadReturnLegFees(
        cfg, json, ".vaultAdapter", json.readAddress(".vaultAdapter.asset"), json.readAddress(".vaultAdapter.share")
      );

    vm.prank(deployer);
    address app = CrossChainVaultAdapterFactory(factory).deploy{value: 0.1 ether}(cfg);
    assertTrue(RouteRegistry(payable(app)).hasRole(RouteRegistry(payable(app)).DEFAULT_ADMIN_ROLE(), deployer));
  }

  function _u32(
    uint256[] memory xs
  ) internal pure returns (uint32[] memory out) {
    out = new uint32[](xs.length);
    for (uint256 i; i < xs.length; ++i) {
      out[i] = uint32(xs[i]);
    }
    return out;
  }

  function _u64(
    uint256[] memory xs
  ) internal pure returns (uint64[] memory out) {
    out = new uint64[](xs.length);
    for (uint256 i; i < xs.length; ++i) {
      out[i] = uint64(xs[i]);
    }
    return out;
  }
}
