// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

import {PreparedAction} from "../contracts/IApplicationActions.sol";
import {HttpHeader, HttpResponse, ResponseBodyEncoding} from "../contracts/IExternalRequest.sol";
import {
    RelayApplicationAdapter,
    RelayExactInput,
    RelayRouteInput,
    RelayRouteResult,
    RelayStep,
    RelayStepItem
} from "../contracts/adapters/RelayApplicationAdapter.sol";

contract RelayApplicationAdapterTest {
    RelayApplicationAdapter internal adapter = new RelayApplicationAdapter("https://api.relay.link");

    address internal constant USER = 0xbeeF000000000000000000000000000000000000;
    address internal constant DEPOSITORY = 0xf70da97812CB96acDF810712Aa562db8dfA3dbEF;
    // The approval step targets the origin ERC-20 (USDC on Base in the fixture).
    address internal constant APPROVE_TARGET = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    bytes internal constant APPROVE_DATA =
        hex"095ea7b3ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";
    bytes internal constant DEPOSIT_DATA = hex"58109c";
    uint256 internal constant ORIGIN = 8453;
    uint256 internal constant DESTINATION = 10;
    uint256 internal constant AMOUNT = 1 ether;
    uint64 internal constant TTL = 3600;

    function testDiscoversQuoteAndExactInput() external view {
        bytes32[] memory queryIds = adapter.queries();
        bytes32[] memory actionIds = adapter.actions();
        require(queryIds.length == 1, "wrong query count");
        require(queryIds[0] == adapter.QUOTE_QUERY(), "missing quote query");
        require(actionIds.length == 1, "wrong action count");
        require(actionIds[0] == adapter.EXACT_INPUT_ACTION(), "missing exact input action");
        require(adapter.queryDescriptor(adapter.QUOTE_QUERY()).length > 0, "missing query descriptor");
        require(adapter.actionDescriptor(adapter.EXACT_INPUT_ACTION()).length > 0, "missing action descriptor");
    }

    function testPrepareExitsViaExternalRequest() external view {
        bool success;
        bytes memory data;
        (success, data) = address(adapter)
            .staticcall(abi.encodeCall(adapter.prepare, (adapter.EXACT_INPUT_ACTION(), USER, abi.encode(_exact()))));
        // A valid prepare() must not resolve locally: it exits through ExternalRequest.
        require(!success, "prepare must exit via ExternalRequest");
        require(data.length >= 4, "expected a custom-error revert payload");
        // Guard the regression where building the steps transform wrote an
        // out-of-bounds transform node and reverted with a panic (0x32) instead.
        bytes4 selector;
        assembly {
            selector := mload(add(data, 0x20))
        }
        require(selector != 0x4e487b71, "prepare must not revert with a panic");
    }

    function testPrepareCallbackFlattensApproveThenDeposit() external view {
        RelayStepItem[] memory approveItems = new RelayStepItem[](1);
        approveItems[0] = _item(USER, APPROVE_TARGET, 0, ORIGIN, APPROVE_DATA);
        RelayStepItem[] memory depositItems = new RelayStepItem[](1);
        depositItems[0] = _item(USER, DEPOSITORY, AMOUNT, ORIGIN, DEPOSIT_DATA);

        RelayStep[] memory steps = new RelayStep[](2);
        steps[0] = RelayStep({kind: "transaction", items: approveItems});
        steps[1] = RelayStep({kind: "transaction", items: depositItems});

        PreparedAction memory prepared = adapter.prepareCallback(_encoded(steps), abi.encode(USER, _exact()));

        require(prepared.calls.length == 2, "expected approve then deposit");
        require(prepared.calls[0].target == APPROVE_TARGET, "wrong approve target");
        require(keccak256(prepared.calls[0].data) == keccak256(APPROVE_DATA), "wrong approve calldata");
        require(prepared.calls[1].target == DEPOSITORY, "wrong deposit target");
        require(prepared.calls[1].value == AMOUNT, "wrong deposit value");
        require(keccak256(prepared.calls[1].data) == keccak256(DEPOSIT_DATA), "wrong deposit calldata");
        // forge-lint: disable-next-line(block-timestamp)
        require(prepared.validUntil == block.timestamp + TTL, "wrong expiry");
    }

    function testPrepareCallbackRejectsSignatureStep() external view {
        RelayStep[] memory steps = new RelayStep[](1);
        steps[0] = RelayStep({kind: "signature", items: new RelayStepItem[](0)});
        (bool ok,) = address(adapter)
            .staticcall(abi.encodeCall(adapter.prepareCallback, (_encoded(steps), abi.encode(USER, _exact()))));
        require(!ok, "signature step must revert");
    }

    function testPrepareCallbackRejectsNonOriginChain() external view {
        RelayStepItem[] memory items = new RelayStepItem[](1);
        items[0] = _item(USER, DEPOSITORY, AMOUNT, DESTINATION, DEPOSIT_DATA);
        RelayStep[] memory steps = new RelayStep[](1);
        steps[0] = RelayStep({kind: "transaction", items: items});
        (bool ok,) = address(adapter)
            .staticcall(abi.encodeCall(adapter.prepareCallback, (_encoded(steps), abi.encode(USER, _exact()))));
        require(!ok, "non-origin transaction must revert");
    }

    function testPrepareCallbackRejectsUnboundSender() external view {
        RelayStepItem[] memory items = new RelayStepItem[](1);
        items[0] = _item(address(0xc0ffee), DEPOSITORY, AMOUNT, ORIGIN, DEPOSIT_DATA);
        RelayStep[] memory steps = new RelayStep[](1);
        steps[0] = RelayStep({kind: "transaction", items: items});
        (bool ok,) = address(adapter)
            .staticcall(abi.encodeCall(adapter.prepareCallback, (_encoded(steps), abi.encode(USER, _exact()))));
        require(!ok, "unbound sender must revert");
    }

    function testPrepareCallbackRejectsOverdraw() external view {
        RelayStepItem[] memory items = new RelayStepItem[](1);
        items[0] = _item(USER, DEPOSITORY, AMOUNT + 1, ORIGIN, DEPOSIT_DATA);
        RelayStep[] memory steps = new RelayStep[](1);
        steps[0] = RelayStep({kind: "transaction", items: items});
        (bool ok,) = address(adapter)
            .staticcall(abi.encodeCall(adapter.prepareCallback, (_encoded(steps), abi.encode(USER, _exact()))));
        require(!ok, "overdraw must revert");
    }

    function testPrepareCallbackRejectsEmptyOriginTransaction() external view {
        // A transaction step on a non-origin chain produces no origin calls.
        RelayStep[] memory steps = new RelayStep[](1);
        steps[0] = RelayStep({kind: "transaction", items: new RelayStepItem[](0)});
        (bool ok,) = address(adapter)
            .staticcall(abi.encodeCall(adapter.prepareCallback, (_encoded(steps), abi.encode(USER, _exact()))));
        require(!ok, "empty quote must revert");
    }

    function testQueryCallbackReturnsRawBody() external view {
        bytes memory raw = bytes('{"details":{"currencyOut":{"amount":"990000000000000000"}}}');
        HttpResponse memory response = HttpResponse({
            status: 200,
            headers: new HttpHeader[](0),
            rawBodyHash: keccak256(raw),
            bodyEncoding: ResponseBodyEncoding.RAW,
            body: raw
        });
        bytes memory out = adapter.externalQueryCallback(
            response, abi.encode(adapter.QUOTE_QUERY(), USER, keccak256(abi.encode(_route())))
        );
        RelayRouteResult memory result = abi.decode(out, (RelayRouteResult));
        require(result.queryId == adapter.QUOTE_QUERY(), "wrong query id");
        require(result.account == USER, "wrong account");
        require(result.rawBodyHash == keccak256(raw), "wrong raw body hash");
        require(keccak256(result.body) == keccak256(raw), "wrong body");
    }

    // --- helpers -------------------------------------------------------------

    function _exact() private pure returns (RelayExactInput memory) {
        return RelayExactInput({
            originChainId: ORIGIN,
            destinationChainId: DESTINATION,
            originCurrency: address(0),
            destinationCurrency: address(0),
            amount: AMOUNT,
            recipient: address(0),
            slippageBps: 30,
            ttlSeconds: TTL
        });
    }

    function _route() private pure returns (RelayRouteInput memory) {
        return RelayRouteInput({
            account: USER,
            originChainId: ORIGIN,
            destinationChainId: DESTINATION,
            originCurrency: address(0),
            destinationCurrency: address(0),
            amount: AMOUNT
        });
    }

    function _item(address from, address to, uint256 value, uint256 chainId, bytes memory data)
        private
        pure
        returns (RelayStepItem memory item)
    {
        item = RelayStepItem({from: from, to: to, data: data, value: value, chainId: chainId});
    }

    function _encoded(RelayStep[] memory steps) private pure returns (HttpResponse memory response) {
        bytes memory body = abi.encode(steps);
        response = HttpResponse({
            status: 200,
            headers: new HttpHeader[](0),
            rawBodyHash: keccak256(body),
            bodyEncoding: ResponseBodyEncoding.JSON_ABI,
            body: body
        });
    }
}
