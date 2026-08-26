// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

import {Json} from "../lib/Json.sol";
import {
    AvantisCancelLimitParameters,
    AvantisCloseTradeParameters,
    AvantisLimitUpdateParameters,
    AvantisMarginAction,
    AvantisMarginUpdateParameters,
    AvantisOpenTradeParameters,
    AvantisRemoveDelegateParameters,
    AvantisSetDelegateParameters,
    AvantisTrade,
    IAvantisTrading
} from "./AvantisTypes.sol";

contract AvantisActionCodec {
    uint256 private constant MAX_PRICE_UPDATE_BYTES = 16_384;
    address private constant TRADING = 0x44914408af82bC9983bbb330e3578E1105e11d4e;
    error InvalidTransaction();

    function open(bytes memory body, address account, AvantisOpenTradeParameters memory requested)
        external
        pure
        returns (bytes memory callData)
    {
        callData = _transaction(body, account, requested.executionFeeWei);
        AvantisTrade memory expected = AvantisTrade({
            trader: account,
            pairIndex: requested.pairIndex,
            index: 0,
            initialPosToken: 0,
            positionSizeUSDC: requested.collateralUsdc,
            openPrice: requested.openPrice,
            buy: requested.isLong,
            leverage: requested.leverage,
            tp: requested.takeProfit,
            sl: requested.stopLoss,
            timestamp: 0
        });
        if (
            keccak256(callData)
                != keccak256(
                    abi.encodeCall(
                        IAvantisTrading.openTrade, (expected, uint8(requested.orderType), requested.slippagePercent)
                    )
                )
        ) revert InvalidTransaction();
    }

    function action(bytes memory body, uint8 actionKind, address account, bytes memory encoded)
        external
        pure
        returns (bytes memory data, uint256 value, uint256 approvalAmount)
    {
        if (actionKind == 0x13) {
            AvantisCloseTradeParameters memory p = abi.decode(encoded, (AvantisCloseTradeParameters));
            data = _transaction(body, account, p.executionFeeWei);
            if (
                keccak256(data)
                    != keccak256(
                        abi.encodeCall(
                            IAvantisTrading.closeTradeMarket,
                            (p.pairIndex, p.tradeIndex, p.collateralToCloseUsdc, p.expectedPrice)
                        )
                    )
            ) revert InvalidTransaction();
            return (data, p.executionFeeWei, 0);
        }
        if (actionKind == 0x90) {
            AvantisCancelLimitParameters memory p = abi.decode(encoded, (AvantisCancelLimitParameters));
            data = _transaction(body, account, 0);
            if (
                keccak256(data)
                    != keccak256(abi.encodeCall(IAvantisTrading.cancelOpenLimitOrder, (p.pairIndex, p.orderIndex)))
            ) revert InvalidTransaction();
            return (data, 0, 0);
        }
        if (actionKind == 0x7c) return _margin(body, account, encoded);
        if (actionKind == 0xa3) return _limit(body, account, encoded);
        if (actionKind == 0xee) return _setDelegate(body, account, encoded);
        return _removeDelegate(body, account, encoded);
    }

    function _margin(bytes memory body, address account, bytes memory encoded)
        private
        pure
        returns (bytes memory data, uint256 value, uint256 approvalAmount)
    {
        AvantisMarginUpdateParameters memory p = abi.decode(encoded, (AvantisMarginUpdateParameters));
        data = _transaction(body, account, p.oracleFeeWei);
        (
            uint256 pairIndex,
            uint256 tradeIndex,
            uint8 action_,
            uint256 collateral,
            bytes[] memory prices,
            uint8 source
        ) = abi.decode(Json.slice(data, 4, data.length - 4), (uint256, uint256, uint8, uint256, bytes[], uint8));
        uint256 priceBytes;
        for (uint256 i = 0; i < prices.length;) {
            priceBytes += prices[i].length;
            unchecked {
                ++i;
            }
        }
        if (
            pairIndex != p.pairIndex || tradeIndex != p.tradeIndex || action_ != uint8(p.action)
                || collateral != p.collateralUsdc || source > 1 || priceBytes > MAX_PRICE_UPDATE_BYTES
                || keccak256(data)
                    != keccak256(
                        abi.encodeCall(
                            IAvantisTrading.updateMargin, (pairIndex, tradeIndex, action_, collateral, prices, source)
                        )
                    )
        ) revert InvalidTransaction();
        return (data, p.oracleFeeWei, p.action == AvantisMarginAction.DEPOSIT ? p.collateralUsdc : 0);
    }

    function _limit(bytes memory body, address account, bytes memory encoded)
        private
        pure
        returns (bytes memory data, uint256 value, uint256 approvalAmount)
    {
        AvantisLimitUpdateParameters memory p = abi.decode(encoded, (AvantisLimitUpdateParameters));
        data = _transaction(body, account, 0);
        if (
            keccak256(data)
                != keccak256(
                    abi.encodeCall(
                        IAvantisTrading.updateOpenLimitOrder,
                        (p.pairIndex, p.orderIndex, p.price, p.slippagePercent, p.takeProfit, p.stopLoss)
                    )
                )
        ) revert InvalidTransaction();
        return (data, 0, 0);
    }

    function _setDelegate(bytes memory body, address account, bytes memory encoded)
        private
        pure
        returns (bytes memory data, uint256 value, uint256 approvalAmount)
    {
        AvantisSetDelegateParameters memory p = abi.decode(encoded, (AvantisSetDelegateParameters));
        data = _transaction(body, account, 0);
        if (keccak256(data) != keccak256(abi.encodeCall(IAvantisTrading.setDelegate, (p.delegate, p.expirySeconds)))) {
            revert InvalidTransaction();
        }
        return (data, 0, 0);
    }

    function _removeDelegate(bytes memory body, address account, bytes memory encoded)
        private
        pure
        returns (bytes memory data, uint256 value, uint256 approvalAmount)
    {
        AvantisRemoveDelegateParameters memory p = abi.decode(encoded, (AvantisRemoveDelegateParameters));
        data = _transaction(body, account, 0);
        if (keccak256(data) != keccak256(abi.encodeCall(IAvantisTrading.removeDelegate, (p.delegate)))) {
            revert InvalidTransaction();
        }
        return (data, 0, 0);
    }

    function _transaction(bytes memory body, address account, uint256 expectedValue)
        private
        pure
        returns (bytes memory)
    {
        bytes memory transaction = Json.objectValue(body, "data");
        if (
            Json.uintValue(transaction, "chainId") != 8453 || Json.addressValue(transaction, "to") != TRADING
                || Json.addressValue(transaction, "from") != account
                || Json.hexStringValue(transaction, "value") != expectedValue
        ) revert InvalidTransaction();
        return Json.bytesValue(transaction, "data");
    }
}
