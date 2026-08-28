// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

import {PreparedAction} from "../contracts/IApplicationActions.sol";
import {HttpHeader, HttpResponse, ResponseBodyEncoding} from "../contracts/IExternalRequest.sol";
import {
    AvantisAccountState,
    AvantisApplicationAdapter,
    AvantisDelegateParameters,
    AvantisMarginAction,
    AvantisMarginParameters,
    AvantisOpenTradeParameters,
    AvantisOrderInfo,
    AvantisOrderType,
    AvantisPositionsBody,
    AvantisPositionsResult,
    AvantisTrade,
    AvantisTradeInfo,
    AvantisTransaction,
    IAvantisTrading
} from "../contracts/adapters/AvantisApplicationAdapter.sol";

interface AvantisVm {
    function etch(address target, bytes calldata code) external;
}

contract AvantisMockToken {
    function balanceOf(address) external pure returns (uint256) {
        return 1_000_000e6;
    }

    function allowance(address, address) external pure returns (uint256) {
        return 0;
    }
}

contract AvantisApplicationAdapterTest {
    AvantisVm internal constant vm = AvantisVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    AvantisApplicationAdapter internal adapter = new AvantisApplicationAdapter("https://tx-builder.avantisfi.com");

    function setUp() external {
        AvantisMockToken token = new AvantisMockToken();
        vm.etch(adapter.USDC(), address(token).code);
    }

    function testDiscoversComprehensiveQueriesAndActions() external view {
        bytes32[] memory queryIds = adapter.queries();
        bytes32[] memory actionIds = adapter.actions();
        require(queryIds.length == 5, "wrong query count");
        require(queryIds[0] == adapter.META_QUERY(), "missing meta query");
        require(queryIds[1] == adapter.MARKETS_QUERY(), "missing markets query");
        require(queryIds[2] == adapter.MARKET_QUERY(), "missing market query");
        require(queryIds[3] == adapter.POSITIONS_QUERY(), "missing positions query");
        require(queryIds[4] == adapter.ACCOUNT_QUERY(), "missing account query");
        require(actionIds.length == 8, "wrong action count");
        require(actionIds[0] == adapter.OPEN_TRADE_ACTION(), "missing open action");
        require(actionIds[7] == adapter.REMOVE_DELEGATE_ACTION(), "missing delegate action");
    }

    function testExternalQueryCallbackBindsProjectedPositions() external view {
        address account = address(0xbeef);
        bytes32 parametersHash = keccak256(abi.encode(account));
        AvantisPositionsBody memory projected =
            AvantisPositionsBody({trades: _projectedTrades(account), orders: new AvantisOrderInfo[](0)});
        HttpResponse memory response = _projectedResponse(abi.encode(projected));
        AvantisPositionsResult memory result = abi.decode(
            adapter.externalQueryCallback(response, abi.encode(adapter.POSITIONS_QUERY(), account, parametersHash)),
            (AvantisPositionsResult)
        );
        require(result.account == account, "wrong account");
        require(result.parametersHash == parametersHash, "wrong parameters");
        require(result.trades.length == 1, "wrong trade count");
        require(result.trades[0].trader == account, "wrong trade trader");
        require(result.trades[0].collateralUsdc == 100e6, "wrong collateral");
        require(result.orders.length == 0, "wrong order count");
        require(keccak256(abi.encode(result.rawBodyHash)) == keccak256(abi.encode(response.rawBodyHash)), "wrong hash");
    }

    function testAccountQueryReturnsOnchainFundsAndAllowance() external view {
        address account = address(0xbeef);
        AvantisAccountState memory result =
            abi.decode(adapter.query(adapter.ACCOUNT_QUERY(), abi.encode(account)), (AvantisAccountState));
        require(result.account == account, "wrong account");
        require(result.usdcBalance == 1_000_000e6, "wrong balance");
        require(result.usdcAllowance == 0, "wrong allowance");
        require(result.spender == adapter.TRADING_STORAGE(), "wrong spender");
    }

    function testTransactionCallbackReturnsApprovalAndValidatedOpen() external view {
        address account = address(0xbeef);
        AvantisOpenTradeParameters memory parameters = _openParameters();
        bytes memory callData = _openCallData(account, parameters);
        PreparedAction memory prepared = adapter.transactionCallback(
            _transactionResponse(account, parameters.executionFeeWei, callData),
            abi.encode(account, callData, parameters.executionFeeWei, parameters.collateralUsdc)
        );

        require(prepared.calls.length == 2, "expected approval and trade");
        require(prepared.calls[0].target == adapter.USDC(), "wrong approval target");
        require(prepared.calls[1].target == adapter.TRADING(), "wrong trade target");
        require(prepared.calls[1].value == parameters.executionFeeWei, "wrong execution fee");
        require(keccak256(prepared.calls[1].data) == keccak256(callData), "wrong trade calldata");
        // forge-lint: disable-next-line(block-timestamp)
        require(prepared.validUntil == block.timestamp + adapter.PREPARATION_VALIDITY(), "wrong expiry");
    }

    function testTransactionCallbackRejectsChangedCalldata() external view {
        address account = address(0xbeef);
        AvantisOpenTradeParameters memory parameters = _openParameters();
        bytes memory expected = _openCallData(account, parameters);
        parameters.takeProfit++;
        bytes memory changed = _openCallData(account, parameters);
        (bool success,) = address(adapter)
            .staticcall(
                abi.encodeCall(
                    adapter.transactionCallback,
                    (
                        _transactionResponse(account, parameters.executionFeeWei, changed),
                        abi.encode(account, expected, parameters.executionFeeWei, parameters.collateralUsdc)
                    )
                )
            );
        require(!success, "changed calldata should fail");
    }

    function testMarginCallbackValidatesDynamicOracleCalldata() external view {
        address account = address(0xbeef);
        AvantisMarginParameters memory parameters = AvantisMarginParameters({
            pairIndex: 1,
            tradeIndex: 2,
            action: AvantisMarginAction.DEPOSIT,
            collateralUsdc: 25e6,
            priceSourcing: 1,
            oracleFeeWei: 1
        });
        bytes[] memory updates = new bytes[](1);
        updates[0] = hex"1234";
        bytes memory callData = abi.encodeCall(
            IAvantisTrading.updateMargin,
            (
                parameters.pairIndex,
                parameters.tradeIndex,
                uint8(parameters.action),
                parameters.collateralUsdc,
                updates,
                parameters.priceSourcing
            )
        );
        PreparedAction memory prepared = adapter.marginCallback(
            _transactionResponse(account, parameters.oracleFeeWei, callData), abi.encode(account, parameters)
        );
        require(prepared.calls.length == 2, "expected approval and margin update");
        require(prepared.calls[1].value == 1, "wrong oracle fee");
        require(keccak256(prepared.calls[1].data) == keccak256(callData), "wrong margin calldata");
    }

    function testDelegateActionsAreConstructedLocally() external view {
        AvantisDelegateParameters memory parameters =
            AvantisDelegateParameters({delegate: address(0xdead), expiry: uint64(block.timestamp + 1 days)});
        PreparedAction memory setDelegate =
            adapter.prepare(adapter.SET_DELEGATE_ACTION(), address(0xbeef), abi.encode(parameters));
        require(setDelegate.calls.length == 1, "wrong set call count");
        require(setDelegate.validUntil == parameters.expiry, "wrong delegate expiry");
        require(
            keccak256(setDelegate.calls[0].data)
                == keccak256(abi.encodeCall(IAvantisTrading.setDelegate, (parameters.delegate, parameters.expiry))),
            "wrong set calldata"
        );

        PreparedAction memory removeDelegate =
            adapter.prepare(adapter.REMOVE_DELEGATE_ACTION(), address(0xbeef), abi.encode(parameters.delegate));
        require(removeDelegate.calls.length == 1, "wrong remove call count");
        require(
            keccak256(removeDelegate.calls[0].data)
                == keccak256(abi.encodeCall(IAvantisTrading.removeDelegate, (parameters.delegate))),
            "wrong remove calldata"
        );
    }

    function _openParameters() private pure returns (AvantisOpenTradeParameters memory) {
        return AvantisOpenTradeParameters({
            pairIndex: 0,
            isLong: true,
            orderType: AvantisOrderType.LIMIT,
            collateralUsdc: 100e6,
            leverage: 10 * 1e10,
            slippagePercent: 1e10,
            openPrice: 4_000 * 1e10,
            takeProfit: 5_000 * 1e10,
            stopLoss: 3_000 * 1e10,
            executionFeeWei: 350_000_000_000_000
        });
    }

    function _openCallData(address account, AvantisOpenTradeParameters memory parameters)
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
        AvantisTransaction memory transaction = AvantisTransaction({
            chainId: 8453,
            to: 0x44914408af82bC9983bbb330e3578E1105e11d4e,
            from: account,
            value: value,
            callData: callData
        });
        return _projectedResponse(abi.encode(transaction));
    }

    function _projectedResponse(bytes memory encoded) private pure returns (HttpResponse memory) {
        HttpHeader[] memory headers = new HttpHeader[](0);
        return HttpResponse({
            status: 200,
            headers: headers,
            rawBodyHash: keccak256(encoded),
            bodyEncoding: ResponseBodyEncoding.JSON_ABI,
            body: encoded
        });
    }

    function _projectedTrades(address account) private pure returns (AvantisTradeInfo[] memory trades) {
        trades = new AvantisTradeInfo[](1);
        trades[0] = AvantisTradeInfo({
            trader: account,
            pairIndex: 0,
            tradeIndex: 0,
            collateralUsdc: 100e6,
            openPrice: 40_000 * 1e10,
            isLong: true,
            leverage: 10 * 1e10,
            takeProfit: 50_000 * 1e10,
            stopLoss: 30_000 * 1e10,
            liquidationPrice: 35_000 * 1e10
        });
    }

    function _response(bytes memory body) private pure returns (HttpResponse memory) {
        HttpHeader[] memory headers = new HttpHeader[](0);
        return HttpResponse({
            status: 200,
            headers: headers,
            rawBodyHash: keccak256(body),
            bodyEncoding: ResponseBodyEncoding.RAW,
            body: body
        });
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
