// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice WBTC-like token whose issuer can pause every transfer, and that can also be made to fail reads, as a
///         component whose implementation is withdrawn or self-destructs behind a proxy would.
contract MockPausableToken is ERC20 {
    uint8 private immutable _decimals;
    bool public paused;
    bool public readsBroken;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function name() public view override returns (string memory) {
        _checkReads();
        return super.name();
    }

    function symbol() public view override returns (string memory) {
        _checkReads();
        return super.symbol();
    }

    function decimals() public view override returns (uint8) {
        _checkReads();
        return _decimals;
    }

    function totalSupply() public view override returns (uint256) {
        _checkReads();
        return super.totalSupply();
    }

    function allowance(address owner, address spender) public view override returns (uint256) {
        _checkReads();
        return super.allowance(owner, spender);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setPaused(bool p) external {
        paused = p;
    }

    /// @notice Makes every ERC-20 read revert, as a proxy's reads do once its implementation is withdrawn, which a
    ///         paused token does not: pausing stops transfers, not reads (DA-14, RT-01).
    function setReadsBroken(bool broken) external {
        readsBroken = broken;
    }

    function balanceOf(address account) public view override returns (uint256) {
        _checkReads();
        return super.balanceOf(account);
    }

    function _checkReads() private view {
        require(!readsBroken, "reads broken");
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!paused, "paused");
        super._update(from, to, value);
    }
}
