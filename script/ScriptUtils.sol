// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @notice Constants and helpers the deploy, listing, admission and test-market scripts share.
library ScriptUtils {
    /// @dev Bytes in an ABI word.
    uint256 internal constant WORD = 32;

    /// @notice Uniswap V3 fee tiers the listed WETH pools use.
    uint24 internal constant POOL_FEE_LOW = 500;
    uint24 internal constant POOL_FEE_MEDIUM = 3000;

    /// @notice Whether `code` is an EIP-7702 delegation: 0xef0100 followed by the delegate address. Such an account is
    ///         still a key that signs transactions, not a contract. Since EIP-3541 no contract can deploy code that
    ///         starts with 0xef, so the 0xef01 prefix alone identifies a delegation.
    function isDelegatedAccount(bytes memory code) internal pure returns (bool) {
        return code.length >= 2 && code[0] == 0xef && code[1] == 0x01;
    }

    /// @notice Whether two strings are equal, for mode and symbol checks.
    function same(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    /// @notice `token`'s ERC-20 symbol, or "?" when it has none that decodes as a string: the symbol is optional in
    ///         ERC-20, and some tokens return it as bytes32.
    function symbolOf(address token) internal view returns (string memory) {
        // A static call, so a token without the function, or one answering in another shape, cannot stop the run.
        // forge-lint: disable-next-line(low-level-calls)
        (bool ok, bytes memory data) = token.staticcall(abi.encodeCall(IERC20Metadata.symbol, ()));
        // A string answer holds at least its offset and its length; anything shorter, a bytes32 among them, is not one.
        if (!ok || data.length < 2 * WORD) return "?";
        // Nor is an answer whose offset or length points past its end, which `abi.decode` refuses by reverting, and
        // that reverted the whole run (RT-25). The offset is checked first, so the length is read inside the answer.
        uint256 offset = wordAt(data, 0);
        if (offset > data.length - WORD || wordAt(data, offset) > data.length - WORD - offset) return "?";
        return abi.decode(data, (string));
    }

    /// @notice What `token.decimals()` answers, when it answers a uint8 at all. A static call whose answer is checked
    ///         before it is read, so a token without the function, or one answering in another shape, cannot stop the
    ///         run: decoding a `try` call's answer happens in the caller, where no `catch` reaches a failure.
    function decimalsOf(address token) internal view returns (bool answered, uint8 decimals) {
        // forge-lint: disable-next-line(low-level-calls)
        (bool ok, bytes memory data) = token.staticcall(abi.encodeCall(IERC20Metadata.decimals, ()));
        // A failed call, or an answer shorter than a word, reads as a word no uint8 fits.
        uint256 word = ok && data.length >= WORD ? wordAt(data, 0) : type(uint256).max;
        answered = word <= type(uint8).max;
        if (answered) decimals = SafeCast.toUint8(word);
    }

    /// @notice The word of `data` that starts at byte `at`, read big-endian; the caller keeps it inside `data`.
    function wordAt(bytes memory data, uint256 at) internal pure returns (uint256 word) {
        for (uint256 i = 0; i < WORD; ++i) {
            word = word << 8 | uint8(data[at + i]);
        }
    }
}
