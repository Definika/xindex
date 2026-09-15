// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {
    ERC20PermitUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IIndexToken} from "./interfaces/IIndexToken.sol";

/// @title IndexToken
/// @notice Fully collateralized, fixed-composition index token. See {IIndexToken}.
/// @dev Deployed as an EIP-1167 clone by {IndexFactory}. The implementation is deployed from the
///      factory constructor so `FACTORY` can be an immutable (immutables live in bytecode, which clones
///      delegate to, so every clone sees the same value).
///
///      The storage-based {ReentrancyGuard} is used deliberately: its namespaced slot reads as
///      "not entered" when zero, so it needs no initializer and is safe in a clone.
///
///      Only an initialized clone can issue or redeem. The implementation and any clone deployed outside
///      the factory have no components and would otherwise mint unbacked shares.
///
///      Invariant, for every component i:
///          token_i.balanceOf(index) >= floor(totalSupply * units_i / 1e18) + totalClaims[token_i]
///      Issue rounds up and redeem rounds down, so rounding drift is at most one raw unit per call and
///      is always in favour of the remaining holders. A claim is recorded only for an amount that stayed in
///      the index, so claims never dilute other holders. Nothing is ever computed from balances, so there
///      is no share price to manipulate and no first-depositor attack.
contract IndexToken is Initializable, ERC20Upgradeable, ERC20PermitUpgradeable, ReentrancyGuard, IIndexToken {
    using SafeERC20 for IERC20;

    uint256 public constant SHARE_UNIT = 1e18;
    address public immutable FACTORY;

    struct Component {
        address token;
        uint96 units;
    }

    Component[] private _components;

    /// @inheritdoc IIndexToken
    mapping(address account => mapping(address token => uint256 amount)) public claimOf;

    /// @inheritdoc IIndexToken
    mapping(address token => uint256 amount) public totalClaims;

    modifier onlyInitialized() {
        _checkInitialized();
        _;
    }

    constructor() {
        FACTORY = msg.sender;
        _disableInitializers();
    }

    /// @inheritdoc IIndexToken
    function initialize(
        string calldata name_,
        string calldata symbol_,
        address[] calldata tokens,
        uint256[] calldata units
    ) external initializer {
        if (msg.sender != FACTORY) revert NotFactory();
        uint256 n = tokens.length;
        if (n == 0 || n != units.length) revert InvalidComponents();

        __ERC20_init(name_, symbol_);
        __ERC20Permit_init(name_);

        for (uint256 i = 0; i < n; ++i) {
            if (tokens[i] == address(0) || units[i] == 0) revert InvalidComponents();
            _components.push(Component({token: tokens[i], units: SafeCast.toUint96(units[i])}));
        }
    }

    // ---------------------------------------------------------------------
    // Issue / redeem / claim
    // ---------------------------------------------------------------------

    /// @inheritdoc IIndexToken
    function issue(uint256 shares, address to) external nonReentrant onlyInitialized {
        if (shares == 0) revert ZeroShares();
        _checkRecipient(to);

        // Effects and event first, then pull the basket. The transfer check below makes the
        // mint conditional on receiving every component in full.
        uint256[] memory amounts = _amounts(shares, Math.Rounding.Ceil);
        _mint(to, shares);
        // `_mint` is internal (OpenZeppelin); no external call precedes this event.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Issued(msg.sender, to, shares, amounts);

        uint256 n = amounts.length;
        for (uint256 i = 0; i < n; ++i) {
            IERC20 token = IERC20(_components[i].token);
            uint256 before = token.balanceOf(address(this));
            token.safeTransferFrom(msg.sender, address(this), amounts[i]);
            // Rejects fee-on-transfer / deflationary tokens even if a whitelisted token changes behaviour.
            if (token.balanceOf(address(this)) - before < amounts[i]) {
                revert TransferAmountMismatch(address(token));
            }
        }
    }

    /// @inheritdoc IIndexToken
    function redeem(uint256 shares, address to) external nonReentrant onlyInitialized {
        _redeem(shares, to, 0);
    }

    /// @inheritdoc IIndexToken
    function redeemSkipping(uint256 shares, address to, uint256 skipMask) external nonReentrant onlyInitialized {
        if (skipMask == 0 || skipMask >> _components.length != 0) revert InvalidSkipMask(skipMask);
        _redeem(shares, to, skipMask);
    }

    /// @inheritdoc IIndexToken
    function claim(address token, address to) external nonReentrant returns (uint256 amount) {
        _checkRecipient(to);
        amount = claimOf[msg.sender][token];
        if (amount == 0) revert NothingToClaim(token);

        delete claimOf[msg.sender][token];
        totalClaims[token] -= amount;
        emit Claimed(msg.sender, to, token, amount);

        IERC20(token).safeTransfer(to, amount);
    }

    /// @dev Burns first, books every skipped component as a claim, then transfers the rest.
    function _redeem(uint256 shares, address to, uint256 skipMask) private {
        if (shares == 0) revert ZeroShares();
        _checkRecipient(to);

        uint256[] memory amounts = _amounts(shares, Math.Rounding.Floor);
        _burn(msg.sender, shares);
        // `_burn` is internal (OpenZeppelin); no external call precedes this event.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Redeemed(msg.sender, to, shares, amounts);

        uint256 n = amounts.length;
        if (skipMask != 0) {
            for (uint256 i = 0; i < n; ++i) {
                uint256 amount = amounts[i];
                if (amount == 0 || (skipMask & (1 << i)) == 0) continue;
                address token = _components[i].token;
                claimOf[msg.sender][token] += amount;
                totalClaims[token] += amount;
                // forge-lint: disable-next-line(reentrancy-events)
                emit ClaimRecorded(msg.sender, token, amount);
            }
        }

        for (uint256 i = 0; i < n; ++i) {
            if (amounts[i] == 0 || (skipMask & (1 << i)) != 0) continue;
            IERC20(_components[i].token).safeTransfer(to, amounts[i]);
        }
    }

    function _checkInitialized() private view {
        if (_getInitializedVersion() != 1) revert NotInitialized();
    }

    function _checkRecipient(address to) private view {
        if (to == address(0)) revert ZeroAddress();
        if (to == address(this)) revert InvalidRecipient(to);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function componentCount() external view returns (uint256) {
        return _components.length;
    }

    /// @inheritdoc IIndexToken
    function componentTokens() external view returns (address[] memory tokens) {
        uint256 n = _components.length;
        tokens = new address[](n);
        for (uint256 i = 0; i < n; ++i) {
            tokens[i] = _components[i].token;
        }
    }

    /// @inheritdoc IIndexToken
    function components() external view returns (address[] memory tokens, uint256[] memory units) {
        uint256 n = _components.length;
        tokens = new address[](n);
        units = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            tokens[i] = _components[i].token;
            units[i] = _components[i].units;
        }
    }

    /// @inheritdoc IIndexToken
    function previewIssue(uint256 shares) external view returns (uint256[] memory amountsIn) {
        return _amounts(shares, Math.Rounding.Ceil);
    }

    /// @inheritdoc IIndexToken
    function previewRedeem(uint256 shares) external view returns (uint256[] memory amountsOut) {
        return _amounts(shares, Math.Rounding.Floor);
    }

    /// @dev Raw amount of every component corresponding to `shares`, with the given rounding.
    function _amounts(uint256 shares, Math.Rounding rounding) private view returns (uint256[] memory amounts) {
        uint256 n = _components.length;
        amounts = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            amounts[i] = Math.mulDiv(shares, _components[i].units, SHARE_UNIT, rounding);
        }
    }

    // ---------------------------------------------------------------------
    // Overrides
    // ---------------------------------------------------------------------

    function nonces(address owner) public view override(IERC20Permit, ERC20PermitUpgradeable) returns (uint256) {
        return super.nonces(owner);
    }
}
