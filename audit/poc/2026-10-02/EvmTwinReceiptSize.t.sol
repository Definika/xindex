// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {EthereumFinalityVerifier} from "../src/verifiers/EthereumFinalityVerifier.sol";
import {FinalityVerifier} from "../src/verifiers/FinalityVerifier.sol";
import {ISP1Verifier} from "../src/interfaces/ISP1Verifier.sol";

contract AcceptAll is ISP1Verifier {
    function verifyProof(bytes32, bytes calldata, bytes calldata) external pure {}
}

/// THROWAWAY: the EVM twin accepts the receipts P1 on Solana cannot verify.
contract TwinTest {
    function _prefix(uint256 base, uint256 len) internal pure returns (bytes memory) {
        if (len < 56) return abi.encodePacked(uint8(base + len));
        uint256 n = 0;
        for (uint256 l = len; l > 0; l >>= 8) ++n;
        bytes memory b = new bytes(n);
        for (uint256 i = 0; i < n; ++i) b[n - 1 - i] = bytes1(uint8(len >> (8 * i)));
        return abi.encodePacked(uint8(base + 55 + n), b);
    }

    function _str(bytes memory b) internal pure returns (bytes memory) {
        if (b.length == 1 && uint8(b[0]) < 0x80) return b;
        return abi.encodePacked(_prefix(0x80, b.length), b);
    }

    function _list(bytes memory payload) internal pure returns (bytes memory) {
        return abi.encodePacked(_prefix(0xc0, payload.length), payload);
    }

    address constant EMITTER = address(0xABaBaBaBABabABabAbAbABAbABabababaBaBABaB);

    function _receipt(uint256 junkLogs, uint256 junkData) internal pure returns (bytes memory) {
        bytes memory logs = _list(
            abi.encodePacked(
                _str(abi.encodePacked(EMITTER)),
                _list(
                    abi.encodePacked(
                        _str(abi.encodePacked(bytes32(uint256(1)))), _str(abi.encodePacked(bytes32(uint256(2))))
                    )
                ),
                _str(hex"33")
            )
        );
        bytes memory junk = _list(abi.encodePacked(_str(abi.encodePacked(address(0xeE))), _list(""), _str("")));
        bytes memory all = logs;
        for (uint256 i = 0; i < junkLogs; ++i) {
            all = abi.encodePacked(all, junk);
        }
        if (junkData > 0) {
            all = abi.encodePacked(
                all, _list(abi.encodePacked(_str(abi.encodePacked(address(0xeE))), _list(""), _str(new bytes(junkData))))
            );
        }
        bytes memory body = _list(abi.encodePacked(_str(hex"01"), _str(hex"010000"), _str(new bytes(256)), _list(all)));
        return abi.encodePacked(hex"02", body);
    }

    function _check(uint256 junkLogs, uint256 junkData) internal returns (uint256 nodeLength, uint256 gasUsed) {
        bytes memory node = _list(abi.encodePacked(_str(hex"2080"), _str(_receipt(junkLogs, junkData))));
        bytes32 receiptsRoot = keccak256(node);
        uint64 number = 100;
        bytes32 leaf = keccak256(abi.encode(uint256(number), uint256(1), bytes32(0), receiptsRoot));
        EthereumFinalityVerifier v =
            new EthereumFinalityVerifier(new AcceptAll(), bytes32(uint256(7)), bytes32(uint256(8)), 1);
        v.update(abi.encode(bytes32(uint256(8)), bytes32(uint256(9)), uint64(2), leaf, number, number), "");
        bytes[] memory nodes = new bytes[](1);
        nodes[0] = node;
        FinalityVerifier.Header memory h = FinalityVerifier.Header({
            headersRoot: leaf,
            number: number,
            timestamp: 1,
            stateRoot: bytes32(0),
            receiptsRoot: receiptsRoot,
            path: new bytes32[](0)
        });
        bytes memory proof = abi.encode(h, nodes, uint256(0), uint256(0));
        uint256 g = gasleft();
        (uint256 blockNumber, address emitter, bytes32 t0, bytes32 t1,) = v.verifyEvent(proof);
        gasUsed = g - gasleft();
        require(blockNumber == number && emitter == EMITTER, "log");
        require(t0 == bytes32(uint256(1)) && t1 == bytes32(uint256(2)), "topics");
        nodeLength = node.length;
    }

    event Measured(uint256 junkLogs, uint256 junkData, uint256 nodeLength, uint256 gasUsed);

    function test_twinAcceptsAReceiptOf513Logs() public {
        (uint256 len, uint256 gasUsed) = _check(512, 0);
        emit Measured(512, 0, len, gasUsed);
    }

    /// What the griefer pays on Ethereum to pad a receipt: 512 empty LOG0s, or one LOG0 of 65,536 bytes.
    function test_costOfPadding() public {
        uint256 g = gasleft();
        assembly {
            for { let i := 0 } lt(i, 512) { i := add(i, 1) } { log0(0, 0) }
        }
        emit Measured(512, 0, 0, g - gasleft());
        bytes memory big = new bytes(65_536);
        g = gasleft();
        assembly {
            log0(add(big, 32), mload(big))
        }
        emit Measured(0, 65_536, 0, g - gasleft());
    }

    function test_twinAcceptsAReceiptPast64KB() public {
        (uint256 len, uint256 gasUsed) = _check(0, 70_000);
        require(len > type(uint16).max, "size");
        emit Measured(0, 70_000, len, gasUsed);
    }
}
