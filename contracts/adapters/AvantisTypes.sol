// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

enum AvantisOrderType {
    MARKET,
    STOP_LIMIT,
    LIMIT,
    MARKET_PNL
}

enum AvantisMarginAction {
    DEPOSIT,
    WITHDRAW
}

struct AvantisOpenTradeParameters {
    uint32 pairIndex;
    bool isLong;
    AvantisOrderType orderType;
    uint256 collateralUsdc;
    uint256 leverage;
    uint256 slippagePercent;
    uint256 openPrice;
    uint256 takeProfit;
    uint256 stopLoss;
    uint256 executionFeeWei;
}

struct AvantisCloseTradeParameters {
    uint256 pairIndex;
    uint256 tradeIndex;
    uint256 collateralToCloseUsdc;
    uint256 expectedPrice;
    uint256 executionFeeWei;
}

struct AvantisCancelLimitParameters {
    uint256 pairIndex;
    uint256 orderIndex;
}

struct AvantisMarginUpdateParameters {
    uint256 pairIndex;
    uint256 tradeIndex;
    AvantisMarginAction action;
    uint256 collateralUsdc;
    uint256 oracleFeeWei;
}

struct AvantisLimitUpdateParameters {
    uint256 pairIndex;
    uint256 orderIndex;
    uint256 price;
    uint256 slippagePercent;
    uint256 takeProfit;
    uint256 stopLoss;
}

struct AvantisSetDelegateParameters {
    address delegate;
    uint256 expirySeconds;
}

struct AvantisRemoveDelegateParameters {
    address delegate;
}

struct AvantisTrade {
    address trader;
    uint256 pairIndex;
    uint256 index;
    uint256 initialPosToken;
    uint256 positionSizeUSDC;
    uint256 openPrice;
    bool buy;
    uint256 leverage;
    uint256 tp;
    uint256 sl;
    uint256 timestamp;
}

interface IAvantisErc20 {
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IAvantisTrading {
    function openTrade(AvantisTrade calldata trade, uint8 orderType, uint256 slippagePercent)
        external
        payable
        returns (uint256 orderId);
    function closeTradeMarket(uint256 pairIndex, uint256 index, uint256 amount, uint256 expectedPrice)
        external
        payable
        returns (uint256 orderId);
    function cancelOpenLimitOrder(uint256 pairIndex, uint256 index) external;
    function updateMargin(
        uint256 pairIndex,
        uint256 index,
        uint8 action,
        uint256 amount,
        bytes[] calldata priceUpdateData,
        uint8 priceSourcing
    ) external payable returns (uint256 orderId);
    function updateOpenLimitOrder(
        uint256 pairIndex,
        uint256 index,
        uint256 price,
        uint256 slippagePercent,
        uint256 takeProfit,
        uint256 stopLoss
    ) external;
    function setDelegate(address delegate, uint256 expirySeconds) external;
    function removeDelegate(address delegate) external;
}
