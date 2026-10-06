// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title MockUsdt
 * @notice Test-only faithful double for **native Tether USDT** — the real token is NOT a standard
 *         ERC-20. Reproduces the quirks our router must tolerate (mirrors the deployed Ethereum
 *         `TetherToken` behaviour):
 *           - `transfer` / `transferFrom` / `approve` return **NO boolean** (a bare `IERC20` call that
 *             expects a bool reverts; `SafeERC20` is required);
 *           - the **approve race**: `approve(spender, v)` reverts when the current allowance is non-zero
 *             and `v` is non-zero (must zero first; this is what `forceApprove` handles);
 *           - a **latent transfer fee** (`basisPointsRate` / `maximumFee`, today 0 on mainnet) — so a
 *             defensive router must measure balance deltas, not trust the input amount;
 *           - a **blocklist** that can freeze an address.
 *         Configurable `decimals` so the same contract doubles for Ethereum USDT (6) and other native
 *         USDT forms. NOT for production.
 * @dev Deliberately does NOT inherit `IERC20` — its `transfer`/`approve`/`transferFrom` intentionally
 *      have no return value, exactly like the real USDT. Selectors still match, so `SafeERC20` works.
 */
contract MockUsdt {
  string public name;
  string public symbol;
  uint8 private immutable i_decimals;
  uint256 public totalSupply;

  mapping(address account => uint256 balance) public balanceOf;
  mapping(address owner => mapping(address spender => uint256 value)) public allowance;
  mapping(address account => bool blocked) public isBlackListed;

  /// @notice Latent fee parameters (Tether's `basisPointsRate` ≤ 20 and `maximumFee`; both 0 today).
  uint256 public basisPointsRate;
  uint256 public maximumFee;
  /// @notice Receives any charged fee (the Tether "owner"); set to the deployer.
  address public owner;

  event Transfer(address indexed from, address indexed to, uint256 value);
  event Approval(address indexed owner, address indexed spender, uint256 value);

  error UsdtApproveRace();
  error UsdtBlocked(address account);
  error UsdtInsufficientBalance();
  error UsdtInsufficientAllowance();
  error UsdtBpsTooHigh();

  constructor(
    string memory _name,
    string memory _symbol,
    uint8 _decimals
  ) {
    name = _name;
    symbol = _symbol;
    i_decimals = _decimals;
    owner = msg.sender;
  }

  /// @notice ERC-20 metadata getter (configurable per native USDT form).
  function decimals() external view returns (uint8) {
    return i_decimals;
  }

  // --- Non-standard ERC-20 surface (no boolean returns) ---

  function transfer(
    address to,
    uint256 value
  ) external {
    _transfer(msg.sender, to, value);
  }

  function transferFrom(
    address from,
    address to,
    uint256 value
  ) external {
    uint256 allowed = allowance[from][msg.sender];
    if (allowed < value) revert UsdtInsufficientAllowance();
    // The real USDT decrements allowance (no max-uint infinite-approve special case).
    allowance[from][msg.sender] = allowed - value;
    _transfer(from, to, value);
  }

  /// @dev The infamous approve race: must reset to 0 before setting a new non-zero allowance.
  function approve(
    address spender,
    uint256 value
  ) external {
    if (value != 0 && allowance[msg.sender][spender] != 0) revert UsdtApproveRace();
    allowance[msg.sender][spender] = value;
    emit Approval(msg.sender, spender, value);
  }

  // --- Test / admin helpers ---

  function mint(
    address to,
    uint256 value
  ) external {
    totalSupply += value;
    balanceOf[to] += value;
    emit Transfer(address(0), to, value);
  }

  /// @notice Set the latent fee (basis points capped at 20, like Tether) and the absolute cap.
  function setParams(
    uint256 newBasisPoints,
    uint256 newMaxFee
  ) external {
    if (newBasisPoints > 20) revert UsdtBpsTooHigh();
    basisPointsRate = newBasisPoints;
    maximumFee = newMaxFee * (10 ** i_decimals);
  }

  function setBlackListed(
    address account,
    bool blocked
  ) external {
    isBlackListed[account] = blocked;
  }

  // --- Internal ---

  function _transfer(
    address from,
    address to,
    uint256 value
  ) internal {
    if (isBlackListed[from]) revert UsdtBlocked(from);
    if (isBlackListed[to]) revert UsdtBlocked(to);
    if (balanceOf[from] < value) revert UsdtInsufficientBalance();

    uint256 fee = (value * basisPointsRate) / 10_000;
    if (fee > maximumFee) fee = maximumFee;
    uint256 sendAmount = value - fee;

    balanceOf[from] -= value;
    balanceOf[to] += sendAmount;
    if (fee > 0) {
      balanceOf[owner] += fee;
      emit Transfer(from, owner, fee);
    }
    emit Transfer(from, to, sendAmount);
  }
}
