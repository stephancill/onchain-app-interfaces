// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

import {Call, IApplicationActions, PreparedAction} from "../IApplicationActions.sol";
import {
    ExternalRequest,
    HttpHeader,
    HttpRequest,
    HttpResponse,
    JsonAbiNode,
    RequestRequirement,
    ResponseTransform,
    ResponseTransformKind
} from "../IExternalRequest.sol";
import {Json} from "../lib/Json.sol";
import {Text} from "../lib/Text.sol";

struct KyberSwapParameters {
    address tokenIn;
    address tokenOut;
    uint256 amountIn;
    uint256 minAmountOut;
    uint16 slippageBps;
    uint64 deadline;
}

struct KyberSwapDescription {
    address srcToken;
    address dstToken;
    address[] srcReceivers;
    uint256[] srcAmounts;
    address[] feeReceivers;
    uint256[] feeAmounts;
    address dstReceiver;
    uint256 amount;
    uint256 minReturnAmount;
    uint256 flags;
    bytes permit;
}

struct KyberSwapExecutionParams {
    address callTarget;
    address approveTarget;
    bytes targetData;
    KyberSwapDescription desc;
    bytes clientData;
}

interface IKyberErc20 {
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @notice Experimental recursive External Request adapter for KyberSwap on Base.
contract KyberSwapApplicationAdapter is IApplicationActions {
    bytes32 public constant SWAP_ACTION = keccak256("kyberswap.swap.exactInput");

    address public constant WETH = 0x4200000000000000000000000000000000000006;
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant ROUTER = 0x6131B5fae19EA4f9D964eAc0408E4408b66337b5;
    bytes4 public constant SWAP_SELECTOR = 0xe21fd0e9;
    uint256 public constant MAX_RESPONSE_BYTES = 512_000;
    uint256 public constant MAX_CALLDATA_BYTES = 64_000;

    string public apiBaseUrl;

    error UnknownAction(bytes32 actionId);
    error InvalidAccount();
    error InvalidParameters();
    error UnsupportedPair(address tokenIn, address tokenOut);
    error InvalidDeadline(uint256 deadline);
    error InvalidApiResponse(uint16 status);
    error InvalidRouter(address router);
    error InvalidQuote();
    error InvalidBuild();
    error InsufficientBalance(uint256 available, uint256 required);

    constructor(string memory apiBaseUrl_) {
        if (bytes(apiBaseUrl_).length == 0) revert InvalidParameters();
        apiBaseUrl = apiBaseUrl_;
    }

    function actions() external pure returns (bytes32[] memory actionIds) {
        actionIds = new bytes32[](1);
        actionIds[0] = SWAP_ACTION;
    }

    function actionDescriptor(bytes32 actionId) external pure returns (bytes memory descriptor) {
        if (actionId == SWAP_ACTION) {
            return bytes(
                '{"version":"0.1","kind":"action","name":"kyberswap.swap.exactInput","inputs":{"encoding":"abi","fields":[{"name":"parameters","abiType":"tuple","components":[{"name":"tokenIn","abiType":"address","semanticType":"erc20"},{"name":"tokenOut","abiType":"address","semanticType":"erc20"},{"name":"amountIn","abiType":"uint256","semanticType":"tokenAmount","assetField":"parameters.tokenIn","minimum":"1"},{"name":"minAmountOut","abiType":"uint256","semanticType":"tokenAmount","assetField":"parameters.tokenOut","minimum":"1"},{"name":"slippageBps","abiType":"uint16","semanticType":"basisPoints","minimum":"0","maximum":"100"},{"name":"deadline","abiType":"uint64","semanticType":"timestamp"}]}]},"output":{"encoding":"preparedAction"},"effects":[{"type":"decrease","assetField":"parameters.tokenIn","amountField":"parameters.amountIn"},{"type":"increase","assetField":"parameters.tokenOut","minimumField":"parameters.minAmountOut"}],"execution":{"atomicity":"atomic-required"},"provenance":{"type":"hybrid"}}'
            );
        }
        revert UnknownAction(actionId);
    }

    function prepare(bytes32 actionId, address account, bytes calldata parameters)
        external
        view
        returns (PreparedAction memory)
    {
        if (actionId != SWAP_ACTION) revert UnknownAction(actionId);
        if (account == address(0)) revert InvalidAccount();
        KyberSwapParameters memory swap = abi.decode(parameters, (KyberSwapParameters));
        _validateParameters(account, swap);

        _revertRequest(
            HttpRequest({
                url: string.concat(
                    apiBaseUrl,
                    "/base/api/v1/routes?tokenIn=",
                    Text.addressString(swap.tokenIn),
                    "&tokenOut=",
                    Text.addressString(swap.tokenOut),
                    "&amountIn=",
                    Text.uintString(swap.amountIn),
                    "&excludeRFQSources=true"
                ),
                method: "GET",
                headers: _headers(false),
                body: bytes(""),
                requirements: new RequestRequirement[](0)
            }),
            this.quoteCallback.selector,
            abi.encode(account, swap)
        );
    }

    function quoteCallback(HttpResponse calldata response, bytes calldata extraData)
        external
        view
        returns (PreparedAction memory)
    {
        (address account, KyberSwapParameters memory swap) = abi.decode(extraData, (address, KyberSwapParameters));
        _validateResponse(response);
        if (Json.uintValue(response.body, "code") != 0) revert InvalidQuote();

        bytes memory dataObject = Json.objectValue(response.body, "data");
        if (Json.addressValue(dataObject, "routerAddress") != ROUTER) {
            revert InvalidRouter(Json.addressValue(dataObject, "routerAddress"));
        }
        bytes memory routeSummary = Json.objectValue(dataObject, "routeSummary");
        if (
            Json.addressValue(routeSummary, "tokenIn") != swap.tokenIn
                || Json.addressValue(routeSummary, "tokenOut") != swap.tokenOut
                || Json.decimalStringValue(routeSummary, "amountIn") != swap.amountIn
                || Json.decimalStringValue(routeSummary, "amountOut") < swap.minAmountOut
        ) revert InvalidQuote();
        bytes memory extraFee = Json.objectValue(routeSummary, "extraFee");
        if (
            !Json.equals(Json.stringValue(extraFee, "feeAmount"), "")
                || !Json.equals(Json.stringValue(extraFee, "feeReceiver"), "")
        ) revert InvalidQuote();

        bytes memory body = abi.encodePacked(
            '{"routeSummary":',
            routeSummary,
            ',"sender":"',
            Text.addressString(account),
            '","recipient":"',
            Text.addressString(account),
            '","slippageTolerance":',
            Text.uintString(swap.slippageBps),
            ',"deadline":',
            Text.uintString(swap.deadline),
            ',"source":"onchain-app-interfaces"}'
        );
        _revertRequest(
            HttpRequest({
                url: string.concat(apiBaseUrl, "/base/api/v1/route/build"),
                method: "POST",
                headers: _headers(true),
                body: body,
                requirements: new RequestRequirement[](0)
            }),
            this.buildCallback.selector,
            extraData
        );
    }

    function buildCallback(HttpResponse calldata response, bytes calldata extraData)
        external
        view
        returns (PreparedAction memory preparedAction)
    {
        (address account, KyberSwapParameters memory swap) = abi.decode(extraData, (address, KyberSwapParameters));
        _validateResponse(response);
        if (Json.uintValue(response.body, "code") != 0) revert InvalidBuild();
        bytes memory dataObject = Json.objectValue(response.body, "data");
        address router = Json.addressValue(dataObject, "routerAddress");
        if (router != ROUTER) revert InvalidRouter(router);
        if (
            Json.decimalStringValue(dataObject, "transactionValue") != 0
                || Json.decimalStringValue(dataObject, "amountIn") != swap.amountIn
        ) revert InvalidBuild();

        bytes memory swapData = Json.bytesValue(dataObject, "data");
        if (swapData.length < 4 || swapData.length > MAX_CALLDATA_BYTES) revert InvalidBuild();
        KyberSwapExecutionParams memory execution =
            abi.decode(Json.slice(swapData, 4, swapData.length - 4), (KyberSwapExecutionParams));
        _validateExecution(swapData, execution, account, swap);

        bool approvalRequired = IKyberErc20(swap.tokenIn).allowance(account, ROUTER) < swap.amountIn;
        Call[] memory calls = new Call[](approvalRequired ? 2 : 1);
        uint256 swapIndex;
        if (approvalRequired) {
            calls[0] = Call({
                target: swap.tokenIn, value: 0, data: abi.encodeCall(IKyberErc20.approve, (ROUTER, swap.amountIn))
            });
            swapIndex = 1;
        }
        calls[swapIndex] = Call({target: ROUTER, value: 0, data: swapData});
        return PreparedAction({calls: calls, validUntil: swap.deadline});
    }

    function _validateParameters(address account, KyberSwapParameters memory swap) private view {
        if (!((swap.tokenIn == WETH && swap.tokenOut == USDC) || (swap.tokenIn == USDC && swap.tokenOut == WETH))) {
            revert UnsupportedPair(swap.tokenIn, swap.tokenOut);
        }
        if (swap.amountIn == 0 || swap.minAmountOut == 0 || swap.slippageBps > 100) {
            revert InvalidParameters();
        }
        // forge-lint: disable-next-line(block-timestamp)
        if (swap.deadline <= block.timestamp || swap.deadline > block.timestamp + 20 minutes) {
            revert InvalidDeadline(swap.deadline);
        }
        uint256 balance = IKyberErc20(swap.tokenIn).balanceOf(account);
        if (balance < swap.amountIn) revert InsufficientBalance(balance, swap.amountIn);
    }

    function _validateResponse(HttpResponse calldata response) private pure {
        if (
            response.status < 200 || response.status >= 300 || response.body.length == 0
                || response.body.length > MAX_RESPONSE_BYTES
        ) revert InvalidApiResponse(response.status);
    }

    function _validateExecution(
        bytes memory swapData,
        KyberSwapExecutionParams memory execution,
        address account,
        KyberSwapParameters memory swap
    ) private pure {
        bytes4 selector;
        assembly ("memory-safe") {
            selector := mload(add(swapData, 0x20))
        }
        KyberSwapDescription memory description = execution.desc;
        if (
            selector != SWAP_SELECTOR || execution.callTarget == address(0) || execution.targetData.length == 0
                || description.srcToken != swap.tokenIn || description.dstToken != swap.tokenOut
                || description.dstReceiver != account || description.amount != swap.amountIn
                || description.minReturnAmount < swap.minAmountOut || description.feeReceivers.length != 0
                || description.feeAmounts.length != 0 || description.permit.length != 0
                || description.srcReceivers.length != description.srcAmounts.length
        ) revert InvalidBuild();

        uint256 sourceAmount;
        for (uint256 i = 0; i < description.srcAmounts.length; i++) {
            sourceAmount += description.srcAmounts[i];
        }
        if (sourceAmount != swap.amountIn) revert InvalidBuild();
        if (keccak256(swapData) != keccak256(abi.encodeWithSelector(SWAP_SELECTOR, execution))) revert InvalidBuild();
    }

    function _headers(bool includeContentType) private pure returns (HttpHeader[] memory headers) {
        headers = new HttpHeader[](includeContentType ? 3 : 2);
        headers[0] = HttpHeader({name: "Accept", value: "application/json"});
        headers[1] = HttpHeader({name: "X-Client-Id", value: "onchain-app-interfaces"});
        if (includeContentType) {
            headers[2] = HttpHeader({name: "Content-Type", value: "application/json"});
        }
    }

    function _revertRequest(HttpRequest memory request, bytes4 callback, bytes memory extraData) private view {
        revert ExternalRequest({
            sender: address(this),
            request: request,
            responseTransform: _rawTransform(),
            callbackFunction: callback,
            extraData: extraData
        });
    }

    function _rawTransform() private pure returns (ResponseTransform memory transform) {
        JsonAbiNode[] memory nodes = new JsonAbiNode[](0);
        transform = ResponseTransform({kind: ResponseTransformKind.RAW, statusFrom: 0, statusTo: 0, nodes: nodes});
    }
}
