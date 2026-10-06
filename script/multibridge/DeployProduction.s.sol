// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console

import {Script} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {console2} from "forge-std/console2.sol";

import {CrossChainVaultAdapterFactory} from "../../src/multibridge/CrossChainVaultAdapterFactory.sol";
import {DeployConfig, VaultAdapterFactoryBase} from "../../src/multibridge/VaultAdapterFactoryBase.sol";
import {CrossChainVaultAdapter} from "../../src/multibridge/examples/CrossChainVaultAdapter.sol";
import {RouteRegistry} from "../../src/multibridge/routing/RouteRegistry.sol";
import {Networks} from "./config/Networks.sol";
import {ReturnLegFeeConfig} from "./config/ReturnLegFeeConfig.sol";

/**
 * @title DeployProduction
 * @notice Production deploy + full-configure of a {CrossChainVaultAdapter} from a single high-level config
 *         (`config/multibridge/deployment.json`, schema in `config/multibridge/deployment.example.json`): a HOME chain
 * (where
 * the
 *         ERC-4626 vault lives), the vault, and a list of OUTBOUND routes — each a (supported network,
 *         token, bridge rail) — resolved into concrete selectors/EIDs/endpoints via the {Networks} address
 *         book. Selectors, EIDs, routers, endpoints and Stargate/USDT0 pools are looked up by chain key,
 *         so the operator never pastes raw interop addresses.
 *
 * @dev Flow (one broadcast): clone the official implementation via the factory with the DEPLOYER as the
 *      temporary admin, install the route registry (routes + Stargate/SVM/allowlists the factory does not
 *      cover), then `transferAdmin` to the real admin when they differ. The DEPLOYER key (the broadcaster)
 *      receives `DEFAULT_ADMIN_ROLE` from `factory.deploy`.
 *
 *      forge script script/multibridge/DeployProduction.s.sol:DeployProduction \
 *        --rpc-url $HOME_RPC_URL --private-key $DEPLOYER_KEY --broadcast --slow
 *
 *      Config path defaults to `config/multibridge/deployment.json` (override with `CONFIG`). See
 *      docs/multibridge/operator/DEPLOYMENT_CONFIG.md. Designed for Tenderly Virtual TestNet mainnet forks.
 */
contract DeployProduction is Script, ReturnLegFeeConfig {
  using stdJson for string;

  /// @notice One decoded entry of the config `routes[]`. Field order is ALPHABETICAL — required for
  ///         `vm.parseJson` ABI decoding. `token` is "asset" or "share"; `rail` is one of
  ///         "LZ_OFT" | "CCIP" | "STARGATE" | "CCIP_SVM".
  struct RouteSpec {
    string network;
    string rail;
    string token;
  }

  /// @notice A resolved CCIP→Solana (SVM) lane config to apply post-handoff.
  struct SvmCfg {
    uint64 selector;
    uint32 computeUnits;
  }

  /// @notice A resolved route registry entry to apply post-handoff.
  struct RouteEntry {
    address token;
    uint64 destination;
    RouteRegistry.Route route;
  }

  /// @notice The fully resolved deployment plan: the factory config (clone + inbound + outbound dest
  ///         allowlists + OFT map, owner = deployer) plus the registry extras the factory cannot set.
  struct Plan {
    DeployConfig cfg;
    uint32[] stargateDstEids;
    SvmCfg[] svmCfgs;
    RouteEntry[] routes;
    uint256 fundWei;
    address realOwner;
  }

  /// @dev Home-side inputs needed to resolve each route's endpoint/dstId (bundled to dodge stack limits).
  // Already slot-minimal: every address needs its own slot, so the rule's byte-sum bound is unreachable.
  // solhint-disable-next-line gas-struct-packing
  struct Ctx {
    address asset;
    address share;
    string assetSymbol;
    address assetOft;
    address shareOft;
    uint32 defaultSvmCu;
    address stargateUsdt;
    address stargateUsdc;
  }

  /// @dev The route-derived outputs of {_resolveRoutes}.
  struct RouteBundle {
    uint64[] ccipDstSelectors;
    uint32[] lzDstEids;
    uint32[] stargateDstEids;
    SvmCfg[] svmCfgs;
    RouteEntry[] routes;
  }

  error UnknownRail(string rail);
  error StargateRailNeedsAssetPool(string network);
  error EndpointNotConfigured(string what);
  error NotAnSvmChain(string network);

  function run() external returns (address app, address factory, address implementation) {
    string memory json = _loadConfig();
    // The deployer MUST be `config.owner` during `deploy` so it receives {DEFAULT_ADMIN_ROLE} and can
    // install the route registry. With `--private-key`/`--sender`, that is `msg.sender`; override via
    // the `DEPLOYER` env if your setup differs.
    address deployer = vm.envOr("DEPLOYER", msg.sender);
    Plan memory plan = resolve(json, deployer);

    Networks.Net memory home = Networks._get(json.readString(".home.network"));
    address cfgFactory = json.readAddressOr(".home.factory", address(0));
    address cfgImpl = json.readAddressOr(".home.implementation", address(0));

    vm.startBroadcast();

    implementation = cfgImpl;
    if (cfgFactory != address(0)) {
      factory = cfgFactory;
    } else {
      if (implementation == address(0)) {
        implementation = address(new CrossChainVaultAdapter());
      }
      factory = address(new CrossChainVaultAdapterFactory(implementation));
    }

    // Clone + initialize + factory-side config, with the deployer as temporary admin.
    app = VaultAdapterFactoryBase(factory).deploy{value: plan.fundWei}(plan.cfg);

    // Install the route registry entries the factory does not cover.
    RouteRegistry a = RouteRegistry(payable(app));

    for (uint256 i; i < plan.stargateDstEids.length; ++i) {
      a.setStargateDestination(plan.stargateDstEids[i], true);
    }
    for (uint256 i; i < plan.svmCfgs.length; ++i) {
      a.setCcipSvmConfig(plan.svmCfgs[i].selector, true, plan.svmCfgs[i].computeUnits);
    }
    for (uint256 i; i < plan.routes.length; ++i) {
      a.setRoute(plan.routes[i].token, plan.routes[i].destination, plan.routes[i].route);
    }

    if (plan.realOwner != deployer) {
      // Hand off admin AND the fee roles the deployer held during setup, so no privilege is stranded.
      address feeCollector = plan.cfg.feeCollector == address(0) ? plan.realOwner : plan.cfg.feeCollector;
      a.transferAdmin(plan.realOwner, plan.realOwner, feeCollector);
    }

    vm.stopBroadcast();

    _writeDeployment(home.chainId, app, factory, implementation, plan);
    console2.log("home chainId:       ", home.chainId);
    console2.log("implementation:     ", implementation);
    console2.log("factory:            ", factory);
    console2.log("vault adapter (clone):  ", app);
    console2.log("routes installed:   ", plan.routes.length);
    console2.log("admin:              ", plan.realOwner);
    return (app, factory, implementation);
  }

  /*//////////////////////////////////////////////////////////////
                              RESOLVER
  //////////////////////////////////////////////////////////////*/

  /// @notice Pure-ish (cheatcode-reading) resolver: turns the config JSON into a {Plan}. Exposed and
  ///         broadcast-free so it can be unit-tested. `deployer` becomes the factory config's temporary
  ///         owner.
  function resolve(
    string memory json,
    address deployer
  ) public view returns (Plan memory plan) {
    plan.realOwner = json.readAddress(".home.owner");
    plan.fundWei = json.readUintOr(".home.fundWei", 0);

    plan.cfg = _factoryConfig(json, deployer);
    RouteBundle memory b = _resolveRoutes(json);
    plan.cfg.ccipDstSelectors = b.ccipDstSelectors;
    plan.cfg.lzDstEids = b.lzDstEids;
    plan.stargateDstEids = b.stargateDstEids;
    plan.svmCfgs = b.svmCfgs;
    plan.routes = b.routes;
    return plan;
  }

  /// @dev Builds the factory {DeployConfig} header: home router/endpoint, deployer as temp owner, vault,
  ///      inbound allowlists, and the (asset/share => OFT) map. Outbound dest arrays are filled by the
  ///      route resolver.
  function _factoryConfig(
    string memory json,
    address deployer
  ) internal view returns (DeployConfig memory cfg) {
    Networks.Net memory home = Networks._get(json.readString(".home.network"));
    cfg.ccipRouter = home.ccipRouter;
    cfg.lzEndpoint = home.lzEndpoint;
    cfg.owner = deployer;
    cfg.feeCollector = json.readAddressOr(".home.feeCollector", address(0));
    cfg.vault = json.readAddress(".home.vault");
    cfg.lzSrcEids = _u32(json.readUintArrayOr(".inbound.lzSrcEids", new uint256[](0)));
    cfg.lzSrcOfts = json.readAddressArrayOr(".inbound.lzSrcOfts", new address[](0));
    cfg.ccipSrcSelectors = _u64(json.readUintArrayOr(".inbound.ccipSrcSelectors", new uint256[](0)));
    (cfg.oftTokens, cfg.ofts) = _oftMap(
      json.readAddress(".home.asset"),
      json.readAddressOr(".home.assetOft", address(0)),
      json.readAddress(".home.share"),
      json.readAddressOr(".home.shareOft", address(0))
    );
    cfg =
      _readReturnLegFees(cfg, json, ".returnLegFees", json.readAddress(".home.asset"), json.readAddress(".home.share"));
    return cfg;
  }

  /// @dev Resolves the `routes[]` into per-rail outbound allowlists + registry entries.
  function _resolveRoutes(
    string memory json
  ) internal view returns (RouteBundle memory b) {
    Ctx memory ctx = _ctx(json);
    RouteSpec[] memory specs = _readRoutes(json);
    uint256 n = specs.length;

    // Over-allocate (length = #routes), fill, then trim per category.
    b.ccipDstSelectors = new uint64[](n);
    b.lzDstEids = new uint32[](n);
    b.stargateDstEids = new uint32[](n);
    b.svmCfgs = new SvmCfg[](n);
    b.routes = new RouteEntry[](n);
    uint256[4] memory cnt; // [ccip, lz, sg, svm]

    for (uint256 i; i < n; ++i) {
      b.routes[i] = _resolveOne(ctx, specs[i], b, cnt);
    }

    b.ccipDstSelectors = _trim64(b.ccipDstSelectors, cnt[0]);
    b.lzDstEids = _trim32(b.lzDstEids, cnt[1]);
    b.stargateDstEids = _trim32(b.stargateDstEids, cnt[2]);
    b.svmCfgs = _trimSvm(b.svmCfgs, cnt[3]);
    return b;
  }

  /// @dev Resolves one route spec, recording its outbound-allowlist contribution into `b`/`cnt`.
  function _resolveOne(
    Ctx memory ctx,
    RouteSpec memory s,
    RouteBundle memory b,
    uint256[4] memory cnt
  ) internal pure returns (RouteEntry memory entry) {
    bool isShare = _eq(s.token, "share");
    RouteRegistry.Rail rail = _rail(s.rail);

    // LOCAL: same-chain delivery — no dest network, endpoint, dstId, or allowlist. Keyed at 0.
    if (rail == RouteRegistry.Rail.LOCAL) {
      return RouteEntry({
        token: isShare ? ctx.share : ctx.asset,
        destination: 0, // CrossChainVaultAdapter.LOCAL_DESTINATION
        route: RouteRegistry.Route({enabled: true, rail: rail, endpoint: address(0), dstId: 0})
      });
    }

    Networks.Net memory dst = Networks._get(s.network);
    address endpoint;
    uint64 dstId;
    if (rail == RouteRegistry.Rail.STARGATE) {
      if (isShare) revert StargateRailNeedsAssetPool(s.network);
      endpoint = _eq(ctx.assetSymbol, "USDC") ? ctx.stargateUsdc : ctx.stargateUsdt;
      if (endpoint == address(0)) revert EndpointNotConfigured("stargate pool on home");
      dstId = dst.lzEid;
      b.stargateDstEids[cnt[2]++] = dst.lzEid;
    } else if (rail == RouteRegistry.Rail.LZ_OFT) {
      endpoint = isShare ? ctx.shareOft : ctx.assetOft;
      if (endpoint == address(0)) revert EndpointNotConfigured("OFT for token");
      dstId = dst.lzEid;
      b.lzDstEids[cnt[1]++] = dst.lzEid;
    } else if (rail == RouteRegistry.Rail.CCIP_SVM) {
      if (!dst.svm) revert NotAnSvmChain(s.network);
      dstId = dst.ccipSelector;
      b.ccipDstSelectors[cnt[0]++] = dst.ccipSelector;
      b.svmCfgs[cnt[3]++] = SvmCfg({selector: dst.ccipSelector, computeUnits: ctx.defaultSvmCu});
    } else {
      // Rail.CCIP (EVM)
      dstId = dst.ccipSelector;
      b.ccipDstSelectors[cnt[0]++] = dst.ccipSelector;
    }

    entry = RouteEntry({
      token: isShare ? ctx.share : ctx.asset,
      destination: dstId,
      route: RouteRegistry.Route({enabled: true, rail: rail, endpoint: endpoint, dstId: dstId})
    });
    return entry;
  }

  function _ctx(
    string memory json
  ) internal view returns (Ctx memory ctx) {
    Networks.Net memory home = Networks._get(json.readString(".home.network"));
    ctx.asset = json.readAddress(".home.asset");
    ctx.share = json.readAddress(".home.share");
    ctx.assetSymbol = json.readString(".home.assetSymbol");
    ctx.assetOft = json.readAddressOr(".home.assetOft", address(0));
    ctx.shareOft = json.readAddressOr(".home.shareOft", address(0));
    ctx.defaultSvmCu = uint32(json.readUintOr(".home.defaultSvmComputeUnits", 0));
    ctx.stargateUsdt = home.stargateUsdt;
    ctx.stargateUsdc = home.stargateUsdc;
    return ctx;
  }

  /*//////////////////////////////////////////////////////////////
                              HELPERS
  //////////////////////////////////////////////////////////////*/

  function _loadConfig() internal view returns (string memory) {
    return vm.readFile(vm.envOr("CONFIG", string("config/multibridge/deployment.json")));
  }

  function _readRoutes(
    string memory json
  ) internal pure returns (RouteSpec[] memory specs) {
    bytes memory raw = vm.parseJson(json, ".routes");
    specs = abi.decode(raw, (RouteSpec[]));
    return specs;
  }

  function _rail(
    string memory r
  ) internal pure returns (RouteRegistry.Rail) {
    bytes32 h = keccak256(bytes(r));
    if (h == keccak256("LZ_OFT")) return RouteRegistry.Rail.LZ_OFT;
    if (h == keccak256("CCIP")) return RouteRegistry.Rail.CCIP;
    if (h == keccak256("LOCAL")) return RouteRegistry.Rail.LOCAL;
    if (h == keccak256("STARGATE")) return RouteRegistry.Rail.STARGATE;
    if (h == keccak256("CCIP_SVM")) return RouteRegistry.Rail.CCIP_SVM;
    revert UnknownRail(r);
  }

  function _eq(
    string memory a,
    string memory b
  ) internal pure returns (bool) {
    return keccak256(bytes(a)) == keccak256(bytes(b));
  }

  /// @dev Builds the (token => OFT) map from the asset/share OFTs that are set (non-zero).
  function _oftMap(
    address asset,
    address assetOft,
    address share,
    address shareOft
  ) internal pure returns (address[] memory tokens, address[] memory ofts) {
    uint256 n = (assetOft != address(0) ? 1 : 0) + (shareOft != address(0) ? 1 : 0);
    tokens = new address[](n);
    ofts = new address[](n);
    uint256 j;
    if (assetOft != address(0)) {
      tokens[j] = asset;
      ofts[j++] = assetOft;
    }
    if (shareOft != address(0)) {
      tokens[j] = share;
      ofts[j++] = shareOft;
    }
    return (tokens, ofts);
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

  function _trim32(
    uint32[] memory xs,
    uint256 n
  ) internal pure returns (uint32[] memory out) {
    out = new uint32[](n);
    for (uint256 i; i < n; ++i) {
      out[i] = xs[i];
    }
    return out;
  }

  function _trim64(
    uint64[] memory xs,
    uint256 n
  ) internal pure returns (uint64[] memory out) {
    out = new uint64[](n);
    for (uint256 i; i < n; ++i) {
      out[i] = xs[i];
    }
    return out;
  }

  function _trimSvm(
    SvmCfg[] memory xs,
    uint256 n
  ) internal pure returns (SvmCfg[] memory out) {
    out = new SvmCfg[](n);
    for (uint256 i; i < n; ++i) {
      out[i] = xs[i];
    }
    return out;
  }

  function _writeDeployment(
    uint256 chainId,
    address app,
    address factory,
    address implementation,
    Plan memory plan
  ) internal {
    string memory obj = "deployment";
    obj.serialize("chainId", chainId);
    obj.serialize("app", app);
    obj.serialize("factory", factory);
    obj.serialize("owner", plan.realOwner);
    obj.serialize("routes", plan.routes.length);
    string memory out = obj.serialize("implementation", implementation);
    string memory path = string.concat("deployments/multibridge/", vm.toString(chainId), ".json");
    out.write(path);
    console2.log("wrote deployment ->", path);
  }
}
