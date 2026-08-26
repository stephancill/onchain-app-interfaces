// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

library Json {
    uint256 private constant MAX_NESTING_DEPTH = 32;

    error JsonFieldNotFound(string key);
    error InvalidJsonValue(string key);
    error InvalidHex();
    error InvalidDecimal();

    function stringValue(bytes memory json, string memory key) internal pure returns (bytes memory value) {
        uint256 cursor = _valueOffset(json, key, 0x22);
        uint256 end = _skipString(json, cursor);
        for (uint256 i = cursor + 1; i + 1 < end; i++) {
            if (json[i] == 0x5c) revert InvalidJsonValue(key);
        }
        return slice(json, cursor + 1, end - cursor - 2);
    }

    function objectValue(bytes memory json, string memory key) internal pure returns (bytes memory value) {
        uint256 start = _valueOffset(json, key, 0x7b);
        uint256 end = _skipValue(json, start, 0);
        return slice(json, start, end - start);
    }

    function arrayValue(bytes memory json, string memory key) internal pure returns (bytes memory value) {
        uint256 start = _valueOffset(json, key, 0x5b);
        uint256 end = _skipValue(json, start, 0);
        return slice(json, start, end - start);
    }

    function arrayLength(bytes memory array) internal pure returns (uint256 length) {
        (uint256 cursor, bool empty) = _arrayStart(array);
        if (empty) return 0;
        while (true) {
            cursor = _skipValue(array, cursor, 1);
            cursor = _skipWhitespace(array, cursor);
            if (cursor >= array.length) revert InvalidJsonValue("array");
            if (array[cursor] == 0x5d) {
                if (_skipWhitespace(array, cursor + 1) != array.length) revert InvalidJsonValue("array");
                return length + 1;
            }
            if (array[cursor] != 0x2c) revert InvalidJsonValue("array");
            cursor = _skipWhitespace(array, cursor + 1);
            length++;
        }
    }

    function objectArray(bytes memory array) internal pure returns (bytes[] memory values) {
        uint256 length = arrayLength(array);
        values = new bytes[](length);
        if (length == 0) return values;
        (uint256 cursor, bool empty) = _arrayStart(array);
        if (empty) revert InvalidJsonValue("array");
        for (uint256 i = 0; i < length; i++) {
            uint256 start = cursor;
            uint256 end = _skipValue(array, cursor, 1);
            if (array[start] != 0x7b) revert InvalidJsonValue("array object");
            values[i] = slice(array, start, end - start);
            cursor = _skipWhitespace(array, end);
            if (i + 1 == length) {
                if (cursor >= array.length || array[cursor] != 0x5d) revert InvalidJsonValue("array");
                continue;
            }
            if (cursor >= array.length || array[cursor] == 0x5d) revert InvalidJsonValue("array");
            if (array[cursor] != 0x2c) revert InvalidJsonValue("array");
            cursor = _skipWhitespace(array, cursor + 1);
        }
    }

    function objectArrayField(bytes memory json, string memory key, uint256 maxItems)
        internal
        pure
        returns (uint256[] memory starts, uint256[] memory ends)
    {
        uint256 arrayStart = _valueOffset(json, key, 0x5b);
        uint256 cursor = _skipWhitespace(json, arrayStart + 1);
        if (cursor < json.length && json[cursor] == 0x5d) {
            if (_skipWhitespace(json, cursor + 1) != _skipValue(json, arrayStart, 0)) {
                revert InvalidJsonValue(key);
            }
            return (starts, ends);
        }
        uint256 count;
        starts = new uint256[](maxItems);
        ends = new uint256[](maxItems);
        while (true) {
            if (count == maxItems) revert InvalidJsonValue(key);
            uint256 start = cursor;
            uint256 end = _skipValue(json, cursor, 1);
            if (json[start] != 0x7b) revert InvalidJsonValue(key);
            starts[count] = start;
            ends[count] = end;
            count++;
            cursor = _skipWhitespace(json, end);
            if (cursor >= json.length) revert InvalidJsonValue(key);
            if (json[cursor] == 0x5d) break;
            if (json[cursor] != 0x2c) revert InvalidJsonValue(key);
            cursor = _skipWhitespace(json, cursor + 1);
        }
        assembly ("memory-safe") {
            mstore(starts, count)
            mstore(ends, count)
        }
    }

    function valueOffsets(bytes memory json, bytes32[] memory keyHashes)
        internal
        pure
        returns (uint256[] memory offsets)
    {
        return valueOffsetsBetween(json, 0, json.length, keyHashes);
    }

    function valueOffsetsBetween(bytes memory json, uint256 from, uint256 to, bytes32[] memory keyHashes)
        internal
        pure
        returns (uint256[] memory offsets)
    {
        offsets = new uint256[](keyHashes.length);
        for (uint256 i = 0; i < offsets.length; i++) {
            offsets[i] = type(uint256).max;
        }

        uint256 cursor = _skipWhitespace(json, from);
        if (cursor >= to || json[cursor++] != 0x7b) revert InvalidJsonValue("object");
        cursor = _skipWhitespace(json, cursor);
        while (cursor < to && json[cursor] != 0x7d) {
            if (json[cursor] != 0x22) revert InvalidJsonValue("object");
            uint256 keyStart = cursor + 1;
            uint256 keyEnd = _skipString(json, cursor) - 1;
            bytes32 keyHash;
            assembly ("memory-safe") {
                keyHash := keccak256(add(add(json, 0x20), keyStart), sub(keyEnd, keyStart))
            }
            cursor = _skipWhitespace(json, keyEnd + 1);
            if (cursor >= to || json[cursor] != 0x3a) revert InvalidJsonValue("object");
            cursor = _skipWhitespace(json, cursor + 1);
            if (cursor >= to) revert InvalidJsonValue("object");
            for (uint256 i = 0; i < keyHashes.length; i++) {
                if (keyHash != keyHashes[i]) continue;
                if (offsets[i] != type(uint256).max) revert InvalidJsonValue("duplicate field");
                offsets[i] = cursor;
                break;
            }
            cursor = _skipWhitespace(json, _skipValue(json, cursor, 1));
            if (cursor >= to) revert InvalidJsonValue("object");
            if (json[cursor] == 0x7d) break;
            if (json[cursor] != 0x2c) revert InvalidJsonValue("object");
            cursor = _skipWhitespace(json, cursor + 1);
        }
        if (
            cursor >= to || json[cursor] != 0x7d
                || (cursor + 1 != to && _skipWhitespaceBetween(json, cursor + 1, to) != to)
        ) {
            revert InvalidJsonValue("object");
        }
        for (uint256 i = 0; i < offsets.length; i++) {
            if (offsets[i] == type(uint256).max) revert JsonFieldNotFound("indexed field");
        }
    }

    function boolAt(bytes memory json, uint256 cursor) internal pure returns (bool) {
        if (_matchesLiteral(json, cursor, "true")) return true;
        if (_matchesLiteral(json, cursor, "false")) return false;
        revert InvalidJsonValue("indexed bool");
    }

    function addressAt(bytes memory json, uint256 cursor) internal pure returns (address) {
        if (cursor + 44 > json.length || json[cursor] != 0x22 || json[cursor + 1] != "0" || json[cursor + 2] != "x") {
            revert InvalidHex();
        }
        uint160 result;
        for (uint256 i = 2; i < 42; i++) {
            result = result * 16 + _nibble(json[cursor + 1 + i]);
        }
        if (json[cursor + 43] != 0x22 || !_valueBoundary(json, cursor + 44)) revert InvalidHex();
        return address(result);
    }

    function decimalStringAt(bytes memory json, uint256 cursor) internal pure returns (uint256 result) {
        if (cursor >= json.length || json[cursor] != 0x22) revert InvalidDecimal();
        uint256 position = cursor + 1;
        while (position < json.length && json[position] != 0x22) {
            uint8 digit = uint8(json[position]);
            if (digit < 48 || digit > 57) revert InvalidDecimal();
            result = result * 10 + digit - 48;
            position++;
        }
        if (position == cursor + 1 || !_valueBoundary(json, position + 1)) revert InvalidDecimal();
    }

    function uintAt(bytes memory json, uint256 cursor) internal pure returns (uint256 result) {
        uint256 start = cursor;
        while (cursor < json.length && uint8(json[cursor]) >= 48 && uint8(json[cursor]) <= 57) {
            result = result * 10 + uint8(json[cursor]) - 48;
            cursor++;
        }
        if (cursor == start || !_valueBoundary(json, cursor)) revert InvalidDecimal();
    }

    function boolValue(bytes memory json, string memory key) internal pure returns (bool) {
        uint256 cursor = _valueOffset(json, key, 0x00);
        if (_matchesLiteral(json, cursor, "true")) return true;
        if (_matchesLiteral(json, cursor, "false")) return false;
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
        uint256 start = cursor;
        while (cursor < json.length && uint8(json[cursor]) >= 48 && uint8(json[cursor]) <= 57) {
            result = result * 10 + uint8(json[cursor]) - 48;
            cursor++;
        }
        if (cursor == start || !_valueBoundary(json, cursor)) revert InvalidDecimal();
    }

    function hexStringValue(bytes memory json, string memory key) internal pure returns (uint256 result) {
        bytes memory value = stringValue(json, key);
        if (value.length < 3 || value[0] != "0" || value[1] != "x" || value.length > 66) revert InvalidHex();
        for (uint256 i = 2; i < value.length; i++) {
            result = result * 16 + _nibble(value[i]);
        }
    }

    function equals(bytes memory left, string memory right) internal pure returns (bool) {
        return keccak256(left) == keccak256(bytes(right));
    }

    function slice(bytes memory data, uint256 start, uint256 length) internal pure returns (bytes memory result) {
        if (start > data.length || length > data.length - start) revert InvalidJsonValue("slice");
        result = new bytes(length);
        assembly ("memory-safe") {
            let src := add(add(data, 0x20), start)
            let dst := add(result, 0x20)
            let full := shl(5, shr(5, length))
            for { let copied := 0 } lt(copied, full) { copied := add(copied, 0x20) } {
                mstore(dst, mload(src))
                dst := add(dst, 0x20)
                src := add(src, 0x20)
            }
            for { let i := 0 } lt(i, and(length, 0x1f)) { i := add(i, 1) } {
                mstore8(dst, byte(i, mload(src)))
                dst := add(dst, 1)
            }
        }
    }

    function _valueOffset(bytes memory json, string memory key, bytes1 expected) private pure returns (uint256 found) {
        bytes memory keyBytes = bytes(key);
        uint256 cursor = _skipWhitespace(json, 0);
        if (cursor >= json.length || json[cursor++] != 0x7b) revert InvalidJsonValue(key);
        cursor = _skipWhitespace(json, cursor);
        found = type(uint256).max;
        if (cursor < json.length && json[cursor] == 0x7d) {
            if (_skipWhitespace(json, cursor + 1) != json.length) revert InvalidJsonValue(key);
            revert JsonFieldNotFound(key);
        }
        while (true) {
            if (cursor >= json.length || json[cursor] != 0x22) revert InvalidJsonValue(key);
            uint256 keyStart = cursor + 1;
            uint256 keyEnd = _skipString(json, cursor) - 1;
            bool matches = keyEnd - keyStart == keyBytes.length;
            for (uint256 i = 0; matches && i < keyBytes.length; i++) {
                if (json[keyStart + i] != keyBytes[i]) matches = false;
            }
            cursor = _skipWhitespace(json, keyEnd + 1);
            if (cursor >= json.length || json[cursor] != 0x3a) revert InvalidJsonValue(key);
            cursor = _skipWhitespace(json, cursor + 1);
            if (cursor >= json.length) revert InvalidJsonValue(key);
            if (matches) {
                if (found != type(uint256).max) revert InvalidJsonValue(key);
                if (expected != 0x00 && json[cursor] != expected) revert InvalidJsonValue(key);
                found = cursor;
            }
            cursor = _skipWhitespace(json, _skipValue(json, cursor, 1));
            if (cursor >= json.length) revert InvalidJsonValue(key);
            if (json[cursor] == 0x7d) {
                if (_skipWhitespace(json, cursor + 1) != json.length) revert InvalidJsonValue(key);
                break;
            }
            if (json[cursor] != 0x2c) revert InvalidJsonValue(key);
            cursor = _skipWhitespace(json, cursor + 1);
        }
        if (found == type(uint256).max) revert JsonFieldNotFound(key);
    }

    function _arrayStart(bytes memory array) private pure returns (uint256 cursor, bool empty) {
        cursor = _skipWhitespace(array, 0);
        if (cursor >= array.length || array[cursor] != 0x5b) revert InvalidJsonValue("array");
        cursor = _skipWhitespace(array, cursor + 1);
        if (cursor < array.length && array[cursor] == 0x5d) {
            if (_skipWhitespace(array, cursor + 1) != array.length) revert InvalidJsonValue("array");
            return (cursor, true);
        }
        if (cursor >= array.length) revert InvalidJsonValue("array");
    }

    function _skipValue(bytes memory json, uint256 cursor, uint256 depth) private pure returns (uint256) {
        if (cursor >= json.length) revert InvalidJsonValue("value");
        bytes1 character = json[cursor];
        if (character == 0x22) return _skipString(json, cursor);
        if (character == 0x7b || character == 0x5b) {
            if (depth >= MAX_NESTING_DEPTH) revert InvalidJsonValue("depth");
            return _skipContainer(json, cursor, character == 0x7b ? bytes1(0x7d) : bytes1(0x5d), depth + 1);
        }
        if (_matchesLiteral(json, cursor, "true")) return cursor + 4;
        if (_matchesLiteral(json, cursor, "false")) return cursor + 5;
        if (_matchesLiteral(json, cursor, "null")) return cursor + 4;
        return _skipNumber(json, cursor);
    }

    function _skipContainer(bytes memory json, uint256 cursor, bytes1 close, uint256 depth)
        private
        pure
        returns (uint256 end)
    {
        bytes1 open = json[cursor];
        cursor = _skipWhitespace(json, cursor + 1);
        if (cursor < json.length && json[cursor] == close) return cursor + 1;
        while (true) {
            if (open == 0x7b) {
                if (cursor >= json.length || json[cursor] != 0x22) revert InvalidJsonValue("object");
                cursor = _skipWhitespace(json, _skipString(json, cursor));
                if (cursor >= json.length || json[cursor] != 0x3a) revert InvalidJsonValue("object");
                cursor = _skipWhitespace(json, cursor + 1);
            }
            cursor = _skipWhitespace(json, _skipValue(json, cursor, depth));
            if (cursor >= json.length) revert InvalidJsonValue("container");
            if (json[cursor] == close) return cursor + 1;
            if (json[cursor] != 0x2c) revert InvalidJsonValue("container");
            cursor = _skipWhitespace(json, cursor + 1);
        }
    }

    function _skipString(bytes memory json, uint256 cursor) private pure returns (uint256) {
        if (cursor >= json.length || json[cursor] != 0x22) revert InvalidJsonValue("string");
        for (cursor++; cursor < json.length; cursor++) {
            uint8 character = uint8(json[cursor]);
            if (character < 0x20) revert InvalidJsonValue("string");
            if (character == 0x22) return cursor + 1;
            if (character != 0x5c) continue;
            if (++cursor >= json.length) revert InvalidJsonValue("string");
            character = uint8(json[cursor]);
            if (character == 0x75) {
                if (cursor + 4 >= json.length) revert InvalidJsonValue("string");
                for (uint256 i = 1; i <= 4; i++) {
                    _nibble(json[cursor + i]);
                }
                cursor += 4;
            } else if (
                character != 0x22 && character != 0x5c && character != 0x2f && character != 0x62 && character != 0x66
                    && character != 0x6e && character != 0x72 && character != 0x74
            ) {
                revert InvalidJsonValue("string");
            }
        }
        revert InvalidJsonValue("string");
    }

    function _skipNumber(bytes memory json, uint256 cursor) private pure returns (uint256) {
        uint256 start = cursor;
        if (json[cursor] == 0x2d && ++cursor >= json.length) revert InvalidJsonValue("number");
        if (json[cursor] == 0x30) {
            cursor++;
        } else {
            if (uint8(json[cursor]) < 49 || uint8(json[cursor]) > 57) revert InvalidJsonValue("number");
            while (cursor < json.length && uint8(json[cursor]) >= 48 && uint8(json[cursor]) <= 57) cursor++;
        }
        if (cursor < json.length && json[cursor] == 0x2e) {
            uint256 fraction = ++cursor;
            while (cursor < json.length && uint8(json[cursor]) >= 48 && uint8(json[cursor]) <= 57) cursor++;
            if (cursor == fraction) revert InvalidJsonValue("number");
        }
        if (cursor < json.length && (json[cursor] == 0x65 || json[cursor] == 0x45)) {
            cursor++;
            if (cursor < json.length && (json[cursor] == 0x2b || json[cursor] == 0x2d)) cursor++;
            uint256 exponent = cursor;
            while (cursor < json.length && uint8(json[cursor]) >= 48 && uint8(json[cursor]) <= 57) cursor++;
            if (cursor == exponent) revert InvalidJsonValue("number");
        }
        if (cursor == start || !_valueBoundary(json, cursor)) revert InvalidJsonValue("number");
        return cursor;
    }

    function _matchesLiteral(bytes memory json, uint256 cursor, bytes memory literal) private pure returns (bool) {
        if (cursor > json.length || literal.length > json.length - cursor) return false;
        for (uint256 i = 0; i < literal.length; i++) {
            if (json[cursor + i] != literal[i]) return false;
        }
        return _valueBoundary(json, cursor + literal.length);
    }

    function _valueBoundary(bytes memory json, uint256 cursor) private pure returns (bool) {
        return cursor == json.length || _whitespace(json[cursor]) || json[cursor] == 0x2c || json[cursor] == 0x5d
            || json[cursor] == 0x7d;
    }

    function _skipWhitespaceBetween(bytes memory json, uint256 cursor, uint256 to) private pure returns (uint256) {
        while (cursor < to && _whitespace(json[cursor])) cursor++;
        return cursor;
    }

    function _skipWhitespace(bytes memory json, uint256 cursor) private pure returns (uint256) {
        while (cursor < json.length && _whitespace(json[cursor])) cursor++;
        return cursor;
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
