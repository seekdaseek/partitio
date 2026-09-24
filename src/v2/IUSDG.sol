// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice The two gasless entry paths USDG exposes on 4663, both verified live.
/// `receiveWithAuthorization` reverts with `CallerMustBePayee` unless msg.sender == to, which is
/// the property that binds an authorization to this contract. A signed dry-run reached
/// `InsufficientFunds`, i.e. it cleared the selector, the payee check and EIP-712 verification.
interface IUSDG {
    function receiveWithAuthorization(
        address from, address to, uint256 value,
        uint256 validAfter, uint256 validBefore, bytes32 nonce,
        uint8 v, bytes32 r, bytes32 s
    ) external;

    function authorizationState(address authorizer, bytes32 nonce) external view returns (bool);
}

interface IERC20Permit {
    function permit(address owner, address spender, uint256 value, uint256 deadline,
                    uint8 v, bytes32 r, bytes32 s) external;
    function nonces(address owner) external view returns (uint256);
}
