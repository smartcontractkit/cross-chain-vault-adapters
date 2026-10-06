// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title AdapterRoles
 * @notice OpenZeppelin AccessControl role ids for vault adapter clones. `DEFAULT_ADMIN_ROLE` (0x00) is
 *         defined by {AccessControl} and governs routes, allowlists, and role grants. Fee operations
 *         use dedicated roles so operators can delegate to bots without exposing admin keys.
 */
library AdapterRoles {
    /// @dev Operator / bot may call {setInboundFee} and {setRequireLzReturnPrefunded}.
    bytes32 internal constant FEE_SETTER = keccak256("FEE_SETTER_ROLE");
    /// @dev Operator / bot may call {withdrawCollectedFee}.
    bytes32 internal constant FEE_COLLECTOR = keccak256("FEE_COLLECTOR_ROLE");
}
