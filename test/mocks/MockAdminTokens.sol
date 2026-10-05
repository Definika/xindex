// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";

/// @notice A token whose owner can pause every transfer and blacklist any holder, as many exchange and fiat tokens can,
///         under Tether's names. `CheckToken` records both powers and lists it: it cannot destroy a balance.
contract MockBlacklistToken is ERC20 {
    address public owner;
    bool public paused;
    mapping(address account => bool) public isBlackListed;

    constructor(address owner_) ERC20("Blacklist Token", "BLK") {
        owner = owner_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function pause() external {
        paused = true;
    }

    function unpause() external {
        paused = false;
    }

    function addBlackList(address account) external {
        isBlackListed[account] = true;
    }

    function _update(address from, address to, uint256 value) internal virtual override {
        require(!paused && !isBlackListed[from] && !isBlackListed[to], "blocked");
        super._update(from, to, value);
    }
}

/// @notice A blacklisting token whose owner can also destroy a blacklisted holder's balance, as Tether and WhiteBIT's
///         WBT can: what the WBT rule refuses.
contract MockSeizableToken is MockBlacklistToken {
    constructor(address owner_) MockBlacklistToken(owner_) {}

    function destroyBlackFunds(address account) external {
        isBlackListed[account] = false;
        _burn(account, balanceOf(account));
        isBlackListed[account] = true;
    }
}

/// @notice A token with BEP-20's `getOwner` and no `owner`, whose owner mints to itself, as Binance-Peg tokens do.
contract MockBep20Token is ERC20 {
    address public getOwner;

    constructor(address owner_) ERC20("Peg Token", "PEG") {
        getOwner = owner_;
    }

    function mint(uint256 amount) external {
        _mint(getOwner, amount);
    }
}

/// @notice A MiniMe controller that approves every transfer, as LEO's does.
contract MockTokenController {
    address public owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function onTransfer(address, address, uint256) external pure returns (bool) {
        return true;
    }
}

/// @notice A MiniMe token, as LEO is: its controller mints and destroys any holder's balance, and is asked to approve
///         every transfer, so it can refuse any holder's.
contract MockMiniMeToken is ERC20 {
    address public controller;

    constructor(address controller_) ERC20("MiniMe Token", "MINI") {
        controller = controller_;
    }

    function generateTokens(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function destroyTokens(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) MockTokenController(controller).onTransfer(from, to, value);
        super._update(from, to, value);
    }
}

/// @notice A token whose powers are held by AccessControl roles, enumerable, as POL's are.
contract MockRolesToken is ERC20, AccessControlEnumerable {
    constructor(address admin) ERC20("Roles Token", "ROLE") {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function mint(address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _mint(to, amount);
    }
}
