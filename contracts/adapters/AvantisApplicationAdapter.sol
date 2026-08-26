// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

import {Call, IApplicationActions, PreparedAction} from "../IApplicationActions.sol";
import {IApplicationQueries} from "../IApplicationQueries.sol";
import {ExternalRequest, HttpHeader, HttpRequest, HttpResponse, RequestRequirement} from "../IExternalRequest.sol";
import {Text} from "../lib/Text.sol";
import {AvantisActionCodec} from "./AvantisActionCodec.sol";
import {AvantisDescriptor} from "./AvantisDescriptor.sol";
import {AvantisRequestCodec} from "./AvantisRequestCodec.sol";
import {
    AvantisMarginAction,
    AvantisMarginUpdateParameters,
    AvantisOpenTradeParameters,
    IAvantisErc20
} from "./AvantisTypes.sol";

/// @notice Experimental Avantis v2 positions and direct-trader action adapter for Base.
contract AvantisApplicationAdapter is IApplicationQueries, IApplicationActions {
    bytes32 public constant POSITIONS_QUERY = keccak256("avantis.positions");
    bytes32 public constant OPEN_TRADE_ACTION = keccak256("avantis.trade.open");
    bytes32 public constant CLOSE_TRADE_ACTION = keccak256("avantis.trade.close");
    bytes32 public constant CANCEL_LIMIT_ACTION = keccak256("avantis.limit.cancel");
    bytes32 public constant UPDATE_MARGIN_ACTION = keccak256("avantis.margin.update");
    bytes32 public constant UPDATE_LIMIT_ACTION = keccak256("avantis.limit.update");
    bytes32 public constant SET_DELEGATE_ACTION = keccak256("avantis.delegate.set");
    bytes32 public constant REMOVE_DELEGATE_ACTION = keccak256("avantis.delegate.remove");

    bytes32 public constant ACTION_CODEC_CODEHASH = 0x77bd96e574c36e223c75a1b81bb0869abaf4ba587fc9855183051ffff4d4eb85;
    bytes32 public constant REQUEST_CODEC_CODEHASH = 0x63e4a9621265df9ad29c14eb7d25feb9c147feea4f4901fb25091594dc4433ca;

    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant TRADING = 0x44914408af82bC9983bbb330e3578E1105e11d4e;
    address public constant TRADING_STORAGE = 0x8a311D7048c35985aa31C131B9A13e03a5f7422d;
    uint256 private constant MAX_RESPONSE_BYTES = 128_000;
    uint256 public constant PREPARATION_VALIDITY = 1 minutes;

    string public coreApiBaseUrl;
    string public txBuilderBaseUrl;
    AvantisDescriptor private immutable _descriptor;
    AvantisActionCodec public immutable actionCodec;
    AvantisRequestCodec public immutable requestCodec;

    error UnknownQuery(bytes32 queryId);
    error UnknownAction(bytes32 actionId);
    error InvalidParameters();
    error InvalidApiResponse(uint16 status);
    error InvalidCodec(address codec);
    error InsufficientUsdcBalance(uint256 available, uint256 required);

    constructor(
        string memory coreApiBaseUrl_,
        string memory txBuilderBaseUrl_,
        AvantisActionCodec actionCodec_,
        AvantisRequestCodec requestCodec_
    ) {
        if (bytes(coreApiBaseUrl_).length == 0 || bytes(txBuilderBaseUrl_).length == 0) revert InvalidParameters();
        if (address(actionCodec_).codehash != ACTION_CODEC_CODEHASH) revert InvalidCodec(address(actionCodec_));
        if (address(requestCodec_).codehash != REQUEST_CODEC_CODEHASH) revert InvalidCodec(address(requestCodec_));
        coreApiBaseUrl = coreApiBaseUrl_;
        txBuilderBaseUrl = txBuilderBaseUrl_;
        _descriptor = new AvantisDescriptor();
        actionCodec = actionCodec_;
        requestCodec = requestCodec_;
    }

    function queries() external pure returns (bytes32[] memory queryIds) {
        queryIds = new bytes32[](1);
        queryIds[0] = POSITIONS_QUERY;
    }

    function queryDescriptor(bytes32 queryId) external view returns (bytes memory) {
        if (queryId != POSITIONS_QUERY) revert UnknownQuery(queryId);
        return _descriptor.queryDescriptor(queryId);
    }

    function query(bytes32 queryId, bytes calldata parameters) external view returns (bytes memory) {
        if (queryId != POSITIONS_QUERY) revert UnknownQuery(queryId);
        address account = abi.decode(parameters, (address));
        if (account == address(0)) revert InvalidParameters();
        _revertRequest(
            string.concat(coreApiBaseUrl, "/user-data?trader=", Text.addressString(account)),
            this.positionsCallback.selector,
            ""
        );
    }

    /// @notice Validates transport-level response properties and returns the raw JSON body.
    /// @dev Semantic extraction happens client-side per the descriptor's json output fields.
    function positionsCallback(HttpResponse calldata response, bytes calldata) external view returns (bytes memory) {
        _validateResponse(response);
        return response.body;
    }

    function actions() external pure returns (bytes32[] memory actionIds) {
        actionIds = new bytes32[](7);
        actionIds[0] = OPEN_TRADE_ACTION;
        actionIds[1] = CLOSE_TRADE_ACTION;
        actionIds[2] = CANCEL_LIMIT_ACTION;
        actionIds[3] = UPDATE_MARGIN_ACTION;
        actionIds[4] = UPDATE_LIMIT_ACTION;
        actionIds[5] = SET_DELEGATE_ACTION;
        actionIds[6] = REMOVE_DELEGATE_ACTION;
    }

    function actionDescriptor(bytes32 actionId) external view returns (bytes memory) {
        if (!_knownAction(actionId)) revert UnknownAction(actionId);
        return _descriptor.actionDescriptor(actionId);
    }

    function prepare(bytes32 actionId, address account, bytes calldata parameters)
        external
        view
        returns (PreparedAction memory)
    {
        if (!_knownAction(actionId)) revert UnknownAction(actionId);
        if (account == address(0)) revert InvalidParameters();
        string memory url = requestCodec.url(txBuilderBaseUrl, actionId, account, parameters);
        _requireActionBalance(actionId, account, parameters);
        _revertRequest(
            url,
            actionId == OPEN_TRADE_ACTION ? this.openTradeCallback.selector : this.actionCallback.selector,
            abi.encode(actionId, account, parameters)
        );
    }

    function openTradeCallback(HttpResponse calldata response, bytes calldata extraData)
        external
        view
        returns (PreparedAction memory)
    {
        (bytes32 actionId, address account, bytes memory parameters) = abi.decode(extraData, (bytes32, address, bytes));
        if (actionId != OPEN_TRADE_ACTION) revert UnknownAction(actionId);
        AvantisOpenTradeParameters memory requested = abi.decode(parameters, (AvantisOpenTradeParameters));
        requestCodec.url(txBuilderBaseUrl, actionId, account, parameters);
        _validateResponse(response);
        bytes memory callData = actionCodec.open(response.body, account, requested);
        return _withApproval(account, requested.collateralUsdc, requested.executionFeeWei, callData);
    }

    function actionCallback(HttpResponse calldata response, bytes calldata extraData)
        external
        view
        returns (PreparedAction memory)
    {
        (bytes32 actionId, address account, bytes memory parameters) = abi.decode(extraData, (bytes32, address, bytes));
        if (!_knownAction(actionId) || actionId == OPEN_TRADE_ACTION || account == address(0)) {
            revert UnknownAction(actionId);
        }
        requestCodec.url(txBuilderBaseUrl, actionId, account, parameters);
        _validateResponse(response);
        (bytes memory data, uint256 value, uint256 approvalAmount) =
            actionCodec.action(response.body, uint8(uint256(actionId)), account, parameters);
        if (approvalAmount != 0) return _withApproval(account, approvalAmount, value, data);
        return _singleCall(value, data);
    }

    function _requireActionBalance(bytes32 actionId, address account, bytes memory encoded) private view {
        if (actionId == OPEN_TRADE_ACTION) {
            AvantisOpenTradeParameters memory p = abi.decode(encoded, (AvantisOpenTradeParameters));
            _requireBalance(account, p.collateralUsdc);
            return;
        }
        if (actionId == UPDATE_MARGIN_ACTION) {
            AvantisMarginUpdateParameters memory p = abi.decode(encoded, (AvantisMarginUpdateParameters));
            if (p.action == AvantisMarginAction.DEPOSIT) _requireBalance(account, p.collateralUsdc);
        }
    }

    function _withApproval(address account, uint256 amount, uint256 value, bytes memory data)
        private
        view
        returns (PreparedAction memory)
    {
        bool approvalRequired = IAvantisErc20(USDC).allowance(account, TRADING_STORAGE) < amount;
        Call[] memory calls = new Call[](approvalRequired ? 2 : 1);
        uint256 actionIndex;
        if (approvalRequired) {
            calls[0] =
                Call({target: USDC, value: 0, data: abi.encodeCall(IAvantisErc20.approve, (TRADING_STORAGE, amount))});
            actionIndex = 1;
        }
        calls[actionIndex] = Call({target: TRADING, value: value, data: data});
        return PreparedAction({calls: calls, validUntil: block.timestamp + PREPARATION_VALIDITY});
    }

    function _singleCall(uint256 value, bytes memory data) private view returns (PreparedAction memory) {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: TRADING, value: value, data: data});
        return PreparedAction({calls: calls, validUntil: block.timestamp + PREPARATION_VALIDITY});
    }

    function _requireBalance(address account, uint256 amount) private view {
        uint256 balance = IAvantisErc20(USDC).balanceOf(account);
        if (balance < amount) revert InsufficientUsdcBalance(balance, amount);
    }

    function _knownAction(bytes32 actionId) private pure returns (bool) {
        return actionId == OPEN_TRADE_ACTION || actionId == CLOSE_TRADE_ACTION || actionId == CANCEL_LIMIT_ACTION
            || actionId == UPDATE_MARGIN_ACTION || actionId == UPDATE_LIMIT_ACTION || actionId == SET_DELEGATE_ACTION
            || actionId == REMOVE_DELEGATE_ACTION;
    }

    function _validateResponse(HttpResponse calldata response) private pure {
        if (response.status != 200 || response.body.length == 0 || response.body.length > MAX_RESPONSE_BYTES) {
            revert InvalidApiResponse(response.status);
        }
    }

    function _revertRequest(string memory url, bytes4 callback, bytes memory extraData) private view {
        HttpHeader[] memory headers = new HttpHeader[](1);
        headers[0] = HttpHeader({name: "Accept", value: "application/json"});
        revert ExternalRequest({
            sender: address(this),
            request: HttpRequest({
                url: url, method: "GET", headers: headers, body: bytes(""), requirements: new RequestRequirement[](0)
            }),
            callbackFunction: callback,
            extraData: extraData
        });
    }
}
