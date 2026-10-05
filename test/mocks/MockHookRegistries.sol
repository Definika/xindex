// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice The part of the ERC-1820 registry `CheckToken` reads: who implements an interface for an account. Etched at
///         the registry's address, where an ERC-777 token registers itself as the implementer of `ERC777Token`.
contract MockERC1820Registry {
    mapping(address account => mapping(bytes32 interfaceHash => address)) internal _implementers;

    function setInterfaceImplementer(address account, bytes32 interfaceHash, address implementer) external {
        _implementers[account][interfaceHash] = implementer;
    }

    function getInterfaceImplementer(address account, bytes32 interfaceHash) external view returns (address) {
        return _implementers[account][interfaceHash];
    }
}

/// @notice A token that declares ERC-1363 by ERC-165, as a token with `transferAndCall` callbacks does; or, built to
///         answer everything, a token whose ERC-165 answers mean nothing, which the standard's detection discounts.
contract MockERC1363Token is ERC20 {
    bool public immutable ANSWERS_EVERYTHING;

    constructor(bool answersEverything) ERC20("Callback Token", "CB1363") {
        ANSWERS_EVERYTHING = answersEverything;
    }

    function supportsInterface(bytes4 interfaceId) external view returns (bool) {
        return ANSWERS_EVERYTHING || interfaceId == 0x01ffc9a7 || interfaceId == 0xb0202a11;
    }
}
