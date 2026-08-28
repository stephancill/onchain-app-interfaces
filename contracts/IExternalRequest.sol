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

/// @notice How the raw HTTP response body was encoded for the callback.
enum ResponseBodyEncoding {
    RAW,
    JSON_ABI
}

/// @notice The HTTP response supplied to an external-request callback.
/// @dev rawBodyHash commits to the exact raw HTTP body so a callback can verify
/// that a projected JSON_ABI body corresponds to the bytes actually received.
struct HttpResponse {
    uint16 status;
    HttpHeader[] headers;
    bytes32 rawBodyHash;
    ResponseBodyEncoding bodyEncoding;
    bytes body;
}

/// @notice How a client should transform a response body before a callback.
enum ResponseTransformKind {
    RAW,
    JSON_ABI
}

/// @notice ABI type a JSON value should be coerced to during JSON_ABI projection.
enum JsonAbiNodeType {
    TUPLE,
    ARRAY,
    BOOL,
    UINT256_DECIMAL,
    UINT256_HEX,
    INT256_DECIMAL,
    ADDRESS,
    BYTES,
    BYTES32,
    STRING
}

/// @notice One node of a flattened preorder response projection tree.
/// @param pointer RFC 6901 JSON Pointer relative to the parent node's JSON value.
/// The empty pointer selects the parent value itself.
/// @param childCount Number of direct children. TUPLE may have many children,
/// ARRAY must have exactly one element schema, and scalar nodes must have zero.
/// @param maxItems Maximum array length. Required for ARRAY and zero otherwise.
struct JsonAbiNode {
    JsonAbiNodeType nodeType;
    string pointer;
    uint16 childCount;
    uint32 maxItems;
}

/// @notice Declares how the HTTP response body should be delivered to a callback.
/// @param statusFrom Lowest accepted status for JSON_ABI projection. Other status
/// values are delivered raw.
/// @param statusTo Highest accepted status for JSON_ABI projection.
/// @param nodes Complete preorder projection tree. Must be empty for RAW.
struct ResponseTransform {
    ResponseTransformKind kind;
    uint16 statusFrom;
    uint16 statusTo;
    JsonAbiNode[] nodes;
}

/// @notice Requests a client-mediated HTTP interaction and EVM callback.
/// @param sender Contract that initiated the request and receives the callback.
/// @param request HTTP request template and client-owned value requirements.
/// @param responseTransform How the client should encode the response for the callback.
/// @param callbackFunction Selector accepting (HttpResponse, bytes).
/// @param extraData Opaque continuation data returned unchanged to the callback.
error ExternalRequest(
    address sender, HttpRequest request, ResponseTransform responseTransform, bytes4 callbackFunction, bytes extraData
);

interface IExternalRequestCallback {
    function externalRequestCallback(HttpResponse calldata response, bytes calldata extraData)
        external
        view
        returns (bytes memory result);
}
