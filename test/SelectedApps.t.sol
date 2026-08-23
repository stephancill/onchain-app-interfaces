// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

import {HttpHeader, HttpResponse} from "../contracts/IExternalRequest.sol";
import {
    BitrefillApplicationAdapter,
    BitrefillCatalogResult,
    BitrefillProductKind,
    BitrefillSearchParameters
} from "../contracts/adapters/BitrefillApplicationAdapter.sol";
import {KyberSwapApplicationAdapter, KyberSwapParameters} from "../contracts/adapters/KyberSwapApplicationAdapter.sol";
import {OpenSeaApplicationAdapter} from "../contracts/adapters/OpenSeaApplicationAdapter.sol";
import {Json} from "../contracts/lib/Json.sol";
import {SelectedAppMockSeaDrop} from "./SelectedAppMocks.sol";

contract JsonHarness {
    function stringValue(bytes memory value, string memory key) external pure returns (bytes memory) {
        return Json.stringValue(value, key);
    }

    function objectValue(bytes memory value, string memory key) external pure returns (bytes memory) {
        return Json.objectValue(value, key);
    }

    function uintValue(bytes memory value, string memory key) external pure returns (uint256) {
        return Json.uintValue(value, key);
    }
}

contract SelectedAppsTest {
    JsonHarness internal json = new JsonHarness();
    SelectedAppMockSeaDrop internal seaDrop = new SelectedAppMockSeaDrop();
    KyberSwapApplicationAdapter internal kyber =
        new KyberSwapApplicationAdapter("https://aggregator-api.kyberswap.com");
    OpenSeaApplicationAdapter internal openSea =
        new OpenSeaApplicationAdapter("https://api.opensea.io", address(seaDrop));
    BitrefillApplicationAdapter internal bitrefill = new BitrefillApplicationAdapter("https://api.bitrefill.com");

    function testJsonReadsOnlyTopLevelFields() external view {
        bytes memory value = bytes('{"code":0,"wrapper":{"data":"inner"},"data":"outer","route":{"text":"{}"}}');
        require(keccak256(json.stringValue(value, "data")) == keccak256(bytes("outer")), "wrong data");
        require(json.uintValue(value, "code") == 0, "wrong code");
        require(keccak256(json.objectValue(value, "route")) == keccak256(bytes('{"text":"{}"}')), "wrong object");
    }

    function testJsonRejectsDuplicateTopLevelFields() external view {
        (bool success,) =
            address(json).staticcall(abi.encodeCall(json.stringValue, (bytes('{"data":"one","data":"two"}'), "data")));
        require(!success, "duplicate field should fail");
    }

    function testKyberRejectsUnsupportedPairBeforeRequest() external view {
        KyberSwapParameters memory parameters = KyberSwapParameters({
            tokenIn: kyber.WETH(),
            tokenOut: address(0xdead),
            amountIn: 1 ether,
            minAmountOut: 1,
            slippageBps: 50,
            deadline: uint64(block.timestamp + 300)
        });
        (bool success,) = address(kyber)
            .staticcall(abi.encodeCall(kyber.prepare, (kyber.SWAP_ACTION(), address(1), abi.encode(parameters))));
        require(!success, "unsupported pair should fail");
    }

    function testOpenSeaRejectsUnsafeSlug() external view {
        (bool success,) = address(openSea)
            .staticcall(
                abi.encodeCall(openSea.query, (openSea.COLLECTION_STATS_QUERY(), abi.encode("collection/../../secret")))
            );
        require(!success, "unsafe slug should fail");
    }

    function testBitrefillRejectsInvalidCountry() external view {
        BitrefillSearchParameters memory parameters =
            BitrefillSearchParameters({kind: BitrefillProductKind.GIFT_CARD, query: "test", country: "usa"});
        (bool success,) = address(bitrefill)
            .staticcall(abi.encodeCall(bitrefill.query, (bitrefill.SEARCH_QUERY(), abi.encode(parameters))));
        require(!success, "invalid country should fail");
    }

    function testBitrefillCallbackValidatesJsonMediaType() external view {
        HttpHeader[] memory headers = new HttpHeader[](1);
        headers[0] = HttpHeader({name: "CONTENT-TYPE", value: "Application/JSON; charset=utf-8"});
        HttpResponse memory response = HttpResponse({status: 200, headers: headers, body: bytes('{"products":[]}')});
        bytes32 parametersHash = keccak256("parameters");
        BitrefillCatalogResult memory result = abi.decode(
            bitrefill.catalogCallback(response, abi.encode(bitrefill.SEARCH_QUERY(), parametersHash)),
            (BitrefillCatalogResult)
        );
        require(result.parametersHash == parametersHash, "wrong parameter binding");
        require(result.status == 200, "wrong status");
        require(!result.sensitive, "catalog should not be sensitive");
    }
}
