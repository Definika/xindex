// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ISyntheticSharesOracle} from "../../src/interfaces/ISyntheticSharesOracle.sol";

interface IMintableAsset {
    function mint(address to, uint256 amount) external;
}

/// @notice An ERC-4626 vault over one mintable asset, as Backed's wrapper of an xStock is: one vault token redeems for
///         `convertToAssets` of the asset, which rises when the vault is given more of it. `mint` gives an account
///         vault tokens backed by fresh assets at the current rate, so a test's issue can deposit them.
contract MockVault is ERC4626 {
    constructor(IERC20 asset_) ERC20("Vault", "VLT") ERC4626(asset_) {}

    function mint(address to, uint256 shares) external {
        uint256 assets = previewMint(shares);
        IMintableAsset(asset()).mint(address(this), assets);
        _mint(to, shares);
    }
}

/// @notice A token whose one unit stands for `multiplier()` shares, as Coinbase's stock tokens on Base are: balances
///         stay fixed when the multiplier moves.
contract MockMultiplierToken is ERC20 {
    uint256 public multiplier = 1e18;
    uint8 internal immutable _decimals;

    constructor(uint8 decimals_) ERC20("Stock", "STKc") {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function setMultiplier(uint256 multiplier_) external {
        multiplier = multiplier_;
    }
}

/// @notice Ondo's `SyntheticSharesOracle` as `PythPrices` reads it: an entry per token, which a test writes as Ondo's
///         admin and setter would. A token never written reads as all zeros, as Ondo's getter does.
contract MockSharesOracle is ISyntheticSharesOracle {
    struct Entry {
        uint128 sValue;
        uint128 pendingSValue;
        uint256 lastUpdate;
        uint256 pauseStartTime;
    }

    mapping(address asset => Entry entry) internal _entries;

    /// @notice Writes `asset`'s sValue as last changed at `lastUpdate`, with a corporate action's pause from
    ///         `pauseStartTime` and its sValue `pendingSValue`, both zero for none.
    function set(address asset, uint128 sValue, uint256 lastUpdate, uint256 pauseStartTime, uint128 pendingSValue)
        external
    {
        _entries[asset] = Entry(sValue, pendingSValue, lastUpdate, pauseStartTime);
    }

    function assetData(address asset) external view returns (uint128, uint128, uint256, uint256, uint16, uint48) {
        Entry memory e = _entries[asset];
        return (e.sValue, e.pendingSValue, e.lastUpdate, e.pauseStartTime, 100, 1 days);
    }
}
