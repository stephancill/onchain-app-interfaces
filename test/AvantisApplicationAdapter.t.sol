// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

import {PreparedAction} from "../contracts/IApplicationActions.sol";
import {HttpHeader, HttpResponse} from "../contracts/IExternalRequest.sol";
import {AvantisApplicationAdapter} from "../contracts/adapters/AvantisApplicationAdapter.sol";
import {AvantisActionCodec} from "../contracts/adapters/AvantisActionCodec.sol";
import {AvantisRequestCodec} from "../contracts/adapters/AvantisRequestCodec.sol";
import {
    AvantisCancelLimitParameters,
    AvantisCloseTradeParameters,
    AvantisLimitUpdateParameters,
    AvantisMarginAction,
    AvantisMarginUpdateParameters,
    AvantisOpenTradeParameters,
    AvantisOrderType,
    AvantisRemoveDelegateParameters,
    AvantisSetDelegateParameters,
    AvantisTrade,
    IAvantisErc20,
    IAvantisTrading
} from "../contracts/adapters/AvantisTypes.sol";

interface AvantisVm {
    function etch(address target, bytes calldata code) external;
}

contract AvantisMockTokenNeedsApproval {
    function balanceOf(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function allowance(address, address) external pure returns (uint256) {
        return 0;
    }
}

contract AvantisMockTokenApproved {
    function balanceOf(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function allowance(address, address) external pure returns (uint256) {
        return type(uint256).max;
    }
}

contract AvantisApplicationAdapterTest {
    AvantisVm internal constant vm = AvantisVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address internal constant ACCOUNT = address(0xbeef);
    address internal constant DELEGATE = address(0xd1e6a7e);

    AvantisActionCodec internal actionCodec = new AvantisActionCodec();
    AvantisRequestCodec internal requestCodec = new AvantisRequestCodec();
    AvantisApplicationAdapter internal adapter = new AvantisApplicationAdapter(
        "https://core.avantisfi.com", "https://tx-builder.avantisfi.com", actionCodec, requestCodec
    );

    function setUp() external {
        AvantisMockTokenNeedsApproval token = new AvantisMockTokenNeedsApproval();
        vm.etch(adapter.USDC(), address(token).code);
    }

    function testDiscoveryAndDescriptors() external view {
        bytes32[] memory queryIds = adapter.queries();
        bytes32[] memory actionIds = adapter.actions();
        require(queryIds.length == 1 && queryIds[0] == adapter.POSITIONS_QUERY(), "positions discovery");
        require(actionIds.length == 7, "action count");
        require(actionIds[0] == adapter.OPEN_TRADE_ACTION(), "open discovery");
        require(actionIds[1] == adapter.CLOSE_TRADE_ACTION(), "close discovery");
        require(actionIds[2] == adapter.CANCEL_LIMIT_ACTION(), "cancel discovery");
        require(actionIds[3] == adapter.UPDATE_MARGIN_ACTION(), "margin discovery");
        require(actionIds[4] == adapter.UPDATE_LIMIT_ACTION(), "limit discovery");
        require(actionIds[5] == adapter.SET_DELEGATE_ACTION(), "set delegate discovery");
        require(actionIds[6] == adapter.REMOVE_DELEGATE_ACTION(), "remove delegate discovery");

        bytes memory queryDescriptor = adapter.queryDescriptor(queryIds[0]);
        require(_contains(queryDescriptor, '"encoding":"json"'), "json output descriptor");
        require(_contains(queryDescriptor, '"abiType":"tuple[]"'), "array descriptor");
        require(_contains(queryDescriptor, '"maxItems":64'), "array bound descriptor");
        require(_contains(queryDescriptor, '"equalsInput":"account"'), "trader binding descriptor");
        for (uint256 i = 0; i < actionIds.length; i++) {
            bytes memory actionDescriptor = adapter.actionDescriptor(actionIds[i]);
            require(_contains(actionDescriptor, '"atomicity":"atomic-required"'), "atomic descriptor");
            require(_contains(actionDescriptor, '"effects":'), "effects descriptor");
        }
    }

    function testConstructorRejectsUntrustedCodecs() external {
        try new AvantisApplicationAdapter(
            "https://core.avantisfi.com",
            "https://tx-builder.avantisfi.com",
            AvantisActionCodec(address(requestCodec)),
            requestCodec
        ) {
            revert("swapped codec accepted");
        } catch {}

        try new AvantisApplicationAdapter(
            "https://core.avantisfi.com",
            "https://tx-builder.avantisfi.com",
            AvantisActionCodec(address(0xbeef)),
            requestCodec
        ) {
            revert("EOA codec accepted");
        } catch {}
    }

    function testSlippageIsCappedAtProtocolMaximum() external view {
        AvantisOpenTradeParameters memory p = _openParameters();
        p.slippagePercent = 80 * 1e10;
        requestCodec.url("https://tx-builder.avantisfi.com", adapter.OPEN_TRADE_ACTION(), ACCOUNT, abi.encode(p));

        p.slippagePercent++;
        (bool success,) = address(requestCodec)
            .staticcall(
                abi.encodeCall(
                    requestCodec.url,
                    ("https://tx-builder.avantisfi.com", adapter.OPEN_TRADE_ACTION(), ACCOUNT, abi.encode(p))
                )
            );
        require(!success, "slippage above 80 percent accepted");
    }

    function testPositionsCallbackReturnsRawBody() external view {
        bytes memory body =
            '{"positions":[{"trader":"0x000000000000000000000000000000000000beef","pairIndex":62}],"limitOrders":[]}';
        bytes memory returned = adapter.positionsCallback(_response(body), "");
        require(keccak256(returned) == keccak256(body), "raw body mismatch");
    }

    function testPositionsCallbackRejectsBadResponses() external view {
        _expectPositionsRevert(new bytes(128_001));
        (bool success,) = address(adapter)
            .staticcall(
                abi.encodeCall(
                    adapter.positionsCallback, (_responseWithStatus(429, '{"positions":[],"limitOrders":[]}'), "")
                )
            );
        require(!success, "non-200 accepted");
        (bool emptyOk,) = address(adapter).staticcall(abi.encodeCall(adapter.positionsCallback, (_response(""), "")));
        require(!emptyOk, "empty body accepted");
    }

    function testOpenTradeSuccessAndExactApproval() external view {
        AvantisOpenTradeParameters memory p = _openParameters();
        bytes memory data = _openData(ACCOUNT, p);
        PreparedAction memory prepared = adapter.openTradeCallback(
            _transactionResponse({
                to: adapter.TRADING(), from: ACCOUNT, chainId: 8453, value: p.executionFeeWei, data: data
            }),
            abi.encode(adapter.OPEN_TRADE_ACTION(), ACCOUNT, abi.encode(p))
        );
        require(prepared.calls.length == 2, "open approval count");
        require(prepared.calls[0].target == adapter.USDC() && prepared.calls[0].value == 0, "approval target");
        require(
            keccak256(prepared.calls[0].data)
                == keccak256(abi.encodeCall(IAvantisErc20.approve, (adapter.TRADING_STORAGE(), p.collateralUsdc))),
            "exact approval"
        );
        _assertActionCall(prepared, 1, p.executionFeeWei, data);
    }

    function testOpenTradeSkipsApprovalWhenAllowanceSufficient() external {
        AvantisMockTokenApproved token = new AvantisMockTokenApproved();
        vm.etch(adapter.USDC(), address(token).code);
        AvantisOpenTradeParameters memory p = _openParameters();
        bytes memory data = _openData(ACCOUNT, p);
        PreparedAction memory prepared = adapter.openTradeCallback(
            _transactionResponse({
                to: adapter.TRADING(), from: ACCOUNT, chainId: 8453, value: p.executionFeeWei, data: data
            }),
            abi.encode(adapter.OPEN_TRADE_ACTION(), ACCOUNT, abi.encode(p))
        );
        require(prepared.calls.length == 1, "unexpected approval");
        _assertActionCall(prepared, 0, p.executionFeeWei, data);
    }

    function testCloseTradeSuccessAndRejectsFieldTampering() external view {
        AvantisCloseTradeParameters memory p = AvantisCloseTradeParameters({
            pairIndex: 2,
            tradeIndex: 4,
            collateralToCloseUsdc: 50_000_000,
            expectedPrice: 2_000 * 1e10,
            executionFeeWei: 350_000_000_000_000
        });
        bytes memory data = abi.encodeCall(
            IAvantisTrading.closeTradeMarket, (p.pairIndex, p.tradeIndex, p.collateralToCloseUsdc, p.expectedPrice)
        );
        PreparedAction memory prepared = _action(adapter.CLOSE_TRADE_ACTION(), abi.encode(p), p.executionFeeWei, data);
        _assertActionCall(prepared, 0, p.executionFeeWei, data);
        bytes memory tampered = abi.encodeCall(
            IAvantisTrading.closeTradeMarket, (p.pairIndex, p.tradeIndex + 1, p.collateralToCloseUsdc, p.expectedPrice)
        );
        _expectActionRevert(adapter.CLOSE_TRADE_ACTION(), abi.encode(p), p.executionFeeWei, tampered);
    }

    function testCancelLimitSuccessAndRejectsFieldTampering() external view {
        AvantisCancelLimitParameters memory p = AvantisCancelLimitParameters({pairIndex: 2, orderIndex: 7});
        bytes memory data = abi.encodeCall(IAvantisTrading.cancelOpenLimitOrder, (p.pairIndex, p.orderIndex));
        _assertActionCall(_action(adapter.CANCEL_LIMIT_ACTION(), abi.encode(p), 0, data), 0, 0, data);
        _expectActionRevert(
            adapter.CANCEL_LIMIT_ACTION(),
            abi.encode(p),
            0,
            abi.encodeCall(IAvantisTrading.cancelOpenLimitOrder, (p.pairIndex + 1, p.orderIndex))
        );
    }

    function testMarginDepositSuccessAndExactApproval() external view {
        AvantisMarginUpdateParameters memory p = _marginParameters(AvantisMarginAction.DEPOSIT);
        bytes[] memory prices = new bytes[](2);
        prices[0] = hex"1234";
        prices[1] = hex"5678";
        bytes memory data = abi.encodeCall(
            IAvantisTrading.updateMargin,
            (p.pairIndex, p.tradeIndex, uint8(p.action), p.collateralUsdc, prices, uint8(1))
        );
        PreparedAction memory prepared = _action(adapter.UPDATE_MARGIN_ACTION(), abi.encode(p), p.oracleFeeWei, data);
        require(prepared.calls.length == 2, "margin approval count");
        require(
            keccak256(prepared.calls[0].data)
                == keccak256(abi.encodeCall(IAvantisErc20.approve, (adapter.TRADING_STORAGE(), p.collateralUsdc))),
            "margin exact approval"
        );
        _assertActionCall(prepared, 1, p.oracleFeeWei, data);
    }

    function testMarginWithdrawSuccessAndRejectsTampering() external view {
        AvantisMarginUpdateParameters memory p = _marginParameters(AvantisMarginAction.WITHDRAW);
        bytes[] memory prices = new bytes[](1);
        prices[0] = hex"1234";
        bytes memory data = abi.encodeCall(
            IAvantisTrading.updateMargin,
            (p.pairIndex, p.tradeIndex, uint8(p.action), p.collateralUsdc, prices, uint8(0))
        );
        PreparedAction memory prepared = _action(adapter.UPDATE_MARGIN_ACTION(), abi.encode(p), p.oracleFeeWei, data);
        require(prepared.calls.length == 1, "withdraw approval");
        _assertActionCall(prepared, 0, p.oracleFeeWei, data);
        bytes memory tampered = abi.encodeCall(
            IAvantisTrading.updateMargin,
            (p.pairIndex, p.tradeIndex, uint8(p.action), p.collateralUsdc + 1, prices, uint8(0))
        );
        _expectActionRevert(adapter.UPDATE_MARGIN_ACTION(), abi.encode(p), p.oracleFeeWei, tampered);
    }

    function testMarginRejectsInvalidPriceSourceAndOversizedOracleBytes() external view {
        AvantisMarginUpdateParameters memory p = _marginParameters(AvantisMarginAction.WITHDRAW);
        bytes[] memory prices = new bytes[](1);
        prices[0] = hex"12";
        bytes memory invalidSource = abi.encodeWithSelector(
            IAvantisTrading.updateMargin.selector,
            p.pairIndex,
            p.tradeIndex,
            uint8(p.action),
            p.collateralUsdc,
            prices,
            uint8(2)
        );
        _expectActionRevert(adapter.UPDATE_MARGIN_ACTION(), abi.encode(p), p.oracleFeeWei, invalidSource);
        prices[0] = new bytes(16_385);
        bytes memory oversized = abi.encodeCall(
            IAvantisTrading.updateMargin,
            (p.pairIndex, p.tradeIndex, uint8(p.action), p.collateralUsdc, prices, uint8(0))
        );
        _expectActionRevert(adapter.UPDATE_MARGIN_ACTION(), abi.encode(p), p.oracleFeeWei, oversized);
    }

    function testLimitUpdateSuccessAndRejectsFieldTampering() external view {
        AvantisLimitUpdateParameters memory p = AvantisLimitUpdateParameters({
            pairIndex: 3,
            orderIndex: 5,
            price: 2_000 * 1e10,
            slippagePercent: 1e10,
            takeProfit: 2_200 * 1e10,
            stopLoss: 1_800 * 1e10
        });
        bytes memory data = abi.encodeCall(
            IAvantisTrading.updateOpenLimitOrder,
            (p.pairIndex, p.orderIndex, p.price, p.slippagePercent, p.takeProfit, p.stopLoss)
        );
        _assertActionCall(_action(adapter.UPDATE_LIMIT_ACTION(), abi.encode(p), 0, data), 0, 0, data);
        _expectActionRevert(
            adapter.UPDATE_LIMIT_ACTION(),
            abi.encode(p),
            0,
            abi.encodeCall(
                IAvantisTrading.updateOpenLimitOrder,
                (p.pairIndex, p.orderIndex, p.price + 1, p.slippagePercent, p.takeProfit, p.stopLoss)
            )
        );
    }

    function testSetDelegateSuccessAndRejectsFieldTampering() external view {
        AvantisSetDelegateParameters memory p =
            AvantisSetDelegateParameters({delegate: DELEGATE, expirySeconds: block.timestamp + 1 days});
        bytes memory data = abi.encodeCall(IAvantisTrading.setDelegate, (p.delegate, p.expirySeconds));
        _assertActionCall(_action(adapter.SET_DELEGATE_ACTION(), abi.encode(p), 0, data), 0, 0, data);
        _expectActionRevert(
            adapter.SET_DELEGATE_ACTION(),
            abi.encode(p),
            0,
            abi.encodeCall(IAvantisTrading.setDelegate, (address(0x1234), p.expirySeconds))
        );
    }

    function testRemoveDelegateSuccessAndRejectsFieldTampering() external view {
        AvantisRemoveDelegateParameters memory p = AvantisRemoveDelegateParameters({delegate: DELEGATE});
        bytes memory data = abi.encodeCall(IAvantisTrading.removeDelegate, (p.delegate));
        _assertActionCall(_action(adapter.REMOVE_DELEGATE_ACTION(), abi.encode(p), 0, data), 0, 0, data);
        _expectActionRevert(
            adapter.REMOVE_DELEGATE_ACTION(),
            abi.encode(p),
            0,
            abi.encodeCall(IAvantisTrading.removeDelegate, (address(0x1234)))
        );
    }

    function testTransactionEnvelopeRejectsTargetFromChainValueSelectorAndNoncanonicalData() external view {
        AvantisCancelLimitParameters memory p = AvantisCancelLimitParameters({pairIndex: 2, orderIndex: 7});
        bytes memory data = abi.encodeCall(IAvantisTrading.cancelOpenLimitOrder, (p.pairIndex, p.orderIndex));
        bytes memory extra = abi.encode(adapter.CANCEL_LIMIT_ACTION(), ACCOUNT, abi.encode(p));
        _expectCallbackRevert(
            _transactionResponse({to: address(0x1234), from: ACCOUNT, chainId: 8453, value: 0, data: data}), extra
        );
        _expectCallbackRevert(
            _transactionResponse({to: adapter.TRADING(), from: address(0x1234), chainId: 8453, value: 0, data: data}),
            extra
        );
        _expectCallbackRevert(
            _transactionResponse({to: adapter.TRADING(), from: ACCOUNT, chainId: 1, value: 0, data: data}), extra
        );
        _expectCallbackRevert(
            _transactionResponse({to: adapter.TRADING(), from: ACCOUNT, chainId: 8453, value: 1, data: data}), extra
        );
        bytes memory wrongSelector = abi.encodeCall(IAvantisTrading.removeDelegate, (DELEGATE));
        _expectCallbackRevert(
            _transactionResponse({to: adapter.TRADING(), from: ACCOUNT, chainId: 8453, value: 0, data: wrongSelector}),
            extra
        );
        _expectCallbackRevert(
            _transactionResponse({
                to: adapter.TRADING(), from: ACCOUNT, chainId: 8453, value: 0, data: abi.encodePacked(data, bytes32(0))
            }),
            extra
        );
    }

    function testOpenTradeRejectsTamperedTrader() external view {
        AvantisOpenTradeParameters memory p = _openParameters();
        bytes memory extra = abi.encode(adapter.OPEN_TRADE_ACTION(), ACCOUNT, abi.encode(p));
        HttpResponse memory response = _transactionResponse({
            to: adapter.TRADING(),
            from: ACCOUNT,
            chainId: 8453,
            value: p.executionFeeWei,
            data: _openData(address(0xdead), p)
        });
        (bool success,) = address(adapter).staticcall(abi.encodeCall(adapter.openTradeCallback, (response, extra)));
        require(!success, "tampered open trader accepted");
    }

    function testDelegateParameterValidation() external view {
        AvantisSetDelegateParameters memory set =
            AvantisSetDelegateParameters({delegate: ACCOUNT, expirySeconds: block.timestamp + 1});
        _expectPrepareRevert(adapter.SET_DELEGATE_ACTION(), abi.encode(set));
        set.delegate = DELEGATE;
        set.expirySeconds = block.timestamp;
        _expectPrepareRevert(adapter.SET_DELEGATE_ACTION(), abi.encode(set));
        _expectPrepareRevert(
            adapter.REMOVE_DELEGATE_ACTION(), abi.encode(AvantisRemoveDelegateParameters({delegate: address(0)}))
        );
    }

    function _expectPositionsRevert(bytes memory body) private view {
        (bool success,) = address(adapter).staticcall(abi.encodeCall(adapter.positionsCallback, (_response(body), "")));
        require(!success, "invalid positions accepted");
    }

    function _action(bytes32 actionId, bytes memory parameters, uint256 value, bytes memory data)
        private
        view
        returns (PreparedAction memory)
    {
        return adapter.actionCallback(
            _transactionResponse({to: adapter.TRADING(), from: ACCOUNT, chainId: 8453, value: value, data: data}),
            abi.encode(actionId, ACCOUNT, parameters)
        );
    }

    function _expectActionRevert(bytes32 actionId, bytes memory parameters, uint256 value, bytes memory data)
        private
        view
    {
        _expectCallbackRevert(
            _transactionResponse({to: adapter.TRADING(), from: ACCOUNT, chainId: 8453, value: value, data: data}),
            abi.encode(actionId, ACCOUNT, parameters)
        );
    }

    function _expectCallbackRevert(HttpResponse memory response, bytes memory extra) private view {
        (bool success,) = address(adapter).staticcall(abi.encodeCall(adapter.actionCallback, (response, extra)));
        require(!success, "invalid action accepted");
    }

    function _expectPrepareRevert(bytes32 actionId, bytes memory parameters) private view {
        (bool success,) = address(adapter).staticcall(abi.encodeCall(adapter.prepare, (actionId, ACCOUNT, parameters)));
        require(!success, "invalid parameters accepted");
    }

    function _assertActionCall(PreparedAction memory prepared, uint256 index, uint256 value, bytes memory data)
        private
        view
    {
        require(prepared.calls[index].target == adapter.TRADING(), "action target");
        require(prepared.calls[index].value == value, "action value");
        require(keccak256(prepared.calls[index].data) == keccak256(data), "action data");
        // forge-lint: disable-next-line(block-timestamp)
        require(prepared.validUntil == block.timestamp + adapter.PREPARATION_VALIDITY(), "validity");
    }

    function _openParameters() private pure returns (AvantisOpenTradeParameters memory) {
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

    function _openData(address account, AvantisOpenTradeParameters memory p) private pure returns (bytes memory) {
        AvantisTrade memory trade = AvantisTrade({
            trader: account,
            pairIndex: p.pairIndex,
            index: 0,
            initialPosToken: 0,
            positionSizeUSDC: p.collateralUsdc,
            openPrice: p.openPrice,
            buy: p.isLong,
            leverage: p.leverage,
            tp: p.takeProfit,
            sl: p.stopLoss,
            timestamp: 0
        });
        return abi.encodeCall(IAvantisTrading.openTrade, (trade, uint8(p.orderType), p.slippagePercent));
    }

    function _marginParameters(AvantisMarginAction action) private pure returns (AvantisMarginUpdateParameters memory) {
        return AvantisMarginUpdateParameters({
            pairIndex: 2, tradeIndex: 4, action: action, collateralUsdc: 25_000_000, oracleFeeWei: 1
        });
    }

    function _transactionResponse(address to, address from, uint256 chainId, uint256 value, bytes memory data)
        private
        pure
        returns (HttpResponse memory)
    {
        return _response(
            abi.encodePacked(
                '{"ok":true,"data":{"to":"',
                _addressString(to),
                '","from":"',
                _addressString(from),
                '","data":"',
                _hexString(data),
                '","value":"0x',
                _uintHex(value),
                '","chainId":',
                _uintDecimal(chainId),
                ',"description":"test"}}'
            )
        );
    }

    function _response(bytes memory body) private pure returns (HttpResponse memory) {
        HttpHeader[] memory headers = new HttpHeader[](0);
        return HttpResponse({status: 200, headers: headers, body: body});
    }

    function _responseWithStatus(uint16 status, bytes memory body) private pure returns (HttpResponse memory) {
        HttpHeader[] memory headers = new HttpHeader[](0);
        return HttpResponse({status: status, headers: headers, body: body});
    }

    function _contains(bytes memory value, bytes memory needle) private pure returns (bool) {
        if (needle.length > value.length) return false;
        for (uint256 i = 0; i <= value.length - needle.length; i++) {
            bool matches = true;
            for (uint256 j = 0; j < needle.length; j++) {
                if (value[i + j] != needle[j]) matches = false;
            }
            if (matches) return true;
        }
        return false;
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

    function _uintDecimal(uint256 value) private pure returns (string memory) {
        if (value == 0) return "0";
        uint256 digits;
        uint256 remaining = value;
        while (remaining != 0) {
            digits++;
            remaining /= 10;
        }
        bytes memory output = new bytes(digits);
        while (value != 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            output[--digits] = bytes1(uint8(48 + value % 10));
            value /= 10;
        }
        return string(output);
    }
}
