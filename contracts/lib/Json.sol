// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

library Json {
    error JsonFieldNotFound(string key);
    error InvalidJsonValue(string key);
    error InvalidHex();
    error InvalidDecimal();

    function stringValue(bytes memory json, string memory key) internal pure returns (bytes memory value) {
        uint256 cursor = _valueOffset(json, key, 0x22);
        uint256 start = ++cursor;
        while (cursor < json.length) {
            if (json[cursor] == 0x5c) revert InvalidJsonValue(key);
            if (json[cursor] == 0x22) return slice(json, start, cursor - start);
            cursor++;
        }
        revert InvalidJsonValue(key);
    }

    function objectValue(bytes memory json, string memory key) internal pure returns (bytes memory value) {
        uint256 cursor = _valueOffset(json, key, 0x7b);
        uint256 start = cursor;
        uint256 depth;
        bool quoted;
        bool escaped;
        while (cursor < json.length) {
            bytes1 character = json[cursor];
            if (quoted) {
                if (escaped) escaped = false;
                else if (character == 0x5c) escaped = true;
                else if (character == 0x22) quoted = false;
            } else if (character == 0x22) {
                quoted = true;
            } else if (character == 0x7b) {
                depth++;
            } else if (character == 0x7d) {
                depth--;
                if (depth == 0) return slice(json, start, cursor - start + 1);
            }
            cursor++;
        }
        revert InvalidJsonValue(key);
    }

    function addressValue(bytes memory json, string memory key) internal pure returns (address) {
        bytes memory value = stringValue(json, key);
        if (value.length != 42 || value[0] != "0" || value[1] != "x") revert InvalidHex();
        uint160 result;
        for (uint256 i = 2; i < 42; i++) {
            result = result * 16 + _nibble(value[i]);
        }
        return address(result);
    }

    function bytesValue(bytes memory json, string memory key) internal pure returns (bytes memory result) {
        bytes memory value = stringValue(json, key);
        if (value.length < 2 || value[0] != "0" || value[1] != "x" || value.length % 2 != 0) {
            revert InvalidHex();
        }
        result = new bytes((value.length - 2) / 2);
        for (uint256 i = 0; i < result.length; i++) {
            result[i] = bytes1((_nibble(value[2 + i * 2]) << 4) | _nibble(value[3 + i * 2]));
        }
    }

    function decimalStringValue(bytes memory json, string memory key) internal pure returns (uint256 result) {
        bytes memory value = stringValue(json, key);
        if (value.length == 0) revert InvalidDecimal();
        for (uint256 i = 0; i < value.length; i++) {
            uint8 digit = uint8(value[i]);
            if (digit < 48 || digit > 57) revert InvalidDecimal();
            result = result * 10 + digit - 48;
        }
    }

    function uintValue(bytes memory json, string memory key) internal pure returns (uint256 result) {
        uint256 cursor = _valueOffset(json, key, 0x00);
        uint256 digits;
        while (cursor < json.length) {
            uint8 digit = uint8(json[cursor]);
            if (digit < 48 || digit > 57) break;
            result = result * 10 + digit - 48;
            digits++;
            cursor++;
        }
        if (digits == 0) revert InvalidDecimal();
    }

    function hexStringValue(bytes memory json, string memory key) internal pure returns (uint256 result) {
        bytes memory value = stringValue(json, key);
        if (value.length < 3 || value[0] != "0" || value[1] != "x" || value.length > 66) {
            revert InvalidHex();
        }
        for (uint256 i = 2; i < value.length; i++) {
            result = result * 16 + _nibble(value[i]);
        }
    }

    function equals(bytes memory left, string memory right) internal pure returns (bool) {
        return keccak256(left) == keccak256(bytes(right));
    }

    function slice(bytes memory data, uint256 start, uint256 length) internal pure returns (bytes memory result) {
        if (start + length > data.length) revert InvalidJsonValue("slice");
        result = new bytes(length);
        for (uint256 i = 0; i < length; i++) {
            result[i] = data[start + i];
        }
    }

    function _valueOffset(bytes memory json, string memory key, bytes1 expected) private pure returns (uint256) {
        bytes memory keyBytes = bytes(key);
        uint256 depth;
        uint256 found = type(uint256).max;
        for (uint256 cursor = 0; cursor < json.length; cursor++) {
            bytes1 character = json[cursor];
            if (character == 0x7b || character == 0x5b) {
                depth++;
                continue;
            }
            if (character == 0x7d || character == 0x5d) {
                if (depth == 0) revert InvalidJsonValue(key);
                depth--;
                continue;
            }
            if (depth != 1 || character != 0x22) continue;

            uint256 start = cursor + 1;
            uint256 end = start;
            bool escaped;
            while (end < json.length) {
                if (escaped) escaped = false;
                else if (json[end] == 0x5c) escaped = true;
                else if (json[end] == 0x22) break;
                end++;
            }
            if (end >= json.length) revert InvalidJsonValue(key);
            cursor = end;
            uint256 valueCursor = end + 1;
            while (valueCursor < json.length && _whitespace(json[valueCursor])) valueCursor++;
            if (valueCursor >= json.length || json[valueCursor] != 0x3a) continue;

            bool matches = end - start == keyBytes.length;
            for (uint256 i = 0; matches && i < keyBytes.length; i++) {
                if (json[start + i] != keyBytes[i]) matches = false;
            }
            if (!matches) continue;
            valueCursor++;
            while (valueCursor < json.length && _whitespace(json[valueCursor])) valueCursor++;
            if (valueCursor >= json.length || (expected != 0x00 && json[valueCursor] != expected)) continue;
            if (found != type(uint256).max) revert InvalidJsonValue(key);
            found = valueCursor;
        }
        if (found != type(uint256).max) return found;
        revert JsonFieldNotFound(key);
    }

    function _whitespace(bytes1 character) private pure returns (bool) {
        return character == 0x20 || character == 0x09 || character == 0x0a || character == 0x0d;
    }

    function _nibble(bytes1 character) private pure returns (uint8) {
        uint8 value = uint8(character);
        if (value >= 48 && value <= 57) return value - 48;
        if (value >= 65 && value <= 70) return value - 55;
        if (value >= 97 && value <= 102) return value - 87;
        revert InvalidHex();
    }
}
