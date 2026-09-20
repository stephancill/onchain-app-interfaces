// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

import {IERC7572} from "./IERC7572.sol";

/// @notice Discovers and executes application-level semantic reads.
/// @dev Experimental v0 interface. Subject to breaking changes.
interface IApplicationQueries is IERC7572 {
    function queries() external view returns (bytes32[] memory queryIds);

    function queryDescriptor(bytes32 queryId) external view returns (bytes memory descriptor);

    function query(bytes32 queryId, bytes calldata parameters) external view returns (bytes memory result);
}
