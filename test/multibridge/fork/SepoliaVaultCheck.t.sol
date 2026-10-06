// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Test} from "forge-std/Test.sol";

contract SepoliaVaultCheck is Test {
  function test_VaultAssetOnSepoliaFork() public {
    vm.createSelectFork(vm.envOr("HUB_RPC_URL", string("https://ethereum-sepolia-rpc.publicnode.com")));
    address asset = IERC4626(0x9cdaf9FBD293E3C7AfFAd34f4bcD947b2296fc14).asset();
    assertEq(asset, 0xF3F2b4815A58152c9BE53250275e8211163268BA);
  }
}
