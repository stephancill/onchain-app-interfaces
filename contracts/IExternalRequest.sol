// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

/// @notice Experimental v0 interface. Subject to breaking changes.
enum RequestLocation {
    HEADER,
    QUERY,
    BODY
}

/// @notice An HTTP header field.
struct HttpHeader {
    string name;
    string value;
}

/// @notice A client-owned string value required to complete an HTTP request.
struct RequestRequirement {
    RequestLocation location;
    string path;
    string description;
    bool sensitive;
}

/// @notice One concrete HTTP request to be completed and executed by a client.
struct HttpRequest {
    string url;
    string method;
    HttpHeader[] headers;
    bytes body;
    RequestRequirement[] requirements;
}

/// @notice The HTTP response supplied to an external-request callback.
struct HttpResponse {
    uint16 status;
    HttpHeader[] headers;
    bytes body;
}

/// @notice Requests a client-mediated HTTP interaction and EVM callback.
/// @param sender Contract that initiated the request and receives the callback.
/// @param request HTTP request template and client-owned value requirements.
/// @param callbackFunction Selector accepting (HttpResponse, bytes).
/// @param extraData Opaque continuation data returned unchanged to the callback.
error ExternalRequest(address sender, HttpRequest request, bytes4 callbackFunction, bytes extraData);

interface IExternalRequestCallback {
    function externalRequestCallback(HttpResponse calldata response, bytes calldata extraData)
        external
        view
        returns (bytes memory result);
}
