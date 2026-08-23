// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

import {SeaDropPublicDrop} from "../contracts/adapters/OpenSeaApplicationAdapter.sol";

contract SelectedAppMockToken {
    function balanceOf(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function allowance(address, address) external pure returns (uint256) {
        return 0;
    }

    function approve(address, uint256) external pure returns (bool) {
        return true;
    }
}

contract SelectedAppMockSeaDrop {
    uint80 public constant MINT_PRICE = 0.001 ether;

    function getPublicDrop(address) external pure returns (SeaDropPublicDrop memory) {
        return SeaDropPublicDrop({
            mintPrice: MINT_PRICE,
            startTime: 0,
            endTime: type(uint48).max,
            maxTotalMintableByWallet: 100,
            feeBps: 250,
            restrictFeeRecipients: false
        });
    }
}

contract SelectedAppMockNft {}
