// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

/// @dev Keeps descriptor literals out of the adapter's EIP-170 runtime budget.
contract AvantisDescriptor {
    error UnknownDescriptor(bytes32 id);

    function queryDescriptor(bytes32 id) external pure returns (bytes memory) {
        if (id != keccak256("avantis.positions")) revert UnknownDescriptor(id);
        return bytes(
            '{"version":"0.1","kind":"query","name":"avantis.positions","inputs":{"encoding":"abi","fields":[{"name":"account","abiType":"address","semanticType":"account"}]},"output":{"encoding":"json","fields":[{"name":"positions","abiType":"tuple[]","maxItems":64,"path":"positions[]","components":[{"name":"trader","abiType":"address","semanticType":"account","equalsInput":"account"},{"name":"pairIndex","abiType":"uint256","semanticType":"marketId"},{"name":"index","abiType":"uint256","semanticType":"tradeIndex"},{"name":"buy","abiType":"bool","semanticType":"isLong"},{"name":"collateral","abiType":"uint256","semanticType":"usdcAmount1e6"},{"name":"leverage","abiType":"uint256","semanticType":"fixedPoint1e10"},{"name":"openPrice","abiType":"uint256","semanticType":"price1e10"},{"name":"tp","abiType":"uint256","semanticType":"price1e10"},{"name":"sl","abiType":"uint256","semanticType":"price1e10"},{"name":"liquidationPrice","abiType":"uint256","semanticType":"price1e10"},{"name":"rolloverFee","abiType":"uint256","semanticType":"usdcAmount1e6"},{"name":"lossProtection","abiType":"uint256","semanticType":"tier"},{"name":"openedAt","abiType":"uint256","semanticType":"timestamp"},{"name":"isPnl","abiType":"bool"},{"name":"isOneCT","abiType":"bool"}]},{"name":"limitOrders","abiType":"tuple[]","maxItems":64,"path":"limitOrders[]","components":[{"name":"trader","abiType":"address","semanticType":"account","equalsInput":"account"},{"name":"pairIndex","abiType":"uint256","semanticType":"marketId"},{"name":"index","abiType":"uint256","semanticType":"orderIndex"},{"name":"buy","abiType":"bool","semanticType":"isLong"},{"name":"blockNumber","abiType":"uint256","semanticType":"blockNumber","path":"block"},{"name":"collateral","abiType":"uint256","semanticType":"usdcAmount1e6"},{"name":"positionSize","abiType":"uint256","semanticType":"usdcAmount1e6"},{"name":"price","abiType":"uint256","semanticType":"price1e10"},{"name":"leverage","abiType":"uint256","semanticType":"fixedPoint1e10"},{"name":"tp","abiType":"uint256","semanticType":"price1e10"},{"name":"sl","abiType":"uint256","semanticType":"price1e10"},{"name":"slippageP","abiType":"uint256","semanticType":"percent1e10"},{"name":"executionFee","abiType":"uint256","semanticType":"nativeTokenWei"},{"name":"liquidationPrice","abiType":"uint256","semanticType":"price1e10"},{"name":"limitOrderType","abiType":"uint256","semanticType":"orderType"},{"name":"isOneCT","abiType":"bool"}]}]},"provenance":{"type":"configured-origin"}}'
        );
    }

    function actionDescriptor(bytes32 id) external pure returns (bytes memory) {
        if (id == keccak256("avantis.trade.open")) {
            return _action(
                "avantis.trade.open",
                '[{"name":"pairIndex","abiType":"uint32","semanticType":"marketId"},{"name":"isLong","abiType":"bool"},{"name":"orderType","abiType":"uint8","enumValues":{"MARKET":0,"STOP_LIMIT":1,"LIMIT":2,"MARKET_PNL":3}},{"name":"collateralUsdc","abiType":"uint256","semanticType":"usdcAmount1e6","minimum":"1"},{"name":"leverage","abiType":"uint256","semanticType":"fixedPoint1e10","minimum":"10000000000","maximum":"10000000000000"},{"name":"slippagePercent","abiType":"uint256","semanticType":"percent1e10","minimum":"1","maximum":"800000000000"},{"name":"openPrice","abiType":"uint256","semanticType":"price1e10","minimum":"1"},{"name":"takeProfit","abiType":"uint256","semanticType":"price1e10"},{"name":"stopLoss","abiType":"uint256","semanticType":"price1e10"},{"name":"executionFeeWei","abiType":"uint256","semanticType":"nativeTokenWei","maximum":"1000000000000000000"}]',
                '[{"type":"decrease","description":"USDC collateral and execution fee"},{"type":"increase","description":"Leveraged perpetual exposure"}]'
            );
        }
        if (id == keccak256("avantis.trade.close")) {
            return _action(
                "avantis.trade.close",
                '[{"name":"pairIndex","abiType":"uint256","semanticType":"marketId"},{"name":"tradeIndex","abiType":"uint256"},{"name":"collateralToCloseUsdc","abiType":"uint256","semanticType":"usdcAmount1e6","minimum":"1"},{"name":"expectedPrice","abiType":"uint256","semanticType":"price1e10","minimum":"1"},{"name":"executionFeeWei","abiType":"uint256","semanticType":"nativeTokenWei","maximum":"1000000000000000000"}]',
                '[{"type":"decrease","description":"Open perpetual exposure"},{"type":"increase","description":"USDC settlement when executed"}]'
            );
        }
        if (id == keccak256("avantis.limit.cancel")) {
            return _action(
                "avantis.limit.cancel",
                '[{"name":"pairIndex","abiType":"uint256","semanticType":"marketId"},{"name":"orderIndex","abiType":"uint256"}]',
                '[{"type":"decrease","description":"Pending limit order"},{"type":"increase","description":"Refunded USDC collateral"}]'
            );
        }
        if (id == keccak256("avantis.margin.update")) {
            return _action(
                "avantis.margin.update",
                '[{"name":"pairIndex","abiType":"uint256","semanticType":"marketId"},{"name":"tradeIndex","abiType":"uint256"},{"name":"action","abiType":"uint8","enumValues":{"DEPOSIT":0,"WITHDRAW":1}},{"name":"collateralUsdc","abiType":"uint256","semanticType":"usdcAmount1e6","minimum":"1"},{"name":"oracleFeeWei","abiType":"uint256","semanticType":"nativeTokenWei","maximum":"1000000000000000000"}]',
                '[{"type":"set","description":"Position collateral and effective leverage"},{"type":"decrease","description":"USDC balance on deposit or position collateral on withdrawal"}]'
            );
        }
        if (id == keccak256("avantis.limit.update")) {
            return _action(
                "avantis.limit.update",
                '[{"name":"pairIndex","abiType":"uint256","semanticType":"marketId"},{"name":"orderIndex","abiType":"uint256"},{"name":"price","abiType":"uint256","semanticType":"price1e10","minimum":"1"},{"name":"slippagePercent","abiType":"uint256","semanticType":"percent1e10","minimum":"1","maximum":"800000000000"},{"name":"takeProfit","abiType":"uint256","semanticType":"price1e10"},{"name":"stopLoss","abiType":"uint256","semanticType":"price1e10"}]',
                '[{"type":"set","description":"Pending order trigger, slippage, take-profit, and stop-loss"}]'
            );
        }
        if (id == keccak256("avantis.delegate.set")) {
            return _action(
                "avantis.delegate.set",
                '[{"name":"delegate","abiType":"address","semanticType":"account"},{"name":"expirySeconds","abiType":"uint256","semanticType":"timestamp"}]',
                '[{"type":"set","description":"Time-bounded trading delegation"}]'
            );
        }
        if (id == keccak256("avantis.delegate.remove")) {
            return _action(
                "avantis.delegate.remove",
                '[{"name":"delegate","abiType":"address","semanticType":"account"}]',
                '[{"type":"decrease","description":"Trading delegation"}]'
            );
        }
        revert UnknownDescriptor(id);
    }

    function _action(string memory name, string memory components, string memory effects)
        private
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(
            '{"version":"0.1","kind":"action","name":"',
            name,
            '","inputs":{"encoding":"abi","fields":[{"name":"parameters","abiType":"tuple","components":',
            components,
            '}]},"output":{"encoding":"preparedAction"},"effects":',
            effects,
            ',"execution":{"atomicity":"atomic-required"},"provenance":{"type":"hybrid"}}'
        );
    }
}
