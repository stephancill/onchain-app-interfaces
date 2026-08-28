// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

import {Call, IApplicationActions, PreparedAction} from "../contracts/IApplicationActions.sol";
import {IApplicationQueries} from "../contracts/IApplicationQueries.sol";
import {
    ExternalRequest,
    HttpHeader,
    HttpRequest,
    HttpResponse,
    JsonAbiNode,
    RequestLocation,
    RequestRequirement,
    ResponseTransform,
    ResponseTransformKind
} from "../contracts/IExternalRequest.sol";

contract ApplicationAdapterFixture is IApplicationQueries, IApplicationActions {
    bytes32 public constant ONCHAIN_QUERY = keccak256("fixture.query.onchain");
    bytes32 public constant REQUIREMENTS_QUERY = keccak256("fixture.query.requirements");
    bytes32 public constant NESTED_QUERY = keccak256("fixture.query.nested");
    bytes32 public constant STATUS_QUERY = keccak256("fixture.query.status");
    bytes32 public constant REDIRECT_QUERY = keccak256("fixture.query.redirect");
    bytes32 public constant FORM_QUERY = keccak256("fixture.query.form");
    bytes32 public constant MISMATCH_QUERY = keccak256("fixture.query.mismatch");

    bytes32 public constant ONCHAIN_ACTION = keccak256("fixture.action.onchain");
    bytes32 public constant EXTERNAL_ACTION = keccak256("fixture.action.external");

    string public baseUrl;

    error UnknownQuery(bytes32 queryId);
    error UnknownAction(bytes32 actionId);

    constructor(string memory baseUrl_) {
        baseUrl = baseUrl_;
    }

    function queries() external pure returns (bytes32[] memory queryIds) {
        queryIds = new bytes32[](7);
        queryIds[0] = ONCHAIN_QUERY;
        queryIds[1] = REQUIREMENTS_QUERY;
        queryIds[2] = NESTED_QUERY;
        queryIds[3] = STATUS_QUERY;
        queryIds[4] = REDIRECT_QUERY;
        queryIds[5] = FORM_QUERY;
        queryIds[6] = MISMATCH_QUERY;
    }

    function queryDescriptor(bytes32 queryId) external pure returns (bytes memory descriptor) {
        if (queryId == ONCHAIN_QUERY) return bytes("fixture.query.onchain(uint256):(uint256)");
        if (queryId == REQUIREMENTS_QUERY) return bytes("fixture.query.requirements():(bytes)");
        if (queryId == NESTED_QUERY) return bytes("fixture.query.nested():(bytes)");
        if (queryId == STATUS_QUERY) return bytes("fixture.query.status():(uint16,bytes)");
        if (queryId == REDIRECT_QUERY) return bytes("fixture.query.redirect():(uint16,bytes)");
        if (queryId == FORM_QUERY) return bytes("fixture.query.form():(bytes)");
        if (queryId == MISMATCH_QUERY) return bytes("fixture.query.mismatch():(bytes)");
        revert UnknownQuery(queryId);
    }

    function query(bytes32 queryId, bytes calldata parameters) external view returns (bytes memory result) {
        if (queryId == ONCHAIN_QUERY) return abi.encode(abi.decode(parameters, (uint256)) * 2);
        if (queryId == REQUIREMENTS_QUERY) {
            _revertRequirementsRequest(this.queryBodyCallback.selector);
        }
        if (queryId == NESTED_QUERY) {
            _revertPublicRequest("/public", this.nestedQueryCallback.selector, bytes("nested"));
        }
        if (queryId == STATUS_QUERY) {
            _revertPublicRequest("/status", this.queryStatusCallback.selector, bytes("status"));
        }
        if (queryId == REDIRECT_QUERY) {
            _revertPublicRequest("/redirect", this.queryStatusCallback.selector, bytes("redirect"));
        }
        if (queryId == FORM_QUERY) {
            _revertFormRequest();
        }
        if (queryId == MISMATCH_QUERY) {
            _revertMismatchedRequest();
        }
        revert UnknownQuery(queryId);
    }

    function actions() external pure returns (bytes32[] memory actionIds) {
        actionIds = new bytes32[](2);
        actionIds[0] = ONCHAIN_ACTION;
        actionIds[1] = EXTERNAL_ACTION;
    }

    function actionDescriptor(bytes32 actionId) external pure returns (bytes memory descriptor) {
        if (actionId == ONCHAIN_ACTION) return bytes("fixture.action.onchain(bytes):(Call[])");
        if (actionId == EXTERNAL_ACTION) return bytes("fixture.action.external(bytes):(Call[])");
        revert UnknownAction(actionId);
    }

    function prepare(bytes32 actionId, address account, bytes calldata parameters)
        external
        view
        returns (PreparedAction memory preparedAction)
    {
        if (actionId == ONCHAIN_ACTION) return _prepared(account, parameters, 0);
        if (actionId == EXTERNAL_ACTION) {
            _revertPublicRequest("/action", this.actionCallback.selector, abi.encode(account, parameters));
        }
        revert UnknownAction(actionId);
    }

    function queryBodyCallback(HttpResponse calldata response, bytes calldata)
        external
        pure
        returns (bytes memory result)
    {
        return response.body;
    }

    function queryStatusCallback(HttpResponse calldata response, bytes calldata)
        external
        pure
        returns (bytes memory result)
    {
        return abi.encode(response.status, response.body);
    }

    function nestedQueryCallback(HttpResponse calldata, bytes calldata extraData) external view returns (bytes memory) {
        require(keccak256(extraData) == keccak256(bytes("nested")), "unexpected continuation");

        HttpHeader[] memory headers = new HttpHeader[](0);
        RequestRequirement[] memory requirements = new RequestRequirement[](1);
        requirements[0] = RequestRequirement({
            location: RequestLocation.HEADER,
            path: "Authorization",
            description: "Bearer credential for the nested fixture request",
            sensitive: true
        });

        revert ExternalRequest({
            sender: address(this),
            request: HttpRequest({
                url: string.concat(baseUrl, "/authenticated"),
                method: "GET",
                headers: headers,
                body: bytes(""),
                requirements: requirements
            }),
            responseTransform: _rawTransform(),
            callbackFunction: this.queryBodyCallback.selector,
            extraData: bytes("final")
        });
    }

    function actionCallback(HttpResponse calldata response, bytes calldata extraData)
        external
        view
        returns (PreparedAction memory preparedAction)
    {
        (address account,) = abi.decode(extraData, (address, bytes));
        return _prepared(account, response.body, block.timestamp + 60);
    }

    function _revertRequirementsRequest(bytes4 callbackFunction) private view {
        HttpHeader[] memory headers = new HttpHeader[](1);
        headers[0] = HttpHeader({name: "Content-Type", value: "application/json"});

        RequestRequirement[] memory requirements = new RequestRequirement[](3);
        requirements[0] = RequestRequirement({
            location: RequestLocation.HEADER,
            path: "Authorization",
            description: "Bearer credential for the fixture API",
            sensitive: true
        });
        requirements[1] = RequestRequirement({
            location: RequestLocation.QUERY,
            path: "account_id",
            description: "Fixture account identifier",
            sensitive: false
        });
        requirements[2] = RequestRequirement({
            location: RequestLocation.BODY,
            path: "/context/account",
            description: "Fixture body account identifier",
            sensitive: false
        });

        revert ExternalRequest({
            sender: address(this),
            request: HttpRequest({
                url: string.concat(baseUrl, "/requirements"),
                method: "POST",
                headers: headers,
                body: bytes('{"context":{}}'),
                requirements: requirements
            }),
            responseTransform: _rawTransform(),
            callbackFunction: callbackFunction,
            extraData: bytes("")
        });
    }

    function _revertPublicRequest(string memory path, bytes4 callbackFunction, bytes memory extraData) private view {
        HttpHeader[] memory headers = new HttpHeader[](0);
        RequestRequirement[] memory requirements = new RequestRequirement[](0);
        revert ExternalRequest({
            sender: address(this),
            request: HttpRequest({
                url: string.concat(baseUrl, path),
                method: "GET",
                headers: headers,
                body: bytes(""),
                requirements: requirements
            }),
            responseTransform: _rawTransform(),
            callbackFunction: callbackFunction,
            extraData: extraData
        });
    }

    function _revertFormRequest() private view {
        HttpHeader[] memory headers = new HttpHeader[](1);
        headers[0] = HttpHeader({name: "Content-Type", value: "application/x-www-form-urlencoded"});
        RequestRequirement[] memory requirements = new RequestRequirement[](1);
        requirements[0] = RequestRequirement({
            location: RequestLocation.BODY, path: "api_key", description: "Fixture form API key", sensitive: true
        });
        revert ExternalRequest({
            sender: address(this),
            request: HttpRequest({
                url: string.concat(baseUrl, "/form"),
                method: "POST",
                headers: headers,
                body: bytes("asset=ETH"),
                requirements: requirements
            }),
            responseTransform: _rawTransform(),
            callbackFunction: this.queryBodyCallback.selector,
            extraData: bytes("")
        });
    }

    function _revertMismatchedRequest() private view {
        HttpHeader[] memory headers = new HttpHeader[](0);
        RequestRequirement[] memory requirements = new RequestRequirement[](0);
        revert ExternalRequest({
            sender: address(0xdead),
            request: HttpRequest({
                url: string.concat(baseUrl, "/should-not-run"),
                method: "GET",
                headers: headers,
                body: bytes(""),
                requirements: requirements
            }),
            responseTransform: _rawTransform(),
            callbackFunction: this.queryBodyCallback.selector,
            extraData: bytes("")
        });
    }

    function _prepared(address target, bytes memory data, uint256 lifetime)
        private
        pure
        returns (PreparedAction memory preparedAction)
    {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: target, value: 0, data: data});
        preparedAction = PreparedAction({calls: calls, validUntil: lifetime});
    }

    function _rawTransform() private pure returns (ResponseTransform memory transform) {
        JsonAbiNode[] memory nodes = new JsonAbiNode[](0);
        transform = ResponseTransform({kind: ResponseTransformKind.RAW, statusFrom: 0, statusTo: 0, nodes: nodes});
    }
}
