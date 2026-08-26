// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

import {Text} from "../lib/Text.sol";
import {
    AvantisCancelLimitParameters,
    AvantisCloseTradeParameters,
    AvantisLimitUpdateParameters,
    AvantisMarginAction,
    AvantisMarginUpdateParameters,
    AvantisOpenTradeParameters,
    AvantisOrderType,
    AvantisRemoveDelegateParameters,
    AvantisSetDelegateParameters
} from "./AvantisTypes.sol";

contract AvantisRequestCodec {
    uint256 private constant SCALE = 1e10;
    uint256 private constant MAX_LEVERAGE = 1_000 * SCALE;
    uint256 private constant MAX_SLIPPAGE_PERCENT = 80 * SCALE;
    uint256 private constant MAX_EXECUTION_FEE = 1 ether;
    error InvalidParameters();

    function url(string memory baseUrl, bytes32 actionId, address account, bytes memory encoded)
        external
        view
        returns (string memory)
    {
        string memory trader = Text.addressString(account);
        if (actionId == keccak256("avantis.trade.open")) {
            AvantisOpenTradeParameters memory p = abi.decode(encoded, (AvantisOpenTradeParameters));
            _validateOpen(account, p);
            return string.concat(
                baseUrl,
                "/v2/trade/open?trader=",
                trader,
                "&pairIndex=",
                Text.uintString(p.pairIndex),
                "&side=",
                p.isLong ? "long" : "short",
                "&orderType=",
                _orderTypeString(p.orderType),
                "&collateralUsdc=",
                _fixedPointString(p.collateralUsdc, 6),
                "&leverage=",
                _fixedPointString(p.leverage, 10),
                "&slippagePercent=",
                _fixedPointString(p.slippagePercent, 10),
                "&openPrice=",
                _fixedPointString(p.openPrice, 10),
                "&takeProfit=",
                _fixedPointString(p.takeProfit, 10),
                "&stopLoss=",
                _fixedPointString(p.stopLoss, 10),
                "&executionFeeWei=",
                Text.uintString(p.executionFeeWei)
            );
        }
        if (actionId == keccak256("avantis.trade.close")) {
            AvantisCloseTradeParameters memory p = abi.decode(encoded, (AvantisCloseTradeParameters));
            if (p.collateralToCloseUsdc == 0 || p.expectedPrice == 0 || p.executionFeeWei > MAX_EXECUTION_FEE) {
                revert InvalidParameters();
            }
            return string.concat(
                baseUrl,
                "/v2/trade/close?trader=",
                trader,
                "&pairIndex=",
                Text.uintString(p.pairIndex),
                "&tradeIndex=",
                Text.uintString(p.tradeIndex),
                "&collateralToCloseUsdc=",
                _fixedPointString(p.collateralToCloseUsdc, 6),
                "&expectedPrice=",
                _fixedPointString(p.expectedPrice, 10),
                "&executionFeeWei=",
                Text.uintString(p.executionFeeWei)
            );
        }
        if (actionId == keccak256("avantis.limit.cancel")) {
            AvantisCancelLimitParameters memory p = abi.decode(encoded, (AvantisCancelLimitParameters));
            return string.concat(
                baseUrl,
                "/v2/limit/cancel?trader=",
                trader,
                "&pairIndex=",
                Text.uintString(p.pairIndex),
                "&orderIndex=",
                Text.uintString(p.orderIndex)
            );
        }
        if (actionId == keccak256("avantis.margin.update")) {
            AvantisMarginUpdateParameters memory p = abi.decode(encoded, (AvantisMarginUpdateParameters));
            if (p.collateralUsdc == 0 || p.oracleFeeWei > MAX_EXECUTION_FEE) revert InvalidParameters();
            return string.concat(
                baseUrl,
                "/v2/margin/update?trader=",
                trader,
                "&pairIndex=",
                Text.uintString(p.pairIndex),
                "&tradeIndex=",
                Text.uintString(p.tradeIndex),
                "&action=",
                p.action == AvantisMarginAction.DEPOSIT ? "deposit" : "withdraw",
                "&collateralUsdc=",
                _fixedPointString(p.collateralUsdc, 6),
                "&oracleFeeWei=",
                Text.uintString(p.oracleFeeWei)
            );
        }
        if (actionId == keccak256("avantis.limit.update")) {
            AvantisLimitUpdateParameters memory p = abi.decode(encoded, (AvantisLimitUpdateParameters));
            if (p.price == 0 || p.slippagePercent == 0 || p.slippagePercent > MAX_SLIPPAGE_PERCENT) {
                revert InvalidParameters();
            }
            return string.concat(
                baseUrl,
                "/v2/limit/update?trader=",
                trader,
                "&pairIndex=",
                Text.uintString(p.pairIndex),
                "&orderIndex=",
                Text.uintString(p.orderIndex),
                "&price=",
                _fixedPointString(p.price, 10),
                "&slippagePercent=",
                _fixedPointString(p.slippagePercent, 10),
                "&takeProfit=",
                _fixedPointString(p.takeProfit, 10),
                "&stopLoss=",
                _fixedPointString(p.stopLoss, 10)
            );
        }
        if (actionId == keccak256("avantis.delegate.set")) {
            AvantisSetDelegateParameters memory p = abi.decode(encoded, (AvantisSetDelegateParameters));
            // forge-lint: disable-next-line(block-timestamp)
            if (p.delegate == address(0) || p.delegate == account || p.expirySeconds <= block.timestamp) {
                revert InvalidParameters();
            }
            return string.concat(
                baseUrl,
                "/v2/delegate/set?trader=",
                trader,
                "&delegate=",
                Text.addressString(p.delegate),
                "&expirySeconds=",
                Text.uintString(p.expirySeconds)
            );
        }
        AvantisRemoveDelegateParameters memory removeParameters = abi.decode(encoded, (AvantisRemoveDelegateParameters));
        if (removeParameters.delegate == address(0) || removeParameters.delegate == account) {
            revert InvalidParameters();
        }
        return string.concat(
            baseUrl, "/v2/delegate/remove?trader=", trader, "&delegate=", Text.addressString(removeParameters.delegate)
        );
    }

    function _validateOpen(address account, AvantisOpenTradeParameters memory p) private pure {
        if (
            account == address(0) || p.collateralUsdc == 0 || p.leverage < SCALE || p.leverage > MAX_LEVERAGE
                || p.slippagePercent == 0 || p.slippagePercent > MAX_SLIPPAGE_PERCENT || p.openPrice == 0
                || p.executionFeeWei > MAX_EXECUTION_FEE
        ) revert InvalidParameters();
    }

    function _orderTypeString(AvantisOrderType orderType) private pure returns (string memory) {
        if (orderType == AvantisOrderType.MARKET) return "market";
        if (orderType == AvantisOrderType.STOP_LIMIT) return "stop_limit";
        if (orderType == AvantisOrderType.LIMIT) return "limit";
        return "market_pnl";
    }

    function _fixedPointString(uint256 value, uint256 decimals) private pure returns (string memory) {
        uint256 scale = 10 ** decimals;
        uint256 fraction = value % scale;
        if (fraction == 0) return Text.uintString(value / scale);
        uint256 trailingZeros;
        while (fraction % 10 == 0) {
            fraction /= 10;
            trailingZeros++;
        }
        uint256 fractionDigits = decimals - trailingZeros;
        bytes memory fractionText = bytes(Text.uintString(fraction));
        bytes memory paddedFraction = new bytes(fractionDigits);
        uint256 padding = fractionDigits - fractionText.length;
        for (uint256 i = 0; i < padding; i++) {
            paddedFraction[i] = "0";
        }
        for (uint256 i = 0; i < fractionText.length; i++) {
            paddedFraction[padding + i] = fractionText[i];
        }
        return string.concat(Text.uintString(value / scale), ".", string(paddedFraction));
    }
}
