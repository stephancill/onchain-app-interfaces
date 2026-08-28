// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

import {IApplicationQueries} from "../IApplicationQueries.sol";
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
} from "../IExternalRequest.sol";
import {Text} from "../lib/Text.sol";

enum BitrefillProductKind {
    GIFT_CARD,
    ESIM,
    TOPUP
}

struct BitrefillSearchParameters {
    BitrefillProductKind kind;
    string query;
    string country;
}

struct BitrefillCatalogResult {
    bytes32 queryId;
    bytes32 parametersHash;
    uint16 status;
    bytes body;
    bool sensitive;
    uint256 observedAt;
}

/// @notice Experimental authenticated, read-only Bitrefill catalog adapter.
contract BitrefillApplicationAdapter is IApplicationQueries {
    bytes32 public constant SEARCH_QUERY = keccak256("bitrefill.catalog.search");
    bytes32 public constant PRODUCT_DETAIL_QUERY = keccak256("bitrefill.product.detail");
    uint256 public constant MAX_RESPONSE_BYTES = 256_000;

    string public apiBaseUrl;

    error UnknownQuery(bytes32 queryId);
    error InvalidParameters();
    error InvalidApiResponse(uint16 status);

    constructor(string memory apiBaseUrl_) {
        if (bytes(apiBaseUrl_).length == 0) revert InvalidParameters();
        apiBaseUrl = apiBaseUrl_;
    }

    function queries() external pure returns (bytes32[] memory queryIds) {
        queryIds = new bytes32[](2);
        queryIds[0] = SEARCH_QUERY;
        queryIds[1] = PRODUCT_DETAIL_QUERY;
    }

    function queryDescriptor(bytes32 queryId) external pure returns (bytes memory descriptor) {
        if (queryId == SEARCH_QUERY) {
            return bytes(
                '{"version":"0.1","kind":"query","name":"bitrefill.catalog.search","inputs":{"encoding":"abi","fields":[{"name":"parameters","abiType":"tuple","components":[{"name":"kind","abiType":"uint8","semanticType":"productKind","enumValues":{"GIFT_CARD":0,"ESIM":1,"TOPUP":2}},{"name":"query","abiType":"string","semanticType":"searchText","minLength":1,"maxLength":100},{"name":"country","abiType":"string","semanticType":"countryCode","maxLength":2}]}]},"output":{"encoding":"abi","fields":[{"name":"result","abiType":"tuple","components":[{"name":"queryId","abiType":"bytes32","semanticType":"capabilityId"},{"name":"parametersHash","abiType":"bytes32"},{"name":"status","abiType":"uint16","semanticType":"httpStatus"},{"name":"body","abiType":"bytes","contentType":"application/json","sensitivity":"public"},{"name":"sensitive","abiType":"bool"},{"name":"observedAt","abiType":"uint256","semanticType":"timestamp"}]}]},"provenance":{"type":"configured-origin"}}'
            );
        }
        if (queryId == PRODUCT_DETAIL_QUERY) {
            return bytes(
                '{"version":"0.1","kind":"query","name":"bitrefill.product.detail","inputs":{"encoding":"abi","fields":[{"name":"slug","abiType":"string","semanticType":"productSlug","minLength":1,"maxLength":128,"pattern":"^[A-Za-z0-9_-]+$"}]},"output":{"encoding":"abi","fields":[{"name":"result","abiType":"tuple","components":[{"name":"queryId","abiType":"bytes32","semanticType":"capabilityId"},{"name":"parametersHash","abiType":"bytes32"},{"name":"status","abiType":"uint16","semanticType":"httpStatus"},{"name":"body","abiType":"bytes","contentType":"application/json","sensitivity":"public"},{"name":"sensitive","abiType":"bool"},{"name":"observedAt","abiType":"uint256","semanticType":"timestamp"}]}]},"provenance":{"type":"configured-origin"}}'
            );
        }
        revert UnknownQuery(queryId);
    }

    function query(bytes32 queryId, bytes calldata parameters) external view returns (bytes memory) {
        string memory path;
        if (queryId == SEARCH_QUERY) {
            BitrefillSearchParameters memory search = abi.decode(parameters, (BitrefillSearchParameters));
            _validateSearch(search);
            string memory encodedQuery = Text.percentEncode(search.query);
            if (search.kind == BitrefillProductKind.GIFT_CARD) {
                path = string.concat("/x402/gift-cards/search?q=", encodedQuery, "&country=", search.country);
            } else if (search.kind == BitrefillProductKind.ESIM) {
                path = string.concat("/x402/esims/search?q=", encodedQuery);
            } else {
                path = string.concat("/x402/topups/search?q=", encodedQuery);
            }
        } else if (queryId == PRODUCT_DETAIL_QUERY) {
            string memory slug = abi.decode(parameters, (string));
            _validateSlug(slug);
            path = string.concat("/x402/products/detail?slug=", Text.percentEncode(slug));
        } else {
            revert UnknownQuery(queryId);
        }

        HttpHeader[] memory headers = new HttpHeader[](1);
        headers[0] = HttpHeader({name: "Accept", value: "application/json"});
        RequestRequirement[] memory requirements = new RequestRequirement[](1);
        requirements[0] = RequestRequirement({
            location: RequestLocation.HEADER,
            path: "X-Access-Token",
            description: "Bitrefill access token authorized for https://api.bitrefill.com",
            sensitive: true
        });
        revert ExternalRequest({
            sender: address(this),
            request: HttpRequest({
                url: string.concat(apiBaseUrl, path),
                method: "GET",
                headers: headers,
                body: bytes(""),
                requirements: requirements
            }),
            responseTransform: _rawTransform(),
            callbackFunction: this.catalogCallback.selector,
            extraData: abi.encode(queryId, keccak256(parameters))
        });
    }

    function catalogCallback(HttpResponse calldata response, bytes calldata extraData)
        external
        view
        returns (bytes memory result)
    {
        (bytes32 queryId, bytes32 parametersHash) = abi.decode(extraData, (bytes32, bytes32));
        if (queryId != SEARCH_QUERY && queryId != PRODUCT_DETAIL_QUERY) revert UnknownQuery(queryId);
        if (
            response.status != 200 || response.body.length == 0 || response.body.length > MAX_RESPONSE_BYTES
                || !_hasJsonContentType(response.headers) || !_looksLikeJson(response.body)
        ) revert InvalidApiResponse(response.status);

        return abi.encode(
            BitrefillCatalogResult({
                queryId: queryId,
                parametersHash: parametersHash,
                status: response.status,
                body: response.body,
                sensitive: false,
                observedAt: block.timestamp
            })
        );
    }

    function _validateSearch(BitrefillSearchParameters memory search) private pure {
        uint256 queryLength = bytes(search.query).length;
        if (queryLength == 0 || queryLength > 100) revert InvalidParameters();
        bytes memory country = bytes(search.country);
        if (search.kind == BitrefillProductKind.GIFT_CARD) {
            if (
                country.length != 2 || uint8(country[0]) < 65 || uint8(country[0]) > 90 || uint8(country[1]) < 65
                    || uint8(country[1]) > 90
            ) revert InvalidParameters();
        } else if (country.length != 0) {
            revert InvalidParameters();
        }
    }

    function _validateSlug(string memory slug) private pure {
        bytes memory value = bytes(slug);
        if (value.length == 0 || value.length > 128) revert InvalidParameters();
        for (uint256 i = 0; i < value.length; i++) {
            uint8 character = uint8(value[i]);
            if (!((character >= 65 && character <= 90) || (character >= 97 && character <= 122)
                        || (character >= 48 && character <= 57) || character == 45 || character == 95)) revert InvalidParameters();
        }
    }

    function _hasJsonContentType(HttpHeader[] calldata headers) private pure returns (bool) {
        bytes32 contentTypeName = keccak256(bytes("content-type"));
        for (uint256 i = 0; i < headers.length; i++) {
            if (_lowerHash(headers[i].name) != contentTypeName) continue;
            bytes memory value = bytes(headers[i].value);
            bytes memory expected = bytes("application/json");
            if (value.length < expected.length) return false;
            for (uint256 j = 0; j < expected.length; j++) {
                uint8 character = uint8(value[j]);
                if (character >= 65 && character <= 90) character += 32;
                if (character != uint8(expected[j])) return false;
            }
            return true;
        }
        return false;
    }

    function _looksLikeJson(bytes calldata body) private pure returns (bool) {
        for (uint256 i = 0; i < body.length; i++) {
            bytes1 character = body[i];
            if (character == 0x20 || character == 0x09 || character == 0x0a || character == 0x0d) {
                continue;
            }
            return character == 0x7b || character == 0x5b;
        }
        return false;
    }

    function _lowerHash(string calldata value) private pure returns (bytes32) {
        bytes memory normalized = bytes(value);
        for (uint256 i = 0; i < normalized.length; i++) {
            uint8 character = uint8(normalized[i]);
            if (character >= 65 && character <= 90) normalized[i] = bytes1(character + 32);
        }
        return keccak256(normalized);
    }

    function _rawTransform() private pure returns (ResponseTransform memory transform) {
        JsonAbiNode[] memory nodes = new JsonAbiNode[](0);
        transform = ResponseTransform({kind: ResponseTransformKind.RAW, statusFrom: 0, statusTo: 0, nodes: nodes});
    }
}
