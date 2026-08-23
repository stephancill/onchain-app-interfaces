// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.30;

library Text {
    bytes16 private constant HEX = "0123456789abcdef";

    function addressString(address account) internal pure returns (string memory) {
        bytes20 value = bytes20(account);
        bytes memory output = new bytes(42);
        output[0] = "0";
        output[1] = "x";
        for (uint256 i = 0; i < 20; i++) {
            uint8 byteValue = uint8(value[i]);
            output[2 + i * 2] = HEX[byteValue >> 4];
            output[3 + i * 2] = HEX[byteValue & 0x0f];
        }
        return string(output);
    }

    function uintString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 digits;
        uint256 remaining = value;
        while (remaining != 0) {
            digits++;
            remaining /= 10;
        }
        bytes memory output = new bytes(digits);
        while (value != 0) {
            // The remainder is always one decimal digit.
            // forge-lint: disable-next-line(unsafe-typecast)
            output[--digits] = bytes1(uint8(48 + value % 10));
            value /= 10;
        }
        return string(output);
    }

    function percentEncode(string memory value) internal pure returns (string memory) {
        bytes memory input = bytes(value);
        bytes memory output = new bytes(input.length * 3);
        uint256 outputLength;
        for (uint256 i = 0; i < input.length; i++) {
            uint8 character = uint8(input[i]);
            if (
                (character >= 65 && character <= 90) || (character >= 97 && character <= 122)
                    || (character >= 48 && character <= 57) || character == 45 || character == 46 || character == 95
                    || character == 126
            ) {
                output[outputLength++] = input[i];
            } else {
                output[outputLength++] = "%";
                output[outputLength++] = HEX[character >> 4];
                output[outputLength++] = HEX[character & 0x0f];
            }
        }

        bytes memory encoded = new bytes(outputLength);
        for (uint256 i = 0; i < outputLength; i++) {
            encoded[i] = output[i];
        }
        return string(encoded);
    }
}
