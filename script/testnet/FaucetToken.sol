// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title FaucetToken
/// @notice Testnet-only ERC-20 that stands in for a real token. The deployer receives the starting supply to seed
///         Uniswap pools, and any account can {drip} a fixed amount once per COOLDOWN. It has no owner and no value.
///         Its supply grows with every drip, so index listings for it use a reference supply.
contract FaucetToken is ERC20 {
    /// @notice Least time between two drips by the same account.
    uint256 public constant COOLDOWN = 1 days;

    /// @notice Amount one {drip} mints.
    uint256 public immutable DRIP_AMOUNT;
    uint8 private immutable DECIMALS;

    /// @notice Time of `account`'s last drip, or 0 if it never dripped.
    mapping(address account => uint256 time) public lastDrip;

    /// @notice The caller dripped less than COOLDOWN ago and can drip again at `nextDrip`.
    error DripTooSoon(uint256 nextDrip);

    /// @param name_ ERC-20 name.
    /// @param symbol_ ERC-20 symbol.
    /// @param decimals_ Token decimals.
    /// @param dripAmount What each {drip} mints.
    /// @param initialSupply Minted to the deployer.
    constructor(string memory name_, string memory symbol_, uint8 decimals_, uint256 dripAmount, uint256 initialSupply)
        ERC20(name_, symbol_)
    {
        DECIMALS = decimals_;
        DRIP_AMOUNT = dripAmount;
        _mint(msg.sender, initialSupply);
    }

    /// @notice Mints DRIP_AMOUNT to msg.sender, at most once per COOLDOWN per account.
    function drip() external {
        uint256 last = lastDrip[msg.sender];
        if (last != 0 && block.timestamp < last + COOLDOWN) revert DripTooSoon(last + COOLDOWN);
        lastDrip[msg.sender] = block.timestamp;
        _mint(msg.sender, DRIP_AMOUNT);
    }

    /// @notice The decimals given at deployment.
    function decimals() public view override returns (uint8) {
        return DECIMALS;
    }
}
