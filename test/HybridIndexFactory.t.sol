// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {HybridIndexFactory} from "../src/HybridIndexFactory.sol";
import {HybridHub} from "../src/HybridHub.sol";
import {HybridHubExtension} from "../src/hybrid/HybridHubExtension.sol";
import {HybridHubModule} from "../src/hybrid/HybridHubModule.sol";
import {IHybridIndex} from "../src/interfaces/IHybridIndex.sol";
import {IndexHub} from "../src/IndexHub.sol";
import {IndexZap} from "../src/IndexZap.sol";
import {IIndexZap} from "../src/interfaces/IIndexZap.sol";
import {Errors} from "@openzeppelin/contracts/utils/Errors.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockUniversalRouter} from "./mocks/MockUniversalRouter.sol";
import {IHybridIndexFactory} from "../src/interfaces/IHybridIndexFactory.sol";
import {IIndexFactory} from "../src/interfaces/IIndexFactory.sol";
import {IXindexErrors} from "../src/interfaces/IXindexErrors.sol";
import {IXindexVault} from "../src/interfaces/IXindexVault.sol";
import {VaultMessages} from "../src/libraries/VaultMessages.sol";
import {MockEventVerifier} from "./mocks/MockEventVerifier.sol";
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
        HybridHubExtension ext = new HybridHubExtension(address(this));
        HybridHub stranger = new HybridHub(address(this), address(new HybridHubModule(address(this), address(ext))));
        vm.expectRevert(abi.encodeWithSelector(IHybridIndexFactory.NotFactoryTemplate.selector, address(stranger)));
        new HybridIndexFactory(owner, guardian, address(stranger));
        assertEq(factory.HYBRID_IMPLEMENTATION(), address(template));
        assertEq(factory.FREEZE_DURATION(), 14 days);
        assertEq(factory.ROTATION_DELAY(), 30 days);
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
    /// @dev FAC-1: a new state verifier decides every index's mints on its chain, as new P1 and P2 decide the vault's
    ///      payouts, so it waits as long: 30 days in public, not a listing's 2.
    function test_FAC1_aNewStateVerifierWaitsTheRotationDelay() public {
        MockStateVerifier next = new MockStateVerifier();
        vm.prank(owner);
        factory.proposeChain(chainId, _b32(address(vault)), address(next));
        uint256 eta = block.timestamp + factory.ROTATION_DELAY();
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        vm.expectRevert(abi.encodeWithSelector(IHybridIndexFactory.ChainNotReady.selector, chainId, eta));
        factory.executeChain(chainId);
        vm.warp(eta);
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

    /// @dev Only the factory's own HybridHub clones may freeze a chain on evidence; an Ethereum-only index may not.
    function test_freezeOnEvidence_onlyAHybridIndex() public {
        vm.expectRevert(abi.encodeWithSelector(IHybridIndexFactory.NotAHybridIndex.selector, address(this)));
        factory.freezeOnEvidence(chainId, true);
        address[] memory ethOnly = new address[](1);
        ethOnly[0] = address(weth);
        address plain = factory.createIndex("Eth", "ETHI", ethOnly, K);
        vm.prank(plain);
        vm.expectRevert(abi.encodeWithSelector(IHybridIndexFactory.NotAHybridIndex.selector, plain));
        factory.freezeOnEvidence(chainId, true);

        address hub = address(_createHybrid());
        vm.prank(hub);
        vm.expectRevert(abi.encodeWithSelector(IHybridIndexFactory.UnknownChain.selector, OTHER));
        factory.freezeOnEvidence(OTHER, true);
        vm.recordLogs();
        vm.expectEmit(address(factory));
        emit IHybridIndexFactory.ChainFrozen(chainId, block.timestamp + 14 days, hub);
        vm.prank(hub);
        factory.freezeOnEvidence(chainId, true);
        assertEq(factory.chainFreeze(chainId).until, block.timestamp + 14 days);
        assertEq(_message(vm.getRecordedLogs()).kind, VaultMessages.FREEZE);

        // Evidence against deposits alone stops mints, not the vault.
        vm.warp(block.timestamp + 1 days);
        vm.recordLogs();
        vm.prank(hub);
        factory.freezeOnEvidence(chainId, false);
        assertEq(factory.chainFreeze(chainId).until, block.timestamp + 14 days);
        assertEq(_message(vm.getRecordedLogs()).kind, 0, "no message to the vault");
    }

    // ---------------------------------------------------------------------
    // governance messages
    // ---------------------------------------------------------------------

    /// @dev A cap waits LISTING_DELAY, then goes to the vault; raising it needs both proofs there, as it does here.
    function test_proposeCap_reachesTheVault() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        factory.proposeCap(chainId, bytes32(0), 5e24, 1e21);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IHybridIndexFactory.UnknownChain.selector, OTHER));
        factory.proposeCap(OTHER, bytes32(0), 5e24, 1e21);

        bytes32 id = factory.vaultProposalId(chainId, VaultMessages.CAP_UPDATE, bytes32(0));
        bytes memory body = abi.encode(bytes32(0), uint256(5e24), uint256(1e21));
        vm.expectEmit(address(factory));
        emit IHybridIndexFactory.VaultProposalMade(
            id, chainId, VaultMessages.CAP_UPDATE, body, block.timestamp + 2 days
        );
        vm.prank(owner);
        assertEq(factory.proposeCap(chainId, bytes32(0), 5e24, 1e21), id);
        IHybridIndexFactory.VaultProposal memory p = factory.vaultProposal(id);
        assertEq(p.chainId, chainId);
        assertEq(p.kind, VaultMessages.CAP_UPDATE);
        assertEq(p.body, body);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IHybridIndexFactory.VaultProposalPending.selector, id, block.timestamp + 2 days)
        );
        factory.proposeCap(chainId, bytes32(0), 6e24, 1e21);
        // Another token has a proposal of its own.
        vm.prank(owner);
        factory.proposeCap(chainId, bytes32(uint256(7)), 1, 1);

        vm.expectRevert(
            abi.encodeWithSelector(IHybridIndexFactory.VaultProposalNotReady.selector, id, block.timestamp + 2 days)
        );
        factory.executeVaultProposal(id);
        vm.warp(block.timestamp + 2 days);
        vm.recordLogs();
        factory.executeVaultProposal(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(factory.vaultProposal(id).eta, 0);
        VaultMessages.Message memory m = _message(logs);
        assertEq(m.kind, VaultMessages.CAP_UPDATE);
        assertEq(m.index, address(factory));
        assertEq(m.body, body);
        _deliverAll(logs);
        assertEq(vault.cap(address(0)), 5e24);
        assertEq(vault.outflowFloor(address(0)), 1e21);
        vm.expectRevert(abi.encodeWithSelector(IHybridIndexFactory.NoVaultProposal.selector, id));
        factory.executeVaultProposal(id);
    }

    /// @dev FAC-2 and VLT-4: an older cap update delivered after a newer one never runs, so it cannot undo it.
    function test_FAC2_VLT4_anOlderCapUpdateDeliveredLastDoesNotUndoANewerOne() public {
        vm.prank(owner);
        bytes32 id = factory.proposeCap(chainId, bytes32(0), 5e24, 1e21);
        vm.warp(block.timestamp + 2 days);
        vm.recordLogs();
        factory.executeVaultProposal(id);
        Vm.Log[] memory older = vm.getRecordedLogs();
        uint256 olderNonce = factory.messageNonce();
        vm.prank(owner);
        factory.proposeCap(chainId, bytes32(0), 4e24, 1e21);
        vm.warp(block.timestamp + 2 days);
        vm.recordLogs();
        factory.executeVaultProposal(id);
        Vm.Log[] memory newer = vm.getRecordedLogs();

        _deliverAll(newer);
        assertEq(vault.cap(address(0)), 4e24);
        vm.expectRevert(abi.encodeWithSelector(IXindexVault.StaleGovernance.selector, olderNonce, olderNonce + 1));
        _deliverAll(older);
        assertEq(vault.cap(address(0)), 4e24, "the newer cap stands");
    }

    /// @dev Each proposal must be executed within PROPOSAL_WINDOW of its eta; an expired one can be replaced.
    function test_vaultProposals_expire() public {
        vm.prank(owner);
        bytes32 id = factory.proposeCap(chainId, bytes32(0), 5e24, 1e21);
        uint256 deadline = block.timestamp + 2 days + 7 days;
        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(IHybridIndexFactory.VaultProposalExpired.selector, id, deadline));
        factory.executeVaultProposal(id);
        vm.prank(owner);
        factory.proposeCap(chainId, bytes32(0), 4e24, 1e21);
        assertEq(factory.vaultProposal(id).eta, block.timestamp + 2 days);
    }

    /// @dev The freezer changes after GUARDIAN_DELAY, as the guardian does, and the guardian cannot stop it.
    function test_proposeFreezer_theGuardianCannotBlockIt() public {
        vm.prank(owner);
        vm.expectRevert(IXindexErrors.ZeroAddress.selector);
        factory.proposeFreezer(chainId, bytes32(0));
        address next = makeAddr("next freezer");
        vm.prank(owner);
        bytes32 id = factory.proposeFreezer(chainId, _b32(next));
        assertEq(factory.vaultProposal(id).eta, block.timestamp + 7 days);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.Unauthorized.selector, guardian));
        factory.cancelVaultProposal(id);

        vm.warp(block.timestamp + 7 days);
        vm.recordLogs();
        factory.executeVaultProposal(id);
        _deliverAll(vm.getRecordedLogs());
        assertEq(vault.freezer(), freezer, "the vault waits a week of its own");
        _applyChange(VaultMessages.FREEZER_CHANGE, abi.encode(_b32(next)));
        assertEq(vault.freezer(), next);
    }

    /// @dev A rotation waits 30 days, in public; the guardian or the owner can cancel it.
    function test_proposeRotation_waitsThirtyDaysAndTheGuardianMayCancel() public {
        MockEventVerifier n1 = new MockEventVerifier();
        MockEventVerifier n2 = new MockEventVerifier();
        vm.startPrank(owner);
        vm.expectRevert(IXindexErrors.ZeroAddress.selector);
        factory.proposeRotation(chainId, bytes32(0), _b32(address(n2)));
        vm.expectRevert(IXindexErrors.ZeroAddress.selector);
        factory.proposeRotation(chainId, _b32(address(n1)), bytes32(0));
        vm.expectRevert(IHybridIndexFactory.VerifiersNotDistinct.selector);
        factory.proposeRotation(chainId, _b32(address(n1)), _b32(address(n1)));
        bytes32 id = factory.proposeRotation(chainId, _b32(address(n1)), _b32(address(n2)));
        vm.stopPrank();
        assertEq(factory.vaultProposal(id).eta, block.timestamp + 30 days);

        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.Unauthorized.selector, address(this)));
        factory.cancelVaultProposal(id);
        vm.expectEmit(address(factory));
        emit IHybridIndexFactory.VaultProposalCancelled(id, guardian);
        vm.prank(guardian);
        factory.cancelVaultProposal(id);
        vm.expectRevert(abi.encodeWithSelector(IHybridIndexFactory.NoVaultProposal.selector, id));
        vm.prank(owner);
        factory.cancelVaultProposal(id);

        vm.prank(owner);
        factory.proposeRotation(chainId, _b32(address(n1)), _b32(address(n2)));
        vm.warp(block.timestamp + 30 days - 1);
        vm.expectRevert(
            abi.encodeWithSelector(IHybridIndexFactory.VaultProposalNotReady.selector, id, block.timestamp + 1)
        );
        factory.executeVaultProposal(id);
        vm.warp(block.timestamp + 1);
        bytes memory payload = _rotationPayload(n1, n2);
        vm.expectEmit(address(factory));
        emit IHybridIndexFactory.VaultProposalExecuted(id);
        vm.expectEmit(address(factory));
        emit VaultMessages.VaultMessage(keccak256(payload), payload);
        // Recording starts after the expectations, whose own emits would otherwise be recorded as logs of this test.
        vm.recordLogs();
        factory.executeVaultProposal(id);
        _deliverAll(vm.getRecordedLogs());
        _applyChange(VaultMessages.VERIFIER_ROTATION, abi.encode(_b32(address(n1)), _b32(address(n2))));
        assertEq(address(vault.p1()), address(n1));
        assertEq(address(vault.p2()), address(n2));
    }

    /// @dev The owner can cancel any of its proposals, a freezer change included.
    function test_cancelVaultProposal_byTheOwner() public {
        vm.startPrank(owner);
        bytes32 id = factory.proposeFreezer(chainId, _b32(makeAddr("next")));
        factory.cancelVaultProposal(id);
        vm.stopPrank();
        assertEq(factory.vaultProposal(id).eta, 0);
    }

    function _rotationPayload(MockEventVerifier n1, MockEventVerifier n2) internal view returns (bytes memory) {
        return VaultMessages.encode(
            VaultMessages.Message({
                sourceChainId: block.chainid,
                kind: VaultMessages.VERIFIER_ROTATION,
                destChainId: chainId,
                vault: _b32(address(vault)),
                index: address(factory),
                nonce: factory.messageNonce() + 1,
                body: abi.encode(_b32(address(n1)), _b32(address(n2)))
            })
        );
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

    /// @dev The zap the deploy script points at this factory mints and burns IndexHub clones only. A HybridHub is in the
    ///      factory's registry and answers `rebalanceNonce`, but no part of it answers `componentTokens`, so a zap call
    ///      on one reverts there with nothing moved. A hybrid index's mints are orders.
    function test_theZapCannotMintOrBurnAHybridIndex() public {
        IHybridIndex hub = _createHybrid();
        IndexZap zap = new IndexZap(factory, new MockUniversalRouter(makeAddr("poolManager")));
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        usdc.mint(holder, 1_000e6);
        vm.prank(holder);
        usdc.approve(address(zap), type(uint256).max);

        bytes memory mint = abi.encodeCall(
            IndexZap.mintWithToken,
            (IIndexZap.MintParams({
                    index: address(hub),
                    expectedNonce: 0,
                    tokenIn: address(usdc),
                    maxAmountIn: 1_000e6,
                    shares: 1e18,
                    legs: new IIndexZap.MintLeg[](2),
                    to: holder,
                    deadline: block.timestamp
                }))
        );
        bytes memory burn = abi.encodeCall(
            IndexZap.burnToToken,
            (IIndexZap.BurnParams({
                    index: address(hub),
                    expectedNonce: 0,
                    shares: 1e18,
                    tokenOut: address(usdc),
                    minAmountOut: 1,
                    legs: new IIndexZap.BurnLeg[](2),
                    to: holder,
                    deadline: block.timestamp
                }))
        );
        bytes[2] memory calls = [mint, burn];
        for (uint256 i = 0; i < 2; ++i) {
            vm.prank(holder);
            (bool ok, bytes memory ret) = address(zap).call(calls[i]);
            assertFalse(ok);
            assertEq(ret, abi.encodeWithSelector(Errors.FailedCall.selector), "the hub's delegation finds no function");
        }
        assertEq(usdc.balanceOf(holder), 1_000e6);
        assertEq(usdc.balanceOf(address(zap)), 0);
    }

    function _cloneCode(address implementation) internal pure returns (bytes memory) {
        return abi.encodePacked(hex"363d3d373d3d3d363d73", implementation, hex"5af43d82803e903d91602b57fd5bf3");
    }
}
