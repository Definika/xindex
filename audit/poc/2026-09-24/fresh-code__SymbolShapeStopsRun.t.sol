// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ConfigureWhitelist} from "../../script/ConfigureWhitelist.s.sol";
import {IndexFactory} from "../../src/IndexFactory.sol";
import {DEFAULT_STALENESS, MockMarket} from "../mocks/MockMarket.sol";

/// @notice An 18-decimal token whose `symbol()` answers two words that are not an ABI string, such as a token that
///         returns `(bytes32 symbol, uint256 something)` from a non-standard getter.
contract OddSymbolToken is ERC20 {
    constructor() ERC20("Odd", "ODD") {}

    function symbol() public pure override returns (string memory) {
        assembly ("memory-safe") {
            mstore(0, 0x20) // a plausible offset...
            mstore(0x20, not(0)) // ...and an absurd length
            return(0, 0x40)
        }
    }
}

/// @notice `ConfigureWhitelist._symbolOf` (added for CR-L08) promises: "A static call, so a token without the function,
///         or one answering in another shape, cannot stop the run." It only guards answers shorter than 64 bytes; a
///         64-byte answer that is not a valid string reaches `abi.decode` and reverts, which aborts the whole propose,
///         safe or status run rather than logging "?" for one entry. No test exercises a non-string symbol at all: the
///         `< 64` guard can be weakened to `< 32` (which also breaks the bytes32-symbol case the NatSpec names) and the
///         whole suite still passes.
contract SymbolShapeStopsRunTest is Test {
    function test_aNonStringSymbolAbortsTheWholeSafeRun() public {
        ConfigureWhitelist configure = new ConfigureWhitelist();
        MockMarket market = new MockMarket();
        IndexFactory factory = new IndexFactory(DEFAULT_SENDER, makeAddr("guardian"));
        OddSymbolToken odd = new OddSymbolToken();
        market.config(address(odd), 1e8);

        ConfigureWhitelist.Entry[] memory list = new ConfigureWhitelist.Entry[](1);
        list[0] = ConfigureWhitelist.Entry({
            token: address(odd),
            feed: address(market.feedOf(address(odd))),
            maxStaleness: DEFAULT_STALENESS,
            referenceSupply: 1_000_000e18
        });
        vm.expectRevert(); // abi.decode of the symbol reverts inside _followsPolicy, taking the whole run with it
        configure.safeCalldata(factory, list, new address[](0));
    }
}
