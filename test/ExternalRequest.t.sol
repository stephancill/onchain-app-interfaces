// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

import {ExternalRequest, HttpHeader, HttpResponse, ResponseBodyEncoding} from "../contracts/IExternalRequest.sol";
import {ExternalRequestFixture} from "./ExternalRequestFixture.sol";

contract ExternalRequestTest {
    ExternalRequestFixture internal fixture = new ExternalRequestFixture();

    function testRequestUsesExternalRequestSelector() external view {
        (bool success, bytes memory data) =
            address(fixture).staticcall(abi.encodeCall(ExternalRequestFixture.requestWithRequirements, ()));
        require(!success, "request should revert");
        require(_selector(data) == ExternalRequest.selector, "wrong error selector");
    }

    function testNestedRequestUsesExternalRequestSelector() external view {
        (bool success, bytes memory data) =
            address(fixture).staticcall(abi.encodeCall(ExternalRequestFixture.nestedRequest, ()));
        require(!success, "request should revert");
        require(_selector(data) == ExternalRequest.selector, "wrong error selector");
    }

    function testCallbackReceivesStructuredResponse() external view {
        HttpHeader[] memory headers = new HttpHeader[](1);
        headers[0] = HttpHeader({name: "Content-Type", value: "application/json"});
        HttpResponse memory response = HttpResponse({
            status: 200,
            headers: headers,
            rawBodyHash: keccak256(bytes("ok")),
            bodyEncoding: ResponseBodyEncoding.RAW,
            body: bytes("ok")
        });

        bytes memory result = fixture.requestCallback(response, abi.encode(uint256(42)));
        (uint256 continuation, bytes memory body) = abi.decode(result, (uint256, bytes));
        require(continuation == 42, "wrong continuation");
        require(keccak256(body) == keccak256(bytes("ok")), "wrong body");
    }

    function _selector(bytes memory data) private pure returns (bytes4 selector) {
        require(data.length >= 4, "missing selector");
        assembly ("memory-safe") {
            selector := mload(add(data, 0x20))
        }
    }
}
