// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {HybridIndexFactory} from "../src/HybridIndexFactory.sol";
import {HybridHub} from "../src/HybridHub.sol";
import {HybridHubModule} from "../src/hybrid/HybridHubModule.sol";
import {IHybridIndex} from "../src/interfaces/IHybridIndex.sol";
import {IndexHub} from "../src/IndexHub.sol";
import {IHybridIndexFactory} from "../src/interfaces/IHybridIndexFactory.sol";
import {IIndexFactory} from "../src/interfaces/IIndexFactory.sol";
import {IXindexErrors} from "../src/interfaces/IXindexErrors.sol";
import {VaultMessages} from "../src/libraries/VaultMessages.sol";
import {MockStateVerifier} from "./mocks/MockStateVerifier.sol";
import {HybridTest} from "./HybridTest.sol";

/// @notice The Stage B factory: the chain registry and its timelock, vault-token listings under Stage A's flow, the
///         chain freeze, and the template each index gets.
contract HybridIndexFactoryTest is HybridTest {
    uint256 constant OTHER = 56;
    bytes32 otherVault = bytes32(uint256(0xB5C));

    function setUp() public {
        _deployStageB();
    }

    function test_constructor_needsATemplateBuiltForIt() public {
        HybridHub stranger = new HybridHub(address(this), address(new HybridHubModule(address(this))));
        vm.expectRevert(abi.encodeWithSelector(IHybridIndexFactory.NotFactoryTemplate.selector, address(stranger)));
        new HybridIndexFactory(owner, guardian, address(stranger));
        assertEq(factory.HYBRID_IMPLEMENTATION(), address(template));
        assertEq(factory.FREEZE_DURATION(), 14 days);
    }

    // ---------------------------------------------------------------------
    // the chain registry
    // ---------------------------------------------------------------------

    function test_proposeChain_refusals() public {
        address verifier = address(stateVerifier);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        factory.proposeChain(OTHER, otherVault, verifier);
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(IHybridIndexFactory.InvalidChain.selector, 0));
        factory.proposeChain(0, otherVault, verifier);
        vm.expectRevert(IXindexErrors.ZeroAddress.selector);
        factory.proposeChain(OTHER, bytes32(0), verifier);
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.NotAContract.selector, address(0xdead)));
        factory.proposeChain(OTHER, otherVault, address(0xdead));
        vm.expectRevert(abi.encodeWithSelector(IHybridIndexFactory.VaultFixed.selector, chainId, _b32(address(vault))));
        factory.proposeChain(chainId, otherVault, verifier);

        vm.expectEmit(address(factory));
        emit IHybridIndexFactory.ChainProposed(OTHER, otherVault, verifier, block.timestamp + 2 days);
        factory.proposeChain(OTHER, otherVault, verifier);
        assertTrue(factory.chainPending(OTHER));
        vm.expectRevert(
            abi.encodeWithSelector(IHybridIndexFactory.ChainPending.selector, OTHER, block.timestamp + 2 days)
        );
        factory.proposeChain(OTHER, otherVault, verifier);
        vm.stopPrank();

        // An expired proposal can be replaced.
        vm.warp(block.timestamp + 2 days + 7 days + 1);
        assertFalse(factory.chainPending(OTHER));
        vm.prank(owner);
        factory.proposeChain(OTHER, otherVault, verifier);
    }

    function test_executeChain_timelock() public {
        vm.expectRevert(abi.encodeWithSelector(IHybridIndexFactory.NoPendingChain.selector, OTHER));
        factory.executeChain(OTHER);
        vm.prank(owner);
        factory.proposeChain(OTHER, otherVault, address(stateVerifier));
        uint256 eta = block.timestamp + 2 days;
        vm.expectRevert(abi.encodeWithSelector(IHybridIndexFactory.ChainNotReady.selector, OTHER, eta));
        factory.executeChain(OTHER);
        vm.warp(eta + 7 days + 1);
        vm.expectRevert(abi.encodeWithSelector(IHybridIndexFactory.ChainExpired.selector, OTHER, eta + 7 days));
        factory.executeChain(OTHER);

        vm.prank(owner);
        factory.proposeChain(OTHER, otherVault, address(stateVerifier));
        vm.warp(block.timestamp + 2 days);
        vm.expectEmit(address(factory));
        emit IHybridIndexFactory.ChainSet(OTHER, otherVault, address(stateVerifier));
        factory.executeChain(OTHER);
        IHybridIndexFactory.Chain memory c = factory.chain(OTHER);
        assertEq(c.vault, otherVault);
        assertEq(factory.stateVerifier(OTHER), address(stateVerifier));
        assertFalse(factory.chainPending(OTHER));
    }

    /// @dev A registered chain keeps its vault; its state verifier rotates through the same delay, and every index
    ///      reads the new one at its next proof.
    function test_theStateVerifierRotates() public {
        MockStateVerifier next = new MockStateVerifier();
        vm.prank(owner);
        factory.proposeChain(chainId, _b32(address(vault)), address(next));
        vm.warp(block.timestamp + 2 days);
        factory.executeChain(chainId);
        assertEq(factory.stateVerifier(chainId), address(next));
        assertEq(factory.chain(chainId).vault, _b32(address(vault)));
    }

    function test_cancelChain() public {
        vm.expectRevert(abi.encodeWithSelector(IHybridIndexFactory.NoPendingChain.selector, OTHER));
        vm.prank(owner);
        factory.cancelChain(OTHER);
        vm.prank(owner);
        factory.proposeChain(OTHER, otherVault, address(stateVerifier));
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.Unauthorized.selector, address(this)));
        factory.cancelChain(OTHER);
        vm.expectEmit(address(factory));
        emit IHybridIndexFactory.ChainProposalCancelled(OTHER);
        vm.prank(guardian);
        factory.cancelChain(OTHER);
        assertFalse(factory.chainPending(OTHER));
    }

    // ---------------------------------------------------------------------
    // vault tokens
    // ---------------------------------------------------------------------

    /// @dev A vault token's listing runs Stage A's flow under its id, which no contract holds and no ERC-20 listing can
    ///      take.
    function test_vaultListings() public {
        (uint256 c, bytes32 id) = factory.vaultToken(native);
        assertEq(c, chainId);
        assertEq(id, bytes32(0));
        assertEq(native.code.length, 0);
        assertTrue(factory.isWhitelisted(native));
        assertEq(factory.referenceSupply(native), BNB_SUPPLY);
        (c,) = factory.vaultToken(address(weth));
        assertEq(c, 0, "an Ethereum token");

        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(IHybridIndexFactory.UnknownChain.selector, OTHER));
        factory.proposeVaultListing(OTHER, bytes32(0), 1e18);
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.AlreadyListed.selector, native));
        factory.proposeVaultListing(chainId, bytes32(0), BNB_SUPPLY);
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.NotAContract.selector, native));
        factory.proposeListing(native, BNB_SUPPLY);

        bytes32 cake = bytes32(uint256(uint160(makeAddr("CAKE"))));
        address cakeId = factory.vaultTokenId(chainId, cake);
        vm.expectEmit(address(factory));
        emit IHybridIndexFactory.VaultTokenRegistered(cakeId, chainId, cake);
        factory.proposeVaultListing(chainId, cake, 1e24);
        factory.cancelListing(cakeId);
        vm.recordLogs();
        factory.proposeVaultListing(chainId, cake, 1e24); // registered once: only the listing is proposed again
        assertEq(vm.getRecordedLogs().length, 1);
        vm.stopPrank();

        // Weekly supply batches take vault tokens like any other.
        address[] memory tokens = new address[](1);
        uint256[] memory supplies = new uint256[](1);
        (tokens[0], supplies[0]) = (native, BNB_SUPPLY + BNB_SUPPLY / 1000);
        vm.prank(owner);
        factory.proposeSupplies(tokens, supplies);
        vm.warp(block.timestamp + 2 days);
        factory.executeSupplies();
        assertEq(factory.referenceSupply(native), supplies[0]);
    }

    // ---------------------------------------------------------------------
    // freeze
    // ---------------------------------------------------------------------

    function test_freezeChain() public {
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.Unauthorized.selector, address(this)));
        factory.freezeChain(chainId);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(IHybridIndexFactory.UnknownChain.selector, OTHER));
        factory.freezeChain(OTHER);

        vm.recordLogs();
        vm.prank(owner);
        factory.freezeChain(chainId);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        IHybridIndexFactory.Freeze memory f = factory.chainFreeze(chainId);
        assertEq(f.start, block.timestamp);
        assertEq(f.until, block.timestamp + 14 days);
        VaultMessages.Message memory m = _message(logs);
        assertEq(m.kind, VaultMessages.FREEZE);
        assertEq(m.index, address(factory));
        assertEq(m.vault, _b32(address(vault)));
        assertEq(m.nonce, 1);
        assertEq(factory.messageNonce(), 1);
        _deliverAll(logs);
        assertEq(vault.frozenUntil(), block.timestamp + 14 days);
    }

    // ---------------------------------------------------------------------
    // templates
    // ---------------------------------------------------------------------

    /// @dev An index of Ethereum tokens only is Stage A's IndexHub, exactly; one holding a vault token is a HybridHub.
    function test_eachIndexGetsItsTemplate() public {
        address[] memory ethOnly = new address[](1);
        ethOnly[0] = address(weth);
        address predicted = factory.predictIndexAddress(address(this), "Eth", "ETHI", ethOnly, K);
        address plain = factory.createIndex("Eth", "ETHI", ethOnly, K);
        assertEq(plain, predicted);
        assertEq(IndexHub(plain).FACTORY(), address(factory));
        assertEq(factory.indexSalt(plain), bytes32(0), "only a hybrid index records its salt");
        assertEq(keccak256(plain.code), keccak256(_cloneCode(factory.IMPLEMENTATION())));

        address[] memory mixed = new address[](2);
        (mixed[0], mixed[1]) = (address(weth), native);
        predicted = factory.predictIndexAddress(address(this), "Hybrid", "HYB", mixed, K);
        address hybrid = factory.createIndex("Hybrid", "HYB", mixed, K);
        assertEq(hybrid, predicted);
        assertEq(keccak256(hybrid.code), keccak256(_cloneCode(address(template))));
        assertTrue(factory.isIndex(hybrid));
        vault.registerIndex(hybrid, factory.indexSalt(hybrid));
        assertTrue(vault.isIndex(hybrid), "the vault recognises the factory's clone");

        address[] memory vaultOnly = new address[](1);
        vaultOnly[0] = native;
        address pure_ = factory.createIndex("BNB", "XBNB", vaultOnly, K);
        (uint256[] memory ids,) = IHybridIndex(pure_).chains();
        assertEq(ids[0], chainId);
    }

    function _cloneCode(address implementation) internal pure returns (bytes memory) {
        return abi.encodePacked(hex"363d3d373d3d3d363d73", implementation, hex"5af43d82803e903d91602b57fd5bf3");
    }
}
