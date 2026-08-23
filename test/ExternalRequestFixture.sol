// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

import {
    ExternalRequest,
    HttpHeader,
    HttpRequest,
    HttpResponse,
    RequestLocation,
    RequestRequirement
} from "../contracts/IExternalRequest.sol";

contract ExternalRequestFixture {
    function requestWithRequirements() external view returns (bytes memory) {
        HttpHeader[] memory headers = new HttpHeader[](1);
        headers[0] = HttpHeader({name: "Content-Type", value: "application/json"});

        RequestRequirement[] memory requirements = new RequestRequirement[](2);
        requirements[0] = RequestRequirement({
            location: RequestLocation.HEADER,
            path: "Authorization",
            description: "Bearer credential for the fixture API",
            sensitive: true
        });
        requirements[1] = RequestRequirement({
            location: RequestLocation.BODY,
            path: "/accountId",
            description: "Fixture account identifier",
            sensitive: false
        });

        revert ExternalRequest({
            sender: address(this),
            request: HttpRequest({
                url: "https://api.example.com/quote",
                method: "POST",
                headers: headers,
                body: bytes('{"asset":"ETH"}'),
                requirements: requirements
            }),
            callbackFunction: this.requestCallback.selector,
            extraData: abi.encode(uint256(42))
        });
    }

    function requestCallback(HttpResponse calldata response, bytes calldata extraData)
        external
        pure
        returns (bytes memory)
    {
        require(response.status == 200, "unexpected status");
        return abi.encode(abi.decode(extraData, (uint256)), response.body);
    }

    function nestedRequest() external view returns (bytes memory) {
        _revertWithPublicRequest(this.nestedCallback.selector, bytes("second"));
    }

    function nestedCallback(HttpResponse calldata, bytes calldata extraData) external view returns (bytes memory) {
        require(keccak256(extraData) == keccak256(bytes("second")), "unexpected continuation");
        _revertWithPublicRequest(this.finalCallback.selector, bytes("final"));
    }

    function finalCallback(HttpResponse calldata response, bytes calldata extraData)
        external
        pure
        returns (bytes memory)
    {
        require(keccak256(extraData) == keccak256(bytes("final")), "unexpected continuation");
        return response.body;
    }

    function _revertWithPublicRequest(bytes4 callbackFunction, bytes memory extraData) private view {
        HttpHeader[] memory headers = new HttpHeader[](0);
        RequestRequirement[] memory requirements = new RequestRequirement[](0);
        revert ExternalRequest({
            sender: address(this),
            request: HttpRequest({
                url: "https://api.example.com/public",
                method: "GET",
                headers: headers,
                body: bytes(""),
                requirements: requirements
            }),
            callbackFunction: callbackFunction,
            extraData: extraData
        });
    }
}
