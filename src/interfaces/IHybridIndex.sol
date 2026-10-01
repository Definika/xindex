// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IHybridHub} from "./IHybridHub.sol";
import {IHybridHubExtension} from "./IHybridHubExtension.sol";
import {IHybridHubModule} from "./IHybridHubModule.sol";

/// @title IHybridIndex
/// @notice A HybridHub index as integrators call it: the hub's own functions, the module's, which the hub delegates to,
///         and the extension's, which the module delegates to, all at the index's address.
// For integrators, who call an index through it: nothing in src/ needs the three parts combined.
// wake-disable-next-line unused-contract
interface IHybridIndex is IHybridHub, IHybridHubModule, IHybridHubExtension {}
