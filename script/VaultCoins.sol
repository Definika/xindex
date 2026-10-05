// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice The native coins of v5's vault chains with the Pyth price id and decimals each is listed with on Ethereum,
///         `vaultTokenId(chainId, 0x0)`, read from Pyth's Hermes catalogue on 2026-10-05. Decimals are the chain's
///         native unit's, in which a vault counts: wei, sun, stroops, yoctoNEAR, MIST, octas.
library VaultCoins {
    /// @dev BNB / US DOLLAR; BNB Chain, wei.
    bytes32 internal constant BNB_PRICE_ID = 0x2f95862b045670cd22bee3114c39763a4a08beeb663b145d283c31d7d1101c4f;
    uint8 internal constant BNB_DECIMALS = 18;
    /// @dev TRON / US DOLLAR; TRON, sun.
    bytes32 internal constant TRX_PRICE_ID = 0x67aed5a24fdad045475e7195c98a98aea119c763f272d4523f5bac93a4f33c2b;
    uint8 internal constant TRX_DECIMALS = 6;
    /// @dev STELLAR / US DOLLAR; Stellar, stroops.
    bytes32 internal constant XLM_PRICE_ID = 0xb7a8eba68a997cd0210c2e1e4ee811ad2d174b3611c22d9ebf16f4cb7e9ba850;
    uint8 internal constant XLM_DECIMALS = 7;
    /// @dev NEAR PROTOCOL / US DOLLAR; NEAR, yoctoNEAR.
    bytes32 internal constant NEAR_PRICE_ID = 0xc415de8d2eba7db216527dff4b60e8f3a5311c740dadb233e13e12547e226750;
    uint8 internal constant NEAR_DECIMALS = 24;
    /// @dev SUI / US DOLLAR; Sui, MIST.
    bytes32 internal constant SUI_PRICE_ID = 0x23d7315113f5b1d3ba7a83604c44b94d79f4fd69af77f804fc7f920a6dc65744;
    uint8 internal constant SUI_DECIMALS = 9;
    /// @dev INJECTIVE / US DOLLAR; Injective, the EVM's 18.
    bytes32 internal constant INJ_PRICE_ID = 0x7a5bc1d2b56ad029048cd63964b3ad2776eadf812edc1a43a31406cb54bff592;
    uint8 internal constant INJ_DECIMALS = 18;
    /// @dev VECHAIN / US DOLLAR; VeChain, wei.
    bytes32 internal constant VET_PRICE_ID = 0x1722176f738aa1aafea170f8b27724042c5ac6d8cb9cf8ae02d692b0927e0681;
    uint8 internal constant VET_DECIMALS = 18;
    /// @dev APTOS / US DOLLAR; Aptos, octas.
    bytes32 internal constant APT_PRICE_ID = 0x03ae4db29ed4ae33d323568895aa00337e658e348b37509f5372ae51f0af00d5;
    uint8 internal constant APT_DECIMALS = 8;
}
