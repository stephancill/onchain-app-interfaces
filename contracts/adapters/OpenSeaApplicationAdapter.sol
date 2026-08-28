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
    RequestLocation,
    RequestRequirement,
    ResponseTransform,
    ResponseTransformKind
} from "../IExternalRequest.sol";
import {Json} from "../lib/Json.sol";
import {Text} from "../lib/Text.sol";

struct OpenSeaStatsResult {
    string slug;
    uint16 status;
    bytes body;
    uint256 observedAt;
}

struct OpenSeaMintParameters {
    string slug;
    address nftContract;
    uint32 quantity;
    uint256 maxTotalValue;
}

struct SeaDropPublicDrop {
    uint80 mintPrice;
    uint48 startTime;
    uint48 endTime;
    uint16 maxTotalMintableByWallet;
    uint16 feeBps;
    bool restrictFeeRecipients;
}

interface ISeaDrop {
    function getPublicDrop(address nftContract) external view returns (SeaDropPublicDrop memory);
}

/// @notice Experimental authenticated OpenSea collection and public-mint adapter for Base.
contract OpenSeaApplicationAdapter is IApplicationQueries, IApplicationActions {
    bytes32 public constant COLLECTION_STATS_QUERY = keccak256("opensea.collection.stats");
    bytes32 public constant PUBLIC_MINT_ACTION = keccak256("opensea.drop.mint.public");
    bytes4 public constant MINT_PUBLIC_SELECTOR = 0x161ac21f;
    uint256 public constant MAX_RESPONSE_BYTES = 256_000;

    string public apiBaseUrl;
    address public seaDrop;

    error UnknownQuery(bytes32 queryId);
    error UnknownAction(bytes32 actionId);
    error InvalidParameters();
    error InvalidApiResponse(uint16 status);
    error InvalidMint();

    constructor(string memory apiBaseUrl_, address seaDrop_) {
        if (bytes(apiBaseUrl_).length == 0 || seaDrop_ == address(0)) revert InvalidParameters();
        apiBaseUrl = apiBaseUrl_;
        seaDrop = seaDrop_;
    }

    function queries() external pure returns (bytes32[] memory queryIds) {
        queryIds = new bytes32[](1);
        queryIds[0] = COLLECTION_STATS_QUERY;
    }

    function queryDescriptor(bytes32 queryId) external pure returns (bytes memory descriptor) {
        if (queryId == COLLECTION_STATS_QUERY) {
            return bytes(
                '{"version":"0.1","kind":"query","name":"opensea.collection.stats","inputs":{"encoding":"abi","fields":[{"name":"slug","abiType":"string","semanticType":"collectionSlug","minLength":1,"maxLength":255,"pattern":"^[a-z0-9-]+$"}]},"output":{"encoding":"abi","fields":[{"name":"result","abiType":"tuple","components":[{"name":"slug","abiType":"string","semanticType":"collectionSlug"},{"name":"status","abiType":"uint16","semanticType":"httpStatus"},{"name":"body","abiType":"bytes","contentType":"application/json","sensitivity":"public"},{"name":"observedAt","abiType":"uint256","semanticType":"timestamp"}]}]},"provenance":{"type":"configured-origin"}}'
            );
        }
        revert UnknownQuery(queryId);
    }

    function query(bytes32 queryId, bytes calldata parameters) external view returns (bytes memory) {
        if (queryId != COLLECTION_STATS_QUERY) revert UnknownQuery(queryId);
        string memory slug = abi.decode(parameters, (string));
        _validateSlug(slug);
        _revertRequest(
            HttpRequest({
                url: string.concat(apiBaseUrl, "/api/v2/collections/", slug, "/stats"),
                method: "GET",
                headers: _headers(false),
                body: bytes(""),
                requirements: _apiKeyRequirement()
            }),
            this.statsCallback.selector,
            abi.encode(slug)
        );
    }

    function statsCallback(HttpResponse calldata response, bytes calldata extraData)
        external
        view
        returns (bytes memory result)
    {
        _validateResponse(response);
        string memory slug = abi.decode(extraData, (string));
        _validateSlug(slug);
        return abi.encode(
            OpenSeaStatsResult({slug: slug, status: response.status, body: response.body, observedAt: block.timestamp})
        );
    }

    function actions() external pure returns (bytes32[] memory actionIds) {
        actionIds = new bytes32[](1);
        actionIds[0] = PUBLIC_MINT_ACTION;
    }

    function actionDescriptor(bytes32 actionId) external pure returns (bytes memory descriptor) {
        if (actionId == PUBLIC_MINT_ACTION) {
            return bytes(
                '{"version":"0.1","kind":"action","name":"opensea.drop.mint.public","inputs":{"encoding":"abi","fields":[{"name":"parameters","abiType":"tuple","components":[{"name":"slug","abiType":"string","semanticType":"dropSlug","minLength":1,"maxLength":255,"pattern":"^[a-z0-9-]+$"},{"name":"nftContract","abiType":"address","semanticType":"erc721"},{"name":"quantity","abiType":"uint32","semanticType":"quantity","minimum":"1","maximum":"100"},{"name":"maxTotalValue","abiType":"uint256","semanticType":"nativeTokenAmount","minimum":"1"}]}]},"output":{"encoding":"preparedAction"},"effects":[{"type":"decrease","description":"Native token payment up to maxTotalValue"},{"type":"increase","assetField":"parameters.nftContract","amountField":"parameters.quantity"}],"execution":{"atomicity":"sequential-allowed"},"provenance":{"type":"hybrid"}}'
            );
        }
        revert UnknownAction(actionId);
    }

    function prepare(bytes32 actionId, address account, bytes calldata parameters)
        external
        view
        returns (PreparedAction memory)
    {
        if (actionId != PUBLIC_MINT_ACTION) revert UnknownAction(actionId);
        if (account == address(0)) revert InvalidParameters();
        OpenSeaMintParameters memory mint = abi.decode(parameters, (OpenSeaMintParameters));
        _validateSlug(mint.slug);
        if (
            mint.nftContract == address(0) || mint.nftContract.code.length == 0 || mint.quantity == 0
                || mint.quantity > 100 || mint.maxTotalValue == 0
        ) revert InvalidParameters();

        _revertRequest(
            HttpRequest({
                url: string.concat(apiBaseUrl, "/api/v2/drops/", mint.slug, "/mint"),
                method: "POST",
                headers: _headers(true),
                body: abi.encodePacked(
                    '{"minter":"', Text.addressString(account), '","quantity":', Text.uintString(mint.quantity), "}"
                ),
                requirements: _apiKeyRequirement()
            }),
            this.mintCallback.selector,
            abi.encode(account, mint)
        );
    }

    function mintCallback(HttpResponse calldata response, bytes calldata extraData)
        external
        view
        returns (PreparedAction memory preparedAction)
    {
        _validateResponse(response);
        (address account, OpenSeaMintParameters memory mint) = abi.decode(extraData, (address, OpenSeaMintParameters));
        if (!Json.equals(Json.stringValue(response.body, "chain"), "base")) revert InvalidMint();
        if (Json.addressValue(response.body, "to") != seaDrop) revert InvalidMint();
        bytes memory callData = Json.bytesValue(response.body, "data");
        uint256 value = Json.hexStringValue(response.body, "value");
        if (callData.length != 132) revert InvalidMint();

        bytes4 selector;
        assembly ("memory-safe") {
            selector := mload(add(callData, 0x20))
        }
        (address nftContract, address feeRecipient, address minter, uint256 quantity) =
            abi.decode(Json.slice(callData, 4, 128), (address, address, address, uint256));
        if (
            selector != MINT_PUBLIC_SELECTOR || nftContract != mint.nftContract || feeRecipient == address(0)
                || minter != account || quantity != mint.quantity
                || keccak256(callData)
                    != keccak256(
                        abi.encodeWithSelector(MINT_PUBLIC_SELECTOR, nftContract, feeRecipient, minter, quantity)
                    )
        ) revert InvalidMint();

        SeaDropPublicDrop memory publicDrop = ISeaDrop(seaDrop).getPublicDrop(nftContract);
        uint256 currentTimestamp = block.timestamp;
        if (
            currentTimestamp < publicDrop.startTime || currentTimestamp >= publicDrop.endTime
                || quantity > publicDrop.maxTotalMintableByWallet || value != uint256(publicDrop.mintPrice) * quantity
                || value > mint.maxTotalValue
        ) revert InvalidMint();

        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: seaDrop, value: value, data: callData});
        return PreparedAction({calls: calls, validUntil: publicDrop.endTime});
    }

    function _validateSlug(string memory slug) private pure {
        bytes memory value = bytes(slug);
        if (value.length == 0 || value.length > 255) revert InvalidParameters();
        for (uint256 i = 0; i < value.length; i++) {
            uint8 character = uint8(value[i]);
            if (!((character >= 97 && character <= 122) || (character >= 48 && character <= 57) || character == 45)) {
                revert InvalidParameters();
            }
        }
    }

    function _validateResponse(HttpResponse calldata response) private pure {
        if (response.status != 200 || response.body.length == 0 || response.body.length > MAX_RESPONSE_BYTES) {
            revert InvalidApiResponse(response.status);
        }
    }

    function _headers(bool includeContentType) private pure returns (HttpHeader[] memory headers) {
        headers = new HttpHeader[](includeContentType ? 2 : 1);
        headers[0] = HttpHeader({name: "Accept", value: "application/json"});
        if (includeContentType) {
            headers[1] = HttpHeader({name: "Content-Type", value: "application/json"});
        }
    }

    function _apiKeyRequirement() private pure returns (RequestRequirement[] memory requirements) {
        requirements = new RequestRequirement[](1);
        requirements[0] = RequestRequirement({
            location: RequestLocation.HEADER,
            path: "x-api-key",
            description: "OpenSea API key authorized for https://api.opensea.io",
            sensitive: true
        });
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
