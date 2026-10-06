// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console

import {CrossChainERC4626Adapter} from "../../src/ccip/CrossChainERC4626Adapter.sol";
import {CrossChainERC4626AdapterFactory} from "../../src/ccip/CrossChainERC4626AdapterFactory.sol";
import {CcipScriptBase} from "./CcipScriptBase.sol";

import {console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {VmSafe} from "forge-std/Vm.sol";

/// @notice Deploys a configured `CrossChainERC4626Adapter` through `CrossChainERC4626AdapterFactory` in one broadcast:
/// chain types, vault target, processing toggles, return-leg fees and role handoff. Deploys a new factory unless
/// `FACTORY` points at an existing one.
/// @dev Fill in `.env` at the repo root (see `.env.example`), then:
/// pnpm ccip:deploy --rpc-url $RPC_URL --account deployer --broadcast
///
/// Required env vars: `ROUTER`, `DEFAULT_ADMIN`, `FEE_SETTER`, `FEE_COLLECTOR`, `DEPOSITS_ENABLED`, `REDEEMS_ENABLED`.
/// Optional env vars:
/// - `FACTORY`: existing factory to deploy through (default: deploy a new one).
/// - `VAULT_TARGET`: ERC-4626 vault to allow (default: none). `TARGET_ENABLED` defaults to true when it is set.
/// - `CHAIN_SELECTORS` and `CHAIN_TYPES`: parallel lists; types are 0=NONE, 1=EVM, 2=SVM.
/// - `FEE_DESTINATION_CHAIN_SELECTORS`, `FEE_BRIDGED_TOKENS`, `FEE_VALUES`: parallel return-leg fee rows. The bridged
///   token is the vault share (deposit return) or the underlying (redeem return); the fee is in underlying units.
///   `FEE_ASSETS` is accepted as an alias for `FEE_BRIDGED_TOKENS`.
/// - `DEPLOYMENT_OUT`: JSON output path (default `deployments/ccip/<chainId>.json`; empty disables it). The file
/// is only written with `--broadcast`, so a dry run never records addresses that do not exist on-chain.
contract DeployAndActivateCrossChainERC4626AdapterScript is CcipScriptBase {
  using stdJson for string;

  error InvalidChainType(uint64 chainSelector, uint256 chainType);
  error NotAnErc4626Vault(address vaultTarget);
  error NotACrossChainERC4626AdapterFactory(address factory);

  /// @notice Reads `.env`, validates it, deploys and records the result.
  function run() external returns (CrossChainERC4626AdapterFactory factory, CrossChainERC4626Adapter adapter) {
    CrossChainERC4626AdapterFactory.DeploymentConfig memory config = loadConfig();
    (factory, adapter) = deploy(config, _optionalAddress("FACTORY"));

    string memory out;
    if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume)) {
      out = _envStringOr("DEPLOYMENT_OUT", string.concat("deployments/ccip/", vm.toString(block.chainid), ".json"));
      if (bytes(out).length != 0) _writeDeployment(out, factory, adapter, config);
    } else {
      console2.log("Dry run: nothing was deployed. Re-run with --broadcast to deploy and write the deployment record.");
    }

    _logSummary(factory, adapter, config, out);
    return (factory, adapter);
  }

  /// @notice Parses the deployment config from env vars. Public so tests and tooling can reuse it.
  function loadConfig() public view returns (CrossChainERC4626AdapterFactory.DeploymentConfig memory config) {
    config.router = _requireAddress("ROUTER");
    config.defaultAdmin = _requireAddress("DEFAULT_ADMIN");
    config.feeSetter = _requireAddress("FEE_SETTER");
    config.feeCollector = _requireAddress("FEE_COLLECTOR");
    config.vaultTarget = _optionalAddress("VAULT_TARGET");
    config.targetEnabled = config.vaultTarget != address(0) && vm.envOr("TARGET_ENABLED", true);
    config.depositsEnabled = _requireBool("DEPOSITS_ENABLED");
    config.redeemsEnabled = _requireBool("REDEEMS_ENABLED");
    config.chainConfigs = _loadChainConfigs();
    config.feeConfigs = _loadFeeConfigs();
    return config;
  }

  /// @notice Validates `config` against the target chain, then deploys through `factoryAddress` (or a new factory).
  function deploy(
    CrossChainERC4626AdapterFactory.DeploymentConfig memory config,
    address factoryAddress
  ) public returns (CrossChainERC4626AdapterFactory factory, CrossChainERC4626Adapter adapter) {
    _validate(config, factoryAddress);

    vm.startBroadcast();
    factory = factoryAddress == address(0)
      ? new CrossChainERC4626AdapterFactory()
      : CrossChainERC4626AdapterFactory(factoryAddress);
    adapter = CrossChainERC4626Adapter(payable(factory.deploy(config)));
    vm.stopBroadcast();

    return (factory, adapter);
  }

  function _loadChainConfigs() private view returns (CrossChainERC4626AdapterFactory.ChainConfig[] memory configs) {
    uint256[] memory selectors = _uintArray("CHAIN_SELECTORS");
    uint256[] memory chainTypes = _uintArray("CHAIN_TYPES");
    _requireSameLength("CHAIN_SELECTORS", selectors.length, "CHAIN_TYPES", chainTypes.length);

    configs = new CrossChainERC4626AdapterFactory.ChainConfig[](selectors.length);
    for (uint256 i = 0; i < selectors.length; ++i) {
      uint64 selector = _toUint64("CHAIN_SELECTORS", selectors[i]);
      if (chainTypes[i] > uint256(type(CrossChainERC4626Adapter.ChainType).max)) {
        revert InvalidChainType(selector, chainTypes[i]);
      }
      configs[i] = CrossChainERC4626AdapterFactory.ChainConfig({
        chainSelector: selector, chainType: CrossChainERC4626Adapter.ChainType(chainTypes[i])
      });
    }
    return configs;
  }

  function _loadFeeConfigs() private view returns (CrossChainERC4626AdapterFactory.FeeConfig[] memory configs) {
    uint256[] memory selectors = _uintArray("FEE_DESTINATION_CHAIN_SELECTORS");
    address[] memory tokens = _addressArray("FEE_BRIDGED_TOKENS");
    if (tokens.length == 0) tokens = _addressArray("FEE_ASSETS");
    uint256[] memory values = _uintArray("FEE_VALUES");
    _requireSameLength("FEE_DESTINATION_CHAIN_SELECTORS", selectors.length, "FEE_BRIDGED_TOKENS", tokens.length);
    _requireSameLength("FEE_BRIDGED_TOKENS", tokens.length, "FEE_VALUES", values.length);

    configs = new CrossChainERC4626AdapterFactory.FeeConfig[](selectors.length);
    for (uint256 i = 0; i < selectors.length; ++i) {
      if (tokens[i] == address(0)) revert ZeroAddress("FEE_BRIDGED_TOKENS");
      configs[i] = CrossChainERC4626AdapterFactory.FeeConfig({
        destinationChainSelector: _toUint64("FEE_DESTINATION_CHAIN_SELECTORS", selectors[i]),
        bridgedToken: tokens[i],
        fee: values[i]
      });
    }
    return configs;
  }

  /// @dev Catches the mistakes that would otherwise surface as an opaque revert or a misconfigured adapter.
  function _validate(
    CrossChainERC4626AdapterFactory.DeploymentConfig memory config,
    address factoryAddress
  ) private view {
    _requireCode("ROUTER", config.router);
    if (factoryAddress != address(0)) {
      _requireCode("FACTORY", factoryAddress);
      (bool ok, bytes memory data) = factoryAddress.staticcall(abi.encodeWithSignature("typeAndVersion()"));
      if (
        !ok || keccak256(bytes(abi.decode(data, (string)))) != keccak256(bytes("CrossChainERC4626AdapterFactory 1.0.0"))
      ) {
        revert NotACrossChainERC4626AdapterFactory(factoryAddress);
      }
    }
    if (config.vaultTarget != address(0)) {
      _requireCode("VAULT_TARGET", config.vaultTarget);
      (bool ok, bytes memory data) = config.vaultTarget.staticcall(abi.encodeWithSignature("asset()"));
      if (!ok || data.length != 32 || abi.decode(data, (address)) == address(0)) {
        revert NotAnErc4626Vault(config.vaultTarget);
      }
    }
  }

  function _writeDeployment(
    string memory path,
    CrossChainERC4626AdapterFactory factory,
    CrossChainERC4626Adapter adapter,
    CrossChainERC4626AdapterFactory.DeploymentConfig memory config
  ) private {
    string memory key = "ccip-deployment";
    key.serialize("chainId", block.chainid);
    key.serialize("factory", address(factory));
    key.serialize("router", config.router);
    key.serialize("defaultAdmin", config.defaultAdmin);
    key.serialize("feeSetter", config.feeSetter);
    key.serialize("feeCollector", config.feeCollector);
    key.serialize("vaultTarget", config.vaultTarget);
    key.serialize("depositsEnabled", config.depositsEnabled);
    key.serialize("redeemsEnabled", config.redeemsEnabled);
    string memory json = key.serialize("adapter", address(adapter));
    json.write(path);
  }

  function _logSummary(
    CrossChainERC4626AdapterFactory factory,
    CrossChainERC4626Adapter adapter,
    CrossChainERC4626AdapterFactory.DeploymentConfig memory config,
    string memory out
  ) private pure {
    console2.log("CrossChainERC4626AdapterFactory:", address(factory));
    console2.log("CrossChainERC4626Adapter:       ", address(adapter));
    console2.log("Router:                         ", config.router);
    console2.log("Default admin:                  ", config.defaultAdmin);
    console2.log("Fee setter / collector:         ", config.feeSetter, config.feeCollector);
    console2.log("Vault target (enabled):         ", config.vaultTarget, config.targetEnabled);
    console2.log("Deposits / redeems enabled:     ", config.depositsEnabled, config.redeemsEnabled);
    console2.log("Chain configs / fee rows:       ", config.chainConfigs.length, config.feeConfigs.length);
    if (bytes(out).length != 0) console2.log("Deployment record:              ", out);
    console2.log("");
    console2.log("Next steps:");
    console2.log(" 1. Fund the adapter with native gas for return legs (ADAPTER=<adapter> FUND_NATIVE_WEI=...).");
    console2.log(" 2. For CCIP v2 lanes, set return-lane formats and finality with pnpm ccip:configure.");
    console2.log(" 3. Verify the result with pnpm ccip:check.");
  }

  function _envStringOr(
    string memory name,
    string memory defaultValue
  ) private view returns (string memory) {
    return vm.envExists(name) ? vm.envString(name) : defaultValue;
  }
}
