// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

/// @notice Experimental v0 interface. Subject to breaking changes.
struct Call {
    address target;
    uint256 value;
    bytes data;
}

/// @notice An ordered EVM call bundle prepared for execution.
struct PreparedAction {
    Call[] calls;
    uint256 validUntil;
}

/// @notice Discovers and prepares application-level actions.
interface IApplicationActions {
    function actions() external view returns (bytes32[] memory actionIds);

    function actionDescriptor(bytes32 actionId) external view returns (bytes memory descriptor);

    function prepare(bytes32 actionId, address account, bytes calldata parameters)
        external
        view
        returns (PreparedAction memory preparedAction);
}
