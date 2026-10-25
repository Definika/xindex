// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

/// @dev Vendored from Wormhole's wormhole (Apache 2) at 77655c37f05f8398b9e21b3a1dd3705312e6bba2,
///      `ethereum/contracts/bridge/interfaces/ITokenBridge.sol`: the five functions `KeeperExecutor` calls on the Token
///      Bridge (Ethereum: 0x3ee18B2214AFF97000D974cf647E7C347E8fa585) and the struct one of them returns. The pragma is
///      pinned and the rest of the interface is left out.
interface ITokenBridge {
    struct TransferWithPayload {
        uint8 payloadID;
        uint256 amount;
        bytes32 tokenAddress;
        uint16 tokenChain;
        bytes32 to;
        uint16 toChain;
        bytes32 fromAddress;
        bytes payload;
    }

    function transferTokens(
        address token,
        uint256 amount,
        uint16 recipientChain,
        bytes32 recipient,
        uint256 arbiterFee,
        uint32 nonce
    ) external payable returns (uint64 sequence);

    function completeTransferWithPayload(bytes memory encodedVm) external returns (bytes memory);

    function parseTransferWithPayload(bytes memory encoded) external pure returns (TransferWithPayload memory transfer);

    function chainId() external view returns (uint16);

    function wrappedAsset(uint16 tokenChainId, bytes32 tokenAddress) external view returns (address);
}
