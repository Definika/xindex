// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @notice The storage of Uniswap V4's PoolManager as `extsload` exposes it, laid out as v4-core lays it out: the pools
///         mapping at slot 6, each pool's packed slot0 (the price in its low 160 bits, then the tick and the fees) at
///         the hash of its id and that slot, and its liquidity three slots on. Used to test `CheckToken`'s depth reads.
contract MockPoolManager {
    uint256 internal constant POOLS_SLOT = 6;
    uint256 internal constant LIQUIDITY_OFFSET = 3;

    mapping(bytes32 slot => bytes32) internal _words;

    function extsload(bytes32 slot) external view returns (bytes32) {
        return _words[slot];
    }

    /// @notice Initializes the hookless pool of `currency0` and `currency1` (sorted, ether as zero) at `fee` and
    ///         `tickSpacing`. `tick` and `lpFee` fill slot0's upper bits, which a reader must mask off.
    function setPool(
        address currency0,
        address currency1,
        uint24 fee,
        int24 tickSpacing,
        uint160 sqrtPriceX96,
        int24 tick,
        uint24 lpFee,
        uint128 liquidity
    ) external {
        bytes32 id = keccak256(abi.encode(currency0, currency1, fee, tickSpacing, address(0)));
        bytes32 state = keccak256(abi.encodePacked(id, bytes32(POOLS_SLOT)));
        uint256 packed = uint256(sqrtPriceX96) | (uint256(uint24(tick)) << 160) | (uint256(lpFee) << 208);
        _words[state] = bytes32(packed);
        _words[bytes32(uint256(state) + LIQUIDITY_OFFSET)] = bytes32(uint256(liquidity));
    }
}
