// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IWeightedIndexFactory} from "xindex/src/interfaces/IWeightedIndexFactory.sol";
import {IMintRequests} from "xindex/src/interfaces/IMintRequests.sol";
import {WeightedIndexFactory} from "xindex/src/WeightedIndexFactory.sol";
import {WeightedMath} from "xindex/src/WeightedMath.sol";
import {MintRequests} from "xindex/src/MintRequests.sol";
import {MainnetAddresses as A} from "xindex/script/MainnetAddresses.sol";
import {ForkAddresses as F} from "xindex/test/fork/ForkAddresses.sol";
import {KeeperExecutor} from "../src/KeeperExecutor.sol";
import {ITokenBridge} from "../src/interfaces/ITokenBridge.sol";
import {IV3SwapRouter} from "../src/interfaces/IV3SwapRouter.sol";

/// @dev Wormhole's core contract, as far as this test reads and overrides it.
interface IWormholeCore {
    struct GuardianSet {
        address[] keys;
        uint32 expirationTime;
    }

    function getCurrentGuardianSetIndex() external view returns (uint32);
    function getGuardianSet(uint32 index) external view returns (GuardianSet memory);
    function messageFee() external view returns (uint256);
}

/// @dev The Token Bridge's views this test needs beyond the executor's interface.
interface ITokenBridgeViews {
    struct Transfer {
        uint8 payloadID;
        uint256 amount;
        bytes32 tokenAddress;
        uint16 tokenChain;
        bytes32 to;
        uint16 toChain;
        uint256 fee;
    }

    function wormhole() external view returns (IWormholeCore);
    function bridgeContracts(uint16 chain) external view returns (bytes32);
    function encodeTransferWithPayload(ITokenBridge.TransferWithPayload memory transfer)
        external
        pure
        returns (bytes memory);
    function parseTransfer(bytes memory encoded) external pure returns (Transfer memory);
}

/// @dev The executor's restock against Wormhole's real Token Bridge on a mainnet fork. No guardian signs for a test, so
///      the fork's current guardian set is replaced by one test key, which the core then accepts as a quorum of one;
///      the bridge, its registered Avalanche emitter, the wrapped AVAX and the core's checks are all the real ones.
contract KeeperExecutorForkTest is Test {
    /// @dev Wormhole's chain id for Avalanche, AVAX's copy's home.
    uint16 constant AVALANCHE = 6;
    /// @dev WAVAX on Avalanche, the source the bridge wraps as `A.AVAX`.
    bytes32 constant AVAX_SOURCE = bytes32(uint256(uint160(0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7)));
    /// @dev The core's storage slot of its guardian sets mapping (Wormhole's `State`: provider takes slots 0 and 1).
    uint256 constant GUARDIAN_SETS_SLOT = 2;
    bytes32 constant HOME_WALLET = bytes32(uint256(0xbee));

    ITokenBridge bridge = ITokenBridge(A.WORMHOLE_TOKEN_BRIDGE);
    IWormholeCore core;
    KeeperExecutor executor;
    Vm.Wallet guardian;
    address execOwner = makeAddr("execOwner");
    address treasury = makeAddr("treasury");
    uint64 sequence = 1;

    function setUp() public {
        string memory url = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 forkBlock = vm.envOr("FORK_BLOCK", F.FORK_BLOCK);
        try vm.createSelectFork(url, forkBlock) returns (uint256) {}
        catch {
            revert(
                string.concat(
                    "MAINNET_RPC_URL cannot serve block ",
                    vm.toString(forkBlock),
                    ": use an archive node, set FORK_BLOCK near the chain head, or run forge test --no-match-path 'test/*.fork.t.sol'"
                )
            );
        }
        core = ITokenBridgeViews(address(bridge)).wormhole();
        guardian = vm.createWallet("guardian");
        _installGuardian(guardian.addr);

        WeightedIndexFactory factory =
            new WeightedIndexFactory(execOwner, makeAddr("guardian role"), address(0), address(new WeightedMath()));
        MintRequests requests = new MintRequests(address(factory), A.USDC, A.USDT);
        executor = new KeeperExecutor(
            IV3SwapRouter(F.SWAP_ROUTER_02),
            A.USDC,
            IWeightedIndexFactory(address(factory)),
            IMintRequests(address(requests)),
            bridge,
            execOwner,
            makeAddr("keeper")
        );
        vm.startPrank(execOwner);
        executor.setTreasury(treasury);
        executor.setHomeRecipient(AVALANCHE, A.AVAX, HOME_WALLET);
        executor.setRestockAllowance(A.AVAX, 100e18); // RS-1: the restocking the owner allows
        vm.stopPrank();
    }

    /// @dev Makes `key` the whole current guardian set, after checking the slot against the core's own getter.
    function _installGuardian(address key) internal {
        uint32 index = core.getCurrentGuardianSetIndex();
        bytes32 set = keccak256(abi.encode(uint256(index), GUARDIAN_SETS_SLOT));
        assertEq(uint256(vm.load(address(core), set)), core.getGuardianSet(index).keys.length, "the slot is the set's");
        vm.store(address(core), set, bytes32(uint256(1)));
        vm.store(address(core), keccak256(abi.encode(set)), bytes32(uint256(uint160(key))));
        assertEq(core.getGuardianSet(index).keys[0], key);
    }

    /// @dev A transfer of `normalized` AVAX, in the bridge's eight decimals, from Avalanche's registered bridge to `to`,
    ///      with a payload, signed by the test guardian.
    function _signedTransfer(uint256 normalized, address to) internal returns (bytes memory) {
        bytes memory payload = ITokenBridgeViews(address(bridge))
            .encodeTransferWithPayload(
                ITokenBridge.TransferWithPayload({
                    payloadID: 3,
                    amount: normalized,
                    tokenAddress: AVAX_SOURCE,
                    tokenChain: AVALANCHE,
                    to: bytes32(uint256(uint160(to))),
                    toChain: 2,
                    fromAddress: bytes32(uint256(0xf00)),
                    payload: hex"01"
                })
            );
        bytes memory body = abi.encodePacked(
            uint32(block.timestamp),
            uint32(0),
            AVALANCHE,
            ITokenBridgeViews(address(bridge)).bridgeContracts(AVALANCHE),
            sequence++,
            uint8(15),
            payload
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(guardian, keccak256(abi.encodePacked(keccak256(body))));
        return abi.encodePacked(uint8(1), core.getCurrentGuardianSetIndex(), uint8(1), uint8(0), r, s, v - 27, body);
    }

    function testFork_aBridgedTransferArrivesAndIsCredited() public {
        assertEq(bridge.wrappedAsset(AVALANCHE, AVAX_SOURCE), A.AVAX, "the bridge's AVAX is the listed copy");
        bytes memory signed = _signedTransfer(100e8, address(executor));

        vm.expectRevert(bytes("invalid sender")); // only the recipient completes a payload transfer
        vm.prank(treasury);
        ITokenBridge(address(bridge)).completeTransferWithPayload(signed);

        vm.prank(treasury);
        uint256 amount = executor.redeemBridged(signed, A.AVAX);
        assertEq(amount, 100e18, "100 AVAX, from eight decimals to the copy's 18");
        assertEq(IERC20(A.AVAX).balanceOf(address(executor)), 100e18);
        assertEq(executor.stockAllowance(A.AVAX), 100e18);
        assertEq(executor.restockAllowance(A.AVAX), 0, "the credit spent the owner's restock allowance");

        vm.expectRevert(bytes("transfer already completed"));
        vm.prank(treasury);
        executor.redeemBridged(signed, A.AVAX);
    }

    function testFork_aTransferOfAnotherTokenIsRefused() public {
        bytes memory signed = _signedTransfer(1e8, address(executor));
        vm.expectRevert(abi.encodeWithSelector(KeeperExecutor.WrongToken.selector, A.AERO, A.AVAX));
        vm.prank(treasury);
        executor.redeemBridged(signed, A.AERO);
    }

    /// @dev Bridging out burns the copy and publishes a plain transfer to the owner's recipient on Avalanche.
    function testFork_bridgeOutPublishesATransferToThePinnedRecipient() public {
        bytes memory signed = _signedTransfer(100e8, address(executor));
        vm.prank(treasury);
        executor.redeemBridged(signed, A.AVAX);
        uint256 supply = IERC20(A.AVAX).totalSupply();
        uint256 fee = core.messageFee();
        vm.deal(treasury, fee);

        vm.recordLogs();
        vm.prank(treasury);
        executor.bridgeOut{value: fee}(A.AVAX, 40e18, AVALANCHE);
        assertEq(IERC20(A.AVAX).balanceOf(address(executor)), 60e18);
        assertEq(IERC20(A.AVAX).totalSupply(), supply - 40e18, "the copy is burned");
        assertEq(executor.stockAllowance(A.AVAX), 60e18, "capped at what is left");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 published = keccak256("LogMessagePublished(address,uint64,uint32,bytes,uint8)");
        bool found;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != address(core) || logs[i].topics[0] != published) continue;
            (,, bytes memory payload,) = abi.decode(logs[i].data, (uint64, uint32, bytes, uint8));
            ITokenBridgeViews.Transfer memory t = ITokenBridgeViews(address(bridge)).parseTransfer(payload);
            assertEq(t.payloadID, 1);
            assertEq(t.amount, 40e8);
            assertEq(t.tokenAddress, AVAX_SOURCE);
            assertEq(t.tokenChain, AVALANCHE);
            assertEq(t.to, HOME_WALLET, "to the owner's recipient");
            assertEq(t.toChain, AVALANCHE);
            assertEq(t.fee, 0);
            found = true;
        }
        assertTrue(found, "the core published the transfer");
    }
}
