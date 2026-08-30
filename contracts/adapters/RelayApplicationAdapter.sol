// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

import {Call, IApplicationActions, PreparedAction} from "../IApplicationActions.sol";
import {IApplicationQueries} from "../IApplicationQueries.sol";
import {
    ExternalRequest,
    HttpHeader,
    HttpRequest,
    HttpResponse,
    JsonAbiNode,
    JsonAbiNodeType,
    RequestRequirement,
    ResponseBodyEncoding,
    ResponseTransform,
    ResponseTransformKind
} from "../IExternalRequest.sol";
import {Text} from "../lib/Text.sol";

/// @notice Parameterization for an indicative EXACT_INPUT Relay route preview.
/// @dev `account` is the depositor Relay quotes for. Application Queries has no
/// distinguished account argument, so the caller MUST pass it here.
struct RelayRouteInput {
    address account;
    uint256 originChainId;
    uint256 destinationChainId;
    address originCurrency;
    address destinationCurrency;
    uint256 amount;
}

/// @notice Parameterization for an EXACT_INPUT executable Relay bridge/swap.
/// @dev The depositor is the `account` passed to prepare() and is NOT repeated.
/// @param recipient Effective recipient (0 resolves to `account`).
struct RelayExactInput {
    uint256 originChainId;
    uint256 destinationChainId;
    address originCurrency;
    address destinationCurrency;
    uint256 amount;
    address recipient;
    uint16 slippageBps;
    uint64 ttlSeconds;
}

/// @notice A projected Relay `/quote/v2` transaction step item (`items[].data`).
struct RelayStepItem {
    address from;
    address to;
    bytes data;
    uint256 value;
    uint256 chainId;
}

/// @notice A projected Relay `/quote/v2` step: a kind plus its transaction items.
/// @dev `kind` is the JSON "transaction" or "signature" value.
struct RelayStep {
    string kind;
    RelayStepItem[] items;
}

/// @notice Result of the RAW indicative quote query.
struct RelayRouteResult {
    bytes32 queryId;
    address account;
    bytes32 parametersHash;
    uint16 status;
    bytes32 rawBodyHash;
    bytes body;
    uint256 observedAt;
}

/// @notice Experimental hybrid query/action adapter for Relay (relay.link).
/// @dev One adapter serves any EVM origin chain because origin and destination are
/// carried in the parameters. Execution takes Relay's EXACT_INPUT `/quote/v2` and
/// reduces it to the ordered origin-chain EVM calls (approve + deposit/swap).
/// Destination-chain fulfillment and `signature` kind steps cannot be represented
/// by `PreparedAction`, so the adapter reverts loudly on a quote that contains them.
contract RelayApplicationAdapter is IApplicationQueries, IApplicationActions {
    bytes32 public constant QUOTE_QUERY = keccak256("relay.route.quote");
    bytes32 public constant EXACT_INPUT_ACTION = keccak256("relay.bridge.exactInput");

    uint256 public constant MAX_RESPONSE_BYTES = 512_000;
    uint256 public constant MAX_CALLDATA_BYTES = 64_000;
    uint256 public constant MAX_STEPS = 32;
    uint256 public constant MAX_ITEMS_PER_STEP = 8;
    uint256 public constant MAX_SLIPPAGE_BPS = 10_000;
    uint256 public constant MAX_TTL_SECONDS = 1 hours;
    bytes32 public constant TRANSACTION_KIND = keccak256("transaction");
    bytes32 public constant SIGNATURE_KIND = keccak256("signature");

    string public apiBaseUrl;

    error UnknownQuery(bytes32 queryId);
    error UnknownAction(bytes32 actionId);
    error InvalidParameters();
    error InvalidApiResponse(uint16 status);
    error SignatureStepUnsupported();
    error NonOriginTransaction(uint256 observedChainId, uint256 originChainId);
    error UnboundTransaction(address observedFrom, address account);
    error Overdraw(uint256 value, uint256 amount);
    error NoOriginTransaction();

    constructor(string memory apiBaseUrl_) {
        if (bytes(apiBaseUrl_).length == 0) revert InvalidParameters();
        apiBaseUrl = apiBaseUrl_;
    }

    // --- Application Queries --------------------------------------------------

    function queries() external pure returns (bytes32[] memory queryIds) {
        queryIds = new bytes32[](1);
        queryIds[0] = QUOTE_QUERY;
    }

    function queryDescriptor(bytes32 queryId) external pure returns (bytes memory descriptor) {
        if (queryId == QUOTE_QUERY) return _quoteQueryDescriptor();
        revert UnknownQuery(queryId);
    }

    function query(bytes32 queryId, bytes calldata parameters) external view returns (bytes memory) {
        if (queryId != QUOTE_QUERY) revert UnknownQuery(queryId);
        RelayRouteInput memory route = abi.decode(parameters, (RelayRouteInput));
        _validateRoute(route);
        RelayExactInput memory relay = RelayExactInput({
            originChainId: route.originChainId,
            destinationChainId: route.destinationChainId,
            originCurrency: route.originCurrency,
            destinationCurrency: route.destinationCurrency,
            amount: route.amount,
            recipient: route.account,
            slippageBps: 0,
            ttlSeconds: 0
        });
        _revertRequest(
            _quoteBody(route.account, route.account, relay, true),
            _rawTransform(),
            this.externalQueryCallback.selector,
            abi.encode(queryId, route.account, keccak256(parameters))
        );
    }

    function externalQueryCallback(HttpResponse calldata response, bytes calldata extraData)
        external
        view
        returns (bytes memory)
    {
        _validateResponse(response);
        (bytes32 queryId, address account, bytes32 parametersHash) = abi.decode(extraData, (bytes32, address, bytes32));
        if (queryId != QUOTE_QUERY) revert UnknownQuery(queryId);
        return abi.encode(
            RelayRouteResult({
                queryId: queryId,
                account: account,
                parametersHash: parametersHash,
                status: response.status,
                rawBodyHash: response.rawBodyHash,
                body: response.body,
                observedAt: block.timestamp
            })
        );
    }

    // --- Application Actions --------------------------------------------------

    function actions() external pure returns (bytes32[] memory actionIds) {
        actionIds = new bytes32[](1);
        actionIds[0] = EXACT_INPUT_ACTION;
    }

    function actionDescriptor(bytes32 actionId) external pure returns (bytes memory descriptor) {
        if (actionId == EXACT_INPUT_ACTION) return _actionDescriptor();
        revert UnknownAction(actionId);
    }

    function prepare(bytes32 actionId, address account, bytes calldata parameters)
        external
        view
        returns (PreparedAction memory)
    {
        if (actionId != EXACT_INPUT_ACTION) revert UnknownAction(actionId);
        if (account == address(0)) revert InvalidParameters();
        RelayExactInput memory relay = abi.decode(parameters, (RelayExactInput));
        _validateExactInput(relay);
        address recipient = relay.recipient == address(0) ? account : relay.recipient;
        if (recipient == address(0)) revert InvalidParameters();
        _revertRequest(
            _quoteBody(account, recipient, relay, false),
            _stepsTransform(),
            this.prepareCallback.selector,
            abi.encode(account, relay)
        );
    }

    function prepareCallback(HttpResponse calldata response, bytes calldata extraData)
        external
        view
        returns (PreparedAction memory)
    {
        _validateResponse(response);
        if (response.bodyEncoding != ResponseBodyEncoding.JSON_ABI) revert InvalidApiResponse(response.status);
        RelayStep[] memory steps = abi.decode(response.body, (RelayStep[]));
        (address account, RelayExactInput memory relay) = abi.decode(extraData, (address, RelayExactInput));

        // Pass one: size the call array and validate every projected item so a
        // malicious or mismatched quote fails before any Call is produced.
        uint256 callCount;
        for (uint256 s = 0; s < steps.length; s++) {
            _requireTransactionKind(steps[s].kind);
            for (uint256 i = 0; i < steps[s].items.length; i++) {
                RelayStepItem memory item = steps[s].items[i];
                _validateItem(item, account, relay.originChainId, relay.amount);
                if (item.chainId == relay.originChainId) callCount++;
            }
        }
        if (callCount == 0) revert NoOriginTransaction();

        // Pass two: emit origin-chain calls in step-then-item order.
        Call[] memory calls = new Call[](callCount);
        uint256 cursor;
        for (uint256 s = 0; s < steps.length; s++) {
            for (uint256 i = 0; i < steps[s].items.length; i++) {
                RelayStepItem memory item = steps[s].items[i];
                if (item.chainId != relay.originChainId) continue;
                if (item.to == address(0) || item.data.length > MAX_CALLDATA_BYTES) {
                    revert InvalidApiResponse(response.status);
                }
                calls[cursor++] = Call({target: item.to, value: item.value, data: item.data});
            }
        }
        return PreparedAction({calls: calls, validUntil: block.timestamp + relay.ttlSeconds});
    }

    // --- request construction -------------------------------------------------

    function _quoteBody(address account, address recipient, RelayExactInput memory relay, bool indicative)
        private
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(
            '{"user":"',
            Text.addressString(account),
            '","recipient":"',
            Text.addressString(recipient),
            '","originChainId":',
            Text.uintString(relay.originChainId),
            ',"destinationChainId":',
            Text.uintString(relay.destinationChainId),
            ',"originCurrency":"',
            Text.addressString(relay.originCurrency),
            '","destinationCurrency":"',
            Text.addressString(relay.destinationCurrency),
            '","amount":"',
            Text.uintString(relay.amount),
            '","tradeType":"EXACT_INPUT","usePermit":false,"explicitDeposit":true',
            indicative ? ',"indicativeQuote":true' : "",
            indicative ? "" : string.concat(',"slippageTolerance":"', Text.uintString(relay.slippageBps), '"'),
            indicative ? "" : string.concat(',"ttl":', Text.uintString(relay.ttlSeconds)),
            ',"source":"onchain-app-interfaces"}'
        );
    }

    function _revertRequest(
        bytes memory body,
        ResponseTransform memory transform,
        bytes4 callback,
        bytes memory extraData
    ) private view {
        HttpHeader[] memory headers = new HttpHeader[](2);
        headers[0] = HttpHeader({name: "Accept", value: "application/json"});
        headers[1] = HttpHeader({name: "Content-Type", value: "application/json"});
        RequestRequirement[] memory requirements = new RequestRequirement[](0);
        revert ExternalRequest({
            sender: address(this),
            request: HttpRequest({
                url: string.concat(apiBaseUrl, "/quote/v2"),
                method: "POST",
                headers: headers,
                body: body,
                requirements: requirements
            }),
            responseTransform: transform,
            callbackFunction: callback,
            extraData: extraData
        });
    }

    // --- validation -----------------------------------------------------------

    function _validateRoute(RelayRouteInput memory route) private pure {
        if (
            route.account == address(0) || route.originChainId == 0 || route.destinationChainId == 0
                || route.amount == 0
        ) {
            revert InvalidParameters();
        }
    }

    function _validateExactInput(RelayExactInput memory relay) private pure {
        if (
            relay.originChainId == 0 || relay.destinationChainId == 0 || relay.amount == 0
                || relay.slippageBps > MAX_SLIPPAGE_BPS || relay.ttlSeconds == 0 || relay.ttlSeconds > MAX_TTL_SECONDS
        ) revert InvalidParameters();
    }

    function _validateResponse(HttpResponse calldata response) private pure {
        if (response.status != 200 || response.body.length == 0 || response.body.length > MAX_RESPONSE_BYTES) {
            revert InvalidApiResponse(response.status);
        }
    }

    function _requireTransactionKind(string memory kind) private pure {
        bytes32 k = keccak256(bytes(kind));
        if (k == SIGNATURE_KIND) revert SignatureStepUnsupported();
        if (k != TRANSACTION_KIND) revert InvalidParameters();
    }

    function _validateItem(RelayStepItem memory item, address account, uint256 originChainId, uint256 amount)
        private
        pure
    {
        if (item.chainId != originChainId) revert NonOriginTransaction(item.chainId, originChainId);
        if (item.from != account) revert UnboundTransaction(item.from, account);
        if (item.value > amount) revert Overdraw(item.value, amount);
    }

    // --- transforms ----------------------------------------------------------

    function _rawTransform() private pure returns (ResponseTransform memory transform) {
        JsonAbiNode[] memory nodes = new JsonAbiNode[](0);
        transform = ResponseTransform({kind: ResponseTransformKind.RAW, statusFrom: 0, statusTo: 0, nodes: nodes});
    }

    /// @notice Flattens `steps[]` into `RelayStep[] {kind, items[] {from,to,data,value,chainId}}`.
    function _stepsTransform() private pure returns (ResponseTransform memory transform) {
        JsonAbiNode[] memory nodes = new JsonAbiNode[](11);
        nodes[0] = _node(JsonAbiNodeType.TUPLE, "", 1, 0);
        // MAX_STEPS and MAX_ITEMS_PER_STEP are small literals; the uint32 cast cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        nodes[1] = _node(JsonAbiNodeType.ARRAY, "/steps", 1, uint32(MAX_STEPS));
        nodes[2] = _node(JsonAbiNodeType.TUPLE, "", 2, 0);
        nodes[3] = _node(JsonAbiNodeType.STRING, "/kind", 0, 0);
        // forge-lint: disable-next-line(unsafe-typecast)
        nodes[4] = _node(JsonAbiNodeType.ARRAY, "/items", 1, uint32(MAX_ITEMS_PER_STEP));
        nodes[5] = _node(JsonAbiNodeType.TUPLE, "", 1, 0);
        nodes[6] = _node(JsonAbiNodeType.TUPLE, "/data", 5, 0);
        nodes[7] = _node(JsonAbiNodeType.ADDRESS, "/from", 0, 0);
        nodes[8] = _node(JsonAbiNodeType.ADDRESS, "/to", 0, 0);
        nodes[9] = _node(JsonAbiNodeType.BYTES, "/data", 0, 0);
        nodes[10] = _node(JsonAbiNodeType.UINT256_DECIMAL, "/value", 0, 0);
        nodes[11] = _node(JsonAbiNodeType.UINT256_DECIMAL, "/chainId", 0, 0);
        transform =
            ResponseTransform({kind: ResponseTransformKind.JSON_ABI, statusFrom: 200, statusTo: 299, nodes: nodes});
    }

    function _node(JsonAbiNodeType nodeType, string memory pointer, uint16 childCount, uint32 maxItems)
        private
        pure
        returns (JsonAbiNode memory node)
    {
        node = JsonAbiNode({nodeType: nodeType, pointer: pointer, childCount: childCount, maxItems: maxItems});
    }

    // --- descriptors ---------------------------------------------------------

    function _quoteQueryDescriptor() private pure returns (bytes memory descriptor) {
        return bytes(
            '{"version":"0.1","kind":"query","name":"relay.route.quote","inputs":{"encoding":"abi","fields":[{"name":"account","abiType":"address","semanticType":"account"},{"name":"originChainId","abiType":"uint256","semanticType":"chainId"},{"name":"destinationChainId","abiType":"uint256","semanticType":"chainId"},{"name":"originCurrency","abiType":"address","semanticType":"erc20"},{"name":"destinationCurrency","abiType":"address","semanticType":"erc20"},{"name":"amount","abiType":"uint256","semanticType":"tokenAmount","assetField":"originCurrency","minimum":"1"}]},"output":{"encoding":"abi","fields":[{"name":"result","abiType":"tuple","components":[{"name":"queryId","abiType":"bytes32","semanticType":"capabilityId"},{"name":"account","abiType":"address","semanticType":"account"},{"name":"parametersHash","abiType":"bytes32"},{"name":"status","abiType":"uint16","semanticType":"httpStatus"},{"name":"rawBodyHash","abiType":"bytes32"},{"name":"body","abiType":"bytes","contentType":"application/json"},{"name":"observedAt","abiType":"uint256","semanticType":"timestamp"}]}]},"provenance":{"type":"configured-origin"}}'
        );
    }

    function _actionDescriptor() private pure returns (bytes memory descriptor) {
        return bytes(
            '{"version":"0.1","kind":"action","name":"relay.bridge.exactInput","inputs":{"encoding":"abi","fields":[{"name":"parameters","abiType":"tuple","components":[{"name":"originChainId","abiType":"uint256","semanticType":"chainId","minimum":"1"},{"name":"destinationChainId","abiType":"uint256","semanticType":"chainId","minimum":"1"},{"name":"originCurrency","abiType":"address","semanticType":"erc20"},{"name":"destinationCurrency","abiType":"address","semanticType":"erc20"},{"name":"amount","abiType":"uint256","semanticType":"tokenAmount","assetField":"parameters.originCurrency","minimum":"1"},{"name":"recipient","abiType":"address","semanticType":"account"},{"name":"slippageBps","abiType":"uint16","semanticType":"basisPoints","minimum":"0","maximum":"10000"},{"name":"ttlSeconds","abiType":"uint64","semanticType":"duration","minimum":"1","maximum":"3600"}]}]},"output":{"encoding":"preparedAction"},"effects":[{"type":"decrease","assetField":"parameters.originCurrency","amountField":"parameters.amount"},{"type":"increase","assetField":"parameters.destinationCurrency","chainIdField":"parameters.destinationChainId","description":"Destination fills are solver-mediated and outside this PreparedAction"}],"execution":{"atomicity":"atomic-required"},"provenance":{"type":"hybrid"}}'
        );
    }
}
