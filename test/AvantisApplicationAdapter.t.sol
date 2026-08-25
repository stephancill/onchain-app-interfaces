// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

import {PreparedAction} from "../contracts/IApplicationActions.sol";
import {HttpHeader, HttpResponse} from "../contracts/IExternalRequest.sol";
import {
    AvantisApplicationAdapter,
    AvantisOpenTradeParameters,
    AvantisOrderType,
    AvantisPositionsResult,
    AvantisTrade,
    IAvantisTrading
} from "../contracts/adapters/AvantisApplicationAdapter.sol";

interface AvantisVm {
    function etch(address target, bytes calldata code) external;
}

contract AvantisMockToken {
    function balanceOf(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function allowance(address, address) external pure returns (uint256) {
        return 0;
    }
}

contract AvantisApplicationAdapterTest {
    AvantisVm internal constant vm = AvantisVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    AvantisApplicationAdapter internal adapter =
        new AvantisApplicationAdapter("https://core.avantisfi.com", "https://tx-builder.avantisfi.com");

    function setUp() external {
        AvantisMockToken token = new AvantisMockToken();
        vm.etch(adapter.USDC(), address(token).code);
    }

    function testDiscoversQueryAndAction() external view {
        bytes32[] memory queryIds = adapter.queries();
        bytes32[] memory actionIds = adapter.actions();
        require(queryIds.length == 1 && queryIds[0] == adapter.POSITIONS_QUERY(), "missing positions query");
        require(actionIds.length == 1 && actionIds[0] == adapter.OPEN_TRADE_ACTION(), "missing open action");
    }

    function testPositionsCallbackBindsAccount() external view {
        address account = address(0xbeef);
        HttpResponse memory response = _response(bytes('{"positions":[],"limitOrders":[]}'));
        AvantisPositionsResult memory result =
            abi.decode(adapter.positionsCallback(response, abi.encode(account)), (AvantisPositionsResult));
        require(result.account == account, "wrong account");
        require(result.status == 200, "wrong status");
        require(keccak256(result.body) == keccak256(response.body), "wrong body");
    }

    function testOpenTradeCallbackReturnsValidatedCall() external view {
        address account = address(0xbeef);
        AvantisOpenTradeParameters memory parameters = _parameters();
        bytes memory callData = _callData(account, parameters);
        PreparedAction memory prepared = adapter.openTradeCallback(
            _transactionResponse(account, parameters.executionFeeWei, callData), abi.encode(account, parameters)
        );

        require(prepared.calls.length == 2, "expected approval and trade");
        require(prepared.calls[0].target == adapter.USDC(), "wrong approval target");
        require(prepared.calls[1].target == adapter.TRADING(), "wrong trade target");
        require(prepared.calls[1].value == parameters.executionFeeWei, "wrong execution fee");
        require(keccak256(prepared.calls[1].data) == keccak256(callData), "wrong trade calldata");
        // forge-lint: disable-next-line(block-timestamp)
        require(prepared.validUntil == block.timestamp + adapter.PREPARATION_VALIDITY(), "wrong expiry");
    }

    function testOpenTradeCallbackRejectsDifferentTrader() external view {
        address account = address(0xbeef);
        AvantisOpenTradeParameters memory parameters = _parameters();
        bytes memory callData = _callData(address(0xdead), parameters);
        (bool success,) = address(adapter)
            .staticcall(
                abi.encodeCall(
                    adapter.openTradeCallback,
                    (
                        _transactionResponse(account, parameters.executionFeeWei, callData),
                        abi.encode(account, parameters)
                    )
                )
            );
        require(!success, "different trader should fail");
    }

    function testOpenTradeCallbackRejectsDifferentValue() external view {
        address account = address(0xbeef);
        AvantisOpenTradeParameters memory parameters = _parameters();
        (bool success,) = address(adapter)
            .staticcall(
                abi.encodeCall(
                    adapter.openTradeCallback,
                    (
                        _transactionResponse(account, parameters.executionFeeWei + 1, _callData(account, parameters)),
                        abi.encode(account, parameters)
                    )
                )
            );
        require(!success, "different value should fail");
    }

    function testRejectsInvalidTradeParameters() external view {
        AvantisOpenTradeParameters memory parameters = _parameters();
        parameters.slippagePercent = 0;
        (bool success,) = address(adapter)
            .staticcall(
                abi.encodeCall(adapter.prepare, (adapter.OPEN_TRADE_ACTION(), address(0xbeef), abi.encode(parameters)))
            );
        require(!success, "zero slippage should fail");
    }

    function _parameters() private pure returns (AvantisOpenTradeParameters memory) {
        return AvantisOpenTradeParameters({
            pairIndex: 0,
            isLong: true,
            orderType: AvantisOrderType.LIMIT,
            collateralUsdc: 100_000_000,
            leverage: 10 * 1e10,
            slippagePercent: 1e10,
            openPrice: 100_000 * 1e10,
            takeProfit: 120_000 * 1e10,
            stopLoss: 90_000 * 1e10,
            executionFeeWei: 350_000_000_000_000
        });
    }

    function _callData(address account, AvantisOpenTradeParameters memory parameters)
        private
        pure
        returns (bytes memory)
    {
        AvantisTrade memory trade = AvantisTrade({
            trader: account,
            pairIndex: parameters.pairIndex,
            index: 0,
            initialPosToken: 0,
            positionSizeUSDC: parameters.collateralUsdc,
            openPrice: parameters.openPrice,
            buy: parameters.isLong,
            leverage: parameters.leverage,
            tp: parameters.takeProfit,
            sl: parameters.stopLoss,
            timestamp: 0
        });
        return
            abi.encodeCall(IAvantisTrading.openTrade, (trade, uint8(parameters.orderType), parameters.slippagePercent));
    }

    function _transactionResponse(address account, uint256 value, bytes memory callData)
        private
        pure
        returns (HttpResponse memory)
    {
        return _response(
            abi.encodePacked(
                '{"ok":true,"data":{"to":"0x44914408af82bc9983bbb330e3578e1105e11d4e","from":"',
                _addressString(account),
                '","data":"',
                _hexString(callData),
                '","value":"0x',
                _uintHex(value),
                '","chainId":8453,"description":"test"}}'
            )
        );
    }

    function _response(bytes memory body) private pure returns (HttpResponse memory) {
        HttpHeader[] memory headers = new HttpHeader[](0);
        return HttpResponse({status: 200, headers: headers, body: body});
    }

    function _addressString(address account) private pure returns (string memory) {
        return _hexString(abi.encodePacked(account));
    }

    function _hexString(bytes memory value) private pure returns (string memory) {
        bytes16 symbols = "0123456789abcdef";
        bytes memory output = new bytes(2 + value.length * 2);
        output[0] = "0";
        output[1] = "x";
        for (uint256 i = 0; i < value.length; i++) {
            output[2 + i * 2] = symbols[uint8(value[i]) >> 4];
            output[3 + i * 2] = symbols[uint8(value[i]) & 0x0f];
        }
        return string(output);
    }

    function _uintHex(uint256 value) private pure returns (string memory) {
        if (value == 0) return "0";
        bytes16 symbols = "0123456789abcdef";
        uint256 digits;
        uint256 remaining = value;
        while (remaining != 0) {
            digits++;
            remaining >>= 4;
        }
        bytes memory output = new bytes(digits);
        while (value != 0) {
            output[--digits] = symbols[value & 0xf];
            value >>= 4;
        }
        return string(output);
    }
}
