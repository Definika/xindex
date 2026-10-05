// Copyright 2025 Pyth Data Association.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// SPDX-License-Identifier: Apache-2.0

pragma solidity 0.8.28;

// Vendored from pyth-network/pyth-crosschain (Apache-2.0) at 2bb0eb54b2b3af8854d0c26f3884c28a0fce0802,
// `target_chains/ethereum/sdk/solidity/IPythEvents.sol`, with the pragma pinned and the whitespace `forge fmt` writes.

/// @title IPythEvents contains the events that Pyth contract emits.
/// @dev This interface can be used for listening to the updates for off-chain and testing purposes.
interface IPythEvents {
    /// @dev Emitted when the price feed with `id` has received a fresh update.
    /// @param id The Pyth Price Feed ID.
    /// @param publishTime Publish time of the given price update.
    /// @param price Price of the given price update.
    /// @param conf Confidence interval of the given price update.
    // Pyth's own events, vendored with its interface: Pyth emits them, so nothing here does.
    // wake-disable-next-line unused-event
    event PriceFeedUpdate(bytes32 indexed id, uint64 publishTime, int64 price, uint64 conf);

    /// @dev Emitted when the TWAP price feed with `id` has received a fresh update.
    /// @param id The Pyth Price Feed ID.
    /// @param startTime Start time of the TWAP.
    /// @param endTime End time of the TWAP.
    /// @param twapPrice Price of the TWAP.
    /// @param twapConf Confidence interval of the TWAP.
    /// @param downSlotsRatio Down slot ratio of the TWAP.
    // wake-disable-next-line unused-event
    event TwapPriceFeedUpdate(
        bytes32 indexed id, uint64 startTime, uint64 endTime, int64 twapPrice, uint64 twapConf, uint32 downSlotsRatio
    );
}
