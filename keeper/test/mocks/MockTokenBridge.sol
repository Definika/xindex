// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ITokenBridge} from "../../src/interfaces/ITokenBridge.sol";

/// @dev Wormhole's Token Bridge, as far as the executor uses it, with the real bridge's rules that matter to it: an
///      amount crosses in eight decimals (what is below them stays with the sender, and the transfer's `amount` is the
///      normalized one), a transfer with a payload completes only for its recipient, and each completes once. A
///      "signed transfer" is the ABI encoding of the transfer itself, since no guardian signs here. Completed coins
///      come out of this contract's own balance, which a test funds.
contract MockTokenBridge is ITokenBridge {
    uint16 public constant CHAIN = 2;
    uint256 public messageFee;
    uint64 public nextSequence;
    mapping(uint16 chain => mapping(bytes32 tokenAddress => address token)) public wrapped;
    mapping(bytes32 hash => bool) public completed;

    struct Sent {
        address token;
        uint256 amount;
        uint16 chain;
        bytes32 recipient;
        uint256 value;
    }

    Sent public last;

    /// @dev The real bridge's error for a payload transfer completed by someone other than its recipient.
    error InvalidSender();
    error TransferCompleted();
    error WrongFee(uint256 value);

    function setWrapped(uint16 chain, bytes32 tokenAddress, address token) external {
        wrapped[chain][tokenAddress] = token;
    }

    function setMessageFee(uint256 fee) external {
        messageFee = fee;
    }

    function transferTokens(address token, uint256 amount, uint16 recipientChain, bytes32 recipient, uint256, uint32)
        external
        payable
        returns (uint64 sequence)
    {
        if (msg.value != messageFee) revert WrongFee(msg.value);
        uint256 carried = _deNormalize(_normalize(amount, token), token);
        SafeERC20.safeTransferFrom(IERC20(token), msg.sender, address(this), carried);
        last = Sent(token, carried, recipientChain, recipient, msg.value);
        sequence = nextSequence++;
    }

    function completeTransferWithPayload(bytes memory encodedVm) external returns (bytes memory) {
        bytes32 hash = keccak256(encodedVm);
        if (completed[hash]) revert TransferCompleted();
        completed[hash] = true;
        TransferWithPayload memory t = abi.decode(encodedVm, (TransferWithPayload));
        address to = address(uint160(uint256(t.to)));
        if (msg.sender != to) revert InvalidSender();
        address token =
            t.tokenChain == CHAIN ? address(uint160(uint256(t.tokenAddress))) : wrapped[t.tokenChain][t.tokenAddress];
        SafeERC20.safeTransfer(IERC20(token), to, _deNormalize(t.amount, token));
        return encodedVm;
    }

    function parseTransferWithPayload(bytes memory encoded) external pure returns (TransferWithPayload memory) {
        return abi.decode(encoded, (TransferWithPayload));
    }

    function chainId() external pure returns (uint16) {
        return CHAIN;
    }

    function wrappedAsset(uint16 tokenChainId, bytes32 tokenAddress) external view returns (address) {
        return wrapped[tokenChainId][tokenAddress];
    }

    /// @dev A signed transfer of `amount` raw units of `token`, from `tokenChain`'s `tokenAddress`, to `to` on Ethereum.
    function vm(uint16 tokenChain, bytes32 tokenAddress, address token, uint256 amount, address to)
        external
        view
        returns (bytes memory)
    {
        return abi.encode(
            TransferWithPayload({
                payloadID: 3,
                amount: _normalize(amount, token),
                tokenAddress: tokenAddress,
                tokenChain: tokenChain,
                to: bytes32(uint256(uint160(to))),
                toChain: CHAIN,
                fromAddress: bytes32(uint256(1)),
                payload: hex"01"
            })
        );
    }

    function _normalize(uint256 amount, address token) private view returns (uint256) {
        uint8 decimals = IERC20Metadata(token).decimals();
        return decimals > 8 ? amount / 10 ** (decimals - 8) : amount;
    }

    function _deNormalize(uint256 amount, address token) private view returns (uint256) {
        uint8 decimals = IERC20Metadata(token).decimals();
        return decimals > 8 ? amount * 10 ** (decimals - 8) : amount;
    }
}
