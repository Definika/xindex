// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {WeightedIndexFactory} from "../../src/WeightedIndexFactory.sol";
import {IWeightedIndexFactory} from "../../src/interfaces/IWeightedIndexFactory.sol";
import {IWeightedHub} from "../../src/interfaces/IWeightedHub.sol";
import {IIndexHub} from "../../src/interfaces/IIndexHub.sol";
import {IRebalanceExecutor} from "../../src/interfaces/IRebalanceExecutor.sol";
import {Listings} from "../../script/Listings.sol";
import {BaseAddresses as B} from "../../script/BaseAddresses.sol";

interface IWrappedEther {
    function deposit() external payable;
}

/// @notice The executor of the rebalance the simulation fills, deployed inside it: it names the units and pays the index
///         what the callback asks from its own balance.
contract NodeExecutor is IRebalanceExecutor {
    function fill(address index, uint256[] calldata newUnits) external {
        IWeightedHub(index).executeRebalance(newUnits, "");
    }

    function onXindexRebalance(uint256[] calldata, uint256[] calldata amountsIn, bytes calldata) external {
        address[] memory tokens = IIndexHub(msg.sender).componentTokens();
        for (uint256 i = 0; i < tokens.length; ++i) {
            if (amountsIn[i] != 0) require(IERC20(tokens[i]).transfer(msg.sender, amountsIn[i]), "pay");
        }
    }
}

/// @notice Coinbase's stock tokens on Base, driven on Base's own node. Each is a B20 token: a precompile of the chain
///         at a fixed address whose only code is the byte 0xef, so the EVM a fork test runs in cannot execute one, and
///         a call to it there fails. Nothing here executes a token locally. Every read is an `eth_call` the node
///         answers, and the index's whole life is one `eth_simulateV1` request the node runs on top of the forked
///         block, under the rules Base runs that day: the factory of this build deployed from its creation code, WETH
///         and the ten stocks listed through its timelock, which reads each token's decimals from the precompile, an
///         index of all eleven created, issued in kind from tokens real holders send, rebalanced by an executor that
///         pays the stocks in, and redeemed. Each call carries less gas than one transaction on Base may.
///         Skips when BASE_RPC_URL is unset; the node must serve `eth_simulateV1`.
///         Run: BASE_RPC_URL=... forge test --match-path 'test/fork/BaseStocks.fork.t.sol' -vvv
contract BaseStocksForkTest is Test {
    /// @dev Block the fork pins to; BASE_FORK_BLOCK overrides it for a non-archive RPC that only serves recent state.
    ///      The suite passed whole here on 2026-11-22.
    uint256 constant FORK_BLOCK = 60_529_140;
    /// @dev The gas a simulated call may use. The widest, the factory's deployment, gets less than the 16,777,216 a
    ///      transaction on Base is held to; the simulated blocks keep Base's own limit, so each block's calls fit one.
    uint256 constant DEPLOY_GAS = 16_000_000;
    uint256 constant WIDE_GAS = 6_000_000;
    uint256 constant CALL_GAS = 200_000;

    /// @dev The factory's `LISTING_DELAY`, which the simulation waits out between its first two blocks.
    uint256 constant LISTING_DELAY = 2 days;

    uint256 constant STOCKS = 10;
    uint256 constant LEGS = STOCKS + 1;
    /// @dev One thousandth of an ether and one hundredth of each stock per index token; the stocks have 8 decimals.
    uint256 constant U_WETH = 1e15;
    uint256 constant U_STOCK = 1e6;
    uint256 constant SHARES = 10e18;

    // Accounts of the simulation, none of which exists on Base: the node signs for nobody (`validation: false`).
    address constant DEPLOYER = address(uint160(uint256(keccak256("xindex.base-stocks.deployer"))));
    address constant OWNER = address(uint160(uint256(keccak256("xindex.base-stocks.owner"))));
    address constant CREATOR = address(uint160(uint256(keccak256("xindex.base-stocks.creator"))));
    address constant MINTER = address(uint160(uint256(keccak256("xindex.base-stocks.minter"))));
    address constant EXECUTOR_DEPLOYER = address(uint160(uint256(keccak256("xindex.base-stocks.executor-deployer"))));

    struct Step {
        string what;
        address from;
        address to;
        bool create;
        bytes data;
        uint256 value;
        uint256 gas;
        uint256 blk;
    }

    /// @dev The simulation's steps in order, each with the block it runs in, and that block's timestamp.
    Step[] steps;
    uint256[] times;

    function setUp() public {
        string memory url = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 forkBlock = vm.envOr("BASE_FORK_BLOCK", FORK_BLOCK);
        try vm.createSelectFork(url, forkBlock) returns (uint256) {}
        catch {
            revert(
                string.concat(
                    "BASE_RPC_URL cannot serve block ",
                    vm.toString(forkBlock),
                    ": use an archive node, set BASE_FORK_BLOCK near the chain head, or run forge test --no-match-path 'test/fork/*'"
                )
            );
        }
        assertEq(block.chainid, B.CHAIN_ID, "BASE_RPC_URL is a Base node");
    }

    // ---------------------------------------------------------------------
    // The node
    // ---------------------------------------------------------------------

    /// @dev `v` as a JSON-RPC quantity: hex without leading zeros.
    function _hex(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0x0";
        bytes memory digits = "0123456789abcdef";
        uint256 length = 0;
        for (uint256 rest = v; rest != 0; rest >>= 4) {
            ++length;
        }
        bytes memory out = new bytes(length + 2);
        out[0] = "0";
        out[1] = "x";
        for (uint256 i = length + 1; i > 1; --i) {
            out[i] = digits[v & 0xf];
            v >>= 4;
        }
        return string(out);
    }

    /// @dev What the node answers to a read of `to` at the forked block.
    function _read(address to, bytes memory data) internal returns (bytes memory) {
        return vm.rpc(
            "eth_call",
            string.concat(
                '[{"to":"', vm.toString(to), '","data":"', vm.toString(data), '"},"', _hex(block.number), '"]'
            )
        );
    }

    /// @dev Queues a call of `to` by `from` with CALL_GAS; returns its step.
    function _push(string memory what, address from, address to, bytes memory data) internal returns (uint256 at) {
        return _push(what, from, to, data, 0, CALL_GAS);
    }

    /// @dev Queues a call that does an index's work, with WIDE_GAS; returns its step.
    function _wide(string memory what, address from, address to, bytes memory data) internal returns (uint256 at) {
        return _push(what, from, to, data, 0, WIDE_GAS);
    }

    function _push(string memory what, address from, address to, bytes memory data, uint256 value, uint256 gas)
        internal
        returns (uint256 at)
    {
        at = steps.length;
        steps.push(
            Step({
                what: what, from: from, to: to, create: false, data: data, value: value, gas: gas, blk: times.length - 1
            })
        );
    }

    function _create(string memory what, address from, bytes memory initcode, uint256 gas) internal {
        steps.push(
            Step({
                what: what,
                from: from,
                to: address(0),
                create: true,
                data: initcode,
                value: 0,
                gas: gas,
                blk: times.length - 1
            })
        );
    }

    function _stepJson(Step storage s) internal view returns (string memory) {
        string memory to = s.create ? "" : string.concat('"to":"', vm.toString(s.to), '",');
        return string.concat(
            '{"from":"',
            vm.toString(s.from),
            '",',
            to,
            '"data":"',
            vm.toString(s.data),
            '","value":"',
            _hex(s.value),
            '","gas":"',
            _hex(s.gas),
            '"}'
        );
    }

    /// @dev Runs the steps on the node, one simulated block per entry of `times`, on top of the forked block, with
    ///      MINTER holding ether. Returns the node's answer.
    function _simulate() internal returns (string memory json) {
        string memory blocks = "";
        for (uint256 b = 0; b < times.length; ++b) {
            string memory calls = "";
            for (uint256 i = 0; i < steps.length; ++i) {
                if (steps[i].blk != b) continue;
                calls = string.concat(calls, bytes(calls).length == 0 ? "" : ",", _stepJson(steps[i]));
            }
            blocks = string.concat(
                blocks,
                b == 0 ? "" : ",",
                '{"blockOverrides":{"time":"',
                _hex(times[b]),
                '"},"stateOverrides":{"',
                vm.toString(MINTER),
                '":{"balance":"',
                _hex(100 ether),
                '"}},"calls":[',
                calls,
                "]}"
            );
        }
        return vm.rpcJson(
            "eth_simulateV1",
            string.concat('[{"blockStateCalls":[', blocks, '],"validation":false},"', _hex(block.number), '"]')
        );
    }

    /// @dev Where step `at` sits in the node's answer: its block, and its place among that block's calls.
    function _path(uint256 at) internal view returns (string memory) {
        uint256 place = 0;
        for (uint256 i = 0; i < at; ++i) {
            if (steps[i].blk == steps[at].blk) ++place;
        }
        return string.concat(".[", vm.toString(steps[at].blk), "].calls[", vm.toString(place), "]");
    }

    /// @dev Every step succeeded on the node; a failure is reported with the step and the node's reason.
    function _assertAllSucceeded(string memory json) internal view {
        for (uint256 i = 0; i < steps.length; ++i) {
            string memory path = _path(i);
            if (vm.parseJsonUint(json, string.concat(path, ".status")) == 1) continue;
            revert(
                string.concat(
                    "the node failed: ",
                    steps[i].what,
                    ": ",
                    vm.parseJsonString(json, string.concat(path, ".error.message")),
                    " ",
                    vm.toString(vm.parseJsonBytes(json, string.concat(path, ".returnData")))
                )
            );
        }
    }

    function _answer(string memory json, uint256 at) internal view returns (bytes memory) {
        return vm.parseJsonBytes(json, string.concat(_path(at), ".returnData"));
    }

    function _uint(string memory json, uint256 at) internal view returns (uint256) {
        return abi.decode(_answer(json, at), (uint256));
    }

    // ---------------------------------------------------------------------
    // The tokens
    // ---------------------------------------------------------------------

    function _stocks() internal pure returns (address[STOCKS] memory) {
        return B.stocks();
    }

    /// @dev A holder of each stock at the pinned block, in the list's order: pools and vaults that hold far more than
    ///      the simulation moves. Read from each token's transfers on 2026-11-22.
    function _holders() internal pure returns (address[STOCKS] memory) {
        return [
            0xF668e21993f0ACd7ab00BB1cFbAeD0df28A3C8EC, // NVDAc
            0xd072410fa13D242e1d53721Bcf7AF02e3455DC96, // METAc
            0x51C72848c68a965f66FA7a88855F9f7784502a7F, // AAPLc
            0x16c70F04C3080a127486Cdf5a4C33c066bBF47C3, // GOOGLc
            0x532e0F46d1e528507FC9454d5847C231f23bDDf6, // AMZNc
            0x2740C0faAb738F6e346e545fDE02aEF9B1A01ee7, // MSFTc
            0x66DCd42E6314B287110922AE36cB2a8bdEECc153, // MSTRc
            0x2836e062a3fe75943a7F4A552E2365b98E414E75, // SNDKc
            0x880dB7Dda4407D99508574E680d067D1164B3cFE, // SPCXc
            0xa4d5947Eb727A052bae69C593FfC84247EC9864E // TSLAc
        ];
    }

    function _legs() internal pure returns (address[] memory legs) {
        address[STOCKS] memory stocks = _stocks();
        legs = new address[](LEGS);
        legs[0] = B.WETH;
        for (uint256 i = 0; i < STOCKS; ++i) {
            legs[i + 1] = stocks[i];
        }
    }

    /// @dev Each stock is the token its name says, read from the node: the symbol, eight decimals, a supply, and a
    ///      multiplier, the shares one token stands for, which a dividend raises while every balance stays as it was.
    ///      Its code is the one byte every B20 token has, which is why no call to it runs in this test's own EVM.
    function testFork_theStocksAreWhatTheirNamesSay() public {
        address[STOCKS] memory stocks = _stocks();
        string[STOCKS] memory symbols =
            ["NVDAc", "METAc", "AAPLc", "GOOGLc", "AMZNc", "MSFTc", "MSTRc", "SNDKc", "SPCXc", "TSLAc"];
        for (uint256 i = 0; i < STOCKS; ++i) {
            assertEq(stocks[i].code, hex"ef", symbols[i]);
            assertEq(abi.decode(_read(stocks[i], abi.encodeCall(IERC20Metadata.symbol, ())), (string)), symbols[i]);
            assertEq(abi.decode(_read(stocks[i], abi.encodeCall(IERC20Metadata.decimals, ())), (uint8)), 8);
            assertGt(abi.decode(_read(stocks[i], abi.encodeCall(IERC20.totalSupply, ())), (uint256)), 0, symbols[i]);
            uint256 multiplier = abi.decode(_read(stocks[i], abi.encodeWithSignature("multiplier()")), (uint256));
            // Not one share a token: on 2026-11-22 NVDAc stood at 1.0005 shares after its dividends, SNDKc at 8.
            assertGt(multiplier, 0, symbols[i]);
            assertEq(uint8(B.tierOf(stocks[i])), uint8(Listings.Tier.Custodial), "Custodial, as Coinbase's coins");
        }
    }

    // ---------------------------------------------------------------------
    // An index of the stocks, on the node
    // ---------------------------------------------------------------------

    function _params() internal pure returns (IWeightedIndexFactory.IndexParams memory) {
        return IWeightedIndexFactory.IndexParams({
            creatorFeeBps: 0,
            creatorStreamingBps: 0,
            maxPlatformFeeBps: 25,
            maxPlatformStreamingBps: 100,
            rebalanceInterval: 7 days,
            gated: false,
            listed: true
        });
    }

    /// @dev Queues the deployment, the listings and the creation: two blocks, a listing delay apart. Returns the
    ///      factory's address and the step that creates the index, whose answer is the index.
    function _queueCreation() internal returns (address factory, uint256 created) {
        address[] memory legs = _legs();
        factory = vm.computeCreateAddress(DEPLOYER, vm.getNonce(DEPLOYER));

        times.push(block.timestamp + 12);
        _create(
            "deploy the factory",
            DEPLOYER,
            abi.encodePacked(type(WeightedIndexFactory).creationCode, abi.encode(OWNER, address(0))),
            DEPLOY_GAS
        );
        for (uint256 i = 0; i < LEGS; ++i) {
            _wide("propose a listing", OWNER, factory, abi.encodeCall(IWeightedIndexFactory.proposeListing, (legs[i])));
        }

        times.push(times[0] + LISTING_DELAY + 1);
        IWeightedIndexFactory.ComponentSpec[] memory specs = new IWeightedIndexFactory.ComponentSpec[](LEGS);
        for (uint256 i = 0; i < LEGS; ++i) {
            _wide("execute a listing", OWNER, factory, abi.encodeCall(IWeightedIndexFactory.executeListing, (legs[i])));
            // 900 for WETH and 910 for each of the ten stocks is 10,000.
            specs[i] = IWeightedIndexFactory.ComponentSpec({
                token: legs[i], weight: i == 0 ? 900 : 910, units: i == 0 ? U_WETH : U_STOCK
            });
        }
        _push(
            "approve the creator",
            OWNER,
            factory,
            abi.encodeCall(IWeightedIndexFactory.setApprovedCreator, (CREATOR, true))
        );
        created = _wide(
            "create the index",
            CREATOR,
            factory,
            abi.encodeCall(IWeightedIndexFactory.createIndex, ("Base Stocks", "BSTK", specs, _params()))
        );
    }

    /// @dev Queues `amount` of each stock sent to `to` by its holder.
    function _queueFunding(address to, uint256 amount) internal {
        address[STOCKS] memory stocks = _stocks();
        address[STOCKS] memory holders = _holders();
        for (uint256 i = 0; i < STOCKS; ++i) {
            _push("a holder sends a stock", holders[i], stocks[i], abi.encodeCall(IERC20.transfer, (to, amount)));
        }
    }

    /// @dev Queues a read of every leg's balance of `account`; returns the first read's step.
    function _queueBalances(address account) internal returns (uint256 first) {
        address[] memory legs = _legs();
        first = steps.length;
        for (uint256 i = 0; i < LEGS; ++i) {
            _push("read a balance", MINTER, legs[i], abi.encodeCall(IERC20.balanceOf, (account)));
        }
    }

    function _balances(string memory json, uint256 first) internal view returns (uint256[] memory balances) {
        balances = new uint256[](LEGS);
        for (uint256 i = 0; i < LEGS; ++i) {
            balances[i] = _uint(json, first + i);
        }
    }

    /// @dev The steps whose answers the assertions read.
    struct Marks {
        uint256 created;
        uint256 previewed;
        uint256 heldAfterIssue;
        uint256 leftAfterIssue;
        uint256 fillPreview;
        uint256 unitsAfterFill;
        uint256 heldAfterFill;
        uint256 paidToExecutor;
        uint256 redeemPreview;
        uint256 supplyAfter;
        uint256 heldAfterRedeem;
        uint256 backAfterRedeem;
    }

    Marks marks;
    uint256[] newUnits;

    /// @dev Queues the issue, in the block of the creation: each holder sends the minter a stock, the minter wraps
    ///      ether, approves the index and issues.
    function _queueIssue(address index) internal {
        address[] memory legs = _legs();
        _queueFunding(MINTER, SHARES * U_STOCK / 1e18);
        _push("wrap ether", MINTER, B.WETH, abi.encodeCall(IWrappedEther.deposit, ()), SHARES * U_WETH / 1e18, CALL_GAS);
        for (uint256 i = 0; i < LEGS; ++i) {
            _push("approve the index", MINTER, legs[i], abi.encodeCall(IERC20.approve, (index, type(uint256).max)));
        }
        marks.previewed = _wide("preview the issue", MINTER, index, abi.encodeCall(IIndexHub.previewIssue, (SHARES)));
        _wide("issue in kind", MINTER, index, abi.encodeWithSignature("issue(uint256,address)", SHARES, MINTER));
        marks.heldAfterIssue = _queueBalances(index);
        marks.leftAfterIssue = _queueBalances(MINTER);
    }

    /// @dev Queues the rebalance: a start once the interval has run, and, two hours into its auction, a fill that
    ///      names a tenth less WETH and a twentieth more of each stock, by an executor deployed there and funded by
    ///      the holders.
    function _queueRebalance(address index) internal {
        times.push(times[1] + 8 days);
        _wide("start a rebalance", OWNER, index, abi.encodeWithSignature("startRebalance(uint256)", 0));
        times.push(times[2] + 4 hours);
        address executor = vm.computeCreateAddress(EXECUTOR_DEPLOYER, vm.getNonce(EXECUTOR_DEPLOYER));
        _create("deploy the executor", EXECUTOR_DEPLOYER, type(NodeExecutor).creationCode, WIDE_GAS);
        _queueFunding(executor, U_STOCK);
        newUnits.push(U_WETH * 9 / 10);
        for (uint256 i = 1; i < LEGS; ++i) {
            newUnits.push(U_STOCK * 21 / 20);
        }
        marks.fillPreview =
            _wide("preview the fill", MINTER, index, abi.encodeCall(IWeightedHub.previewRebalance, (newUnits)));
        _wide("fill the rebalance", MINTER, executor, abi.encodeCall(NodeExecutor.fill, (index, newUnits)));
        marks.unitsAfterFill = _wide("read the units", MINTER, index, abi.encodeCall(IWeightedHub.recordedUnits, ()));
        marks.heldAfterFill = _queueBalances(index);
        marks.paidToExecutor = _push("read the executor", MINTER, B.WETH, abi.encodeCall(IERC20.balanceOf, (executor)));
    }

    /// @dev Queues the exit: the minter redeems every share.
    function _queueExit(address index) internal {
        marks.redeemPreview =
            _wide("preview the redeem", MINTER, index, abi.encodeCall(IIndexHub.previewRedeem, (SHARES)));
        _wide("redeem in kind", MINTER, index, abi.encodeCall(IIndexHub.redeem, (SHARES, MINTER)));
        marks.supplyAfter = _push("read the supply", MINTER, index, abi.encodeCall(IERC20.totalSupply, ()));
        marks.heldAfterRedeem = _queueBalances(index);
        marks.backAfterRedeem = _queueBalances(MINTER);
    }

    /// @dev The whole life of an index of WETH and Coinbase's ten stocks, run by Base's node on the real tokens.
    ///      - The factory, deployed from this build's creation code, lists each token through its timelock; the
    ///        proposal reads the token's decimals from the precompile.
    ///      - An issue in kind pulls each stock from the minter and probes that the index can send it on (RW-8): a
    ///        contract the issuer never met receives a stock, sends itself one raw unit, and holds exactly what the
    ///        preview named.
    ///      - A fill takes WETH out and each stock in: the units are the ones the executor named, and every balance
    ///        moves by exactly the previewed amount, which is the probe that a bought leg can leave (RX-12) passing
    ///        on every stock.
    ///      - The holder redeems everything at the new units, and the index is left with nothing it owes.
    function testFork_anIndexOfTheStocksLivesOnBasesNode() public {
        // A first run, to learn the index's address: creation is the same in the full run.
        (, marks.created) = _queueCreation();
        string memory json = _simulate();
        _assertAllSucceeded(json);
        address index = abi.decode(_answer(json, marks.created), (address));

        _queueIssue(index);
        _queueRebalance(index);
        _queueExit(index);
        json = _simulate();
        _assertAllSucceeded(json);
        assertEq(abi.decode(_answer(json, marks.created), (address)), index, "the same index in both runs");

        _assertIssued(json);
        _assertFilled(json);
        _assertRedeemed(json);
    }

    function _assertIssued(string memory json) internal view {
        uint256[] memory need = abi.decode(_answer(json, marks.previewed), (uint256[]));
        uint256[] memory held = _balances(json, marks.heldAfterIssue);
        uint256[] memory left = _balances(json, marks.leftAfterIssue);
        for (uint256 i = 0; i < LEGS; ++i) {
            assertEq(need[i], SHARES * (i == 0 ? U_WETH : U_STOCK) / 1e18, "the issue asks for the units");
            assertEq(held[i], need[i], "the index holds exactly what the preview named");
            assertEq(left[i], 0, "and the minter paid exactly that");
        }
    }

    function _assertFilled(string memory json) internal view {
        (uint256 bar, int256 gain, uint256[] memory amountsOut, uint256[] memory amountsIn) =
            abi.decode(_answer(json, marks.fillPreview), (uint256, int256, uint256[], uint256[]));
        assertGt(bar, 0);
        assertGe(gain, int256(bar), "the fill clears the bar");
        uint256[] memory units = abi.decode(_answer(json, marks.unitsAfterFill), (uint256[]));
        uint256[] memory before = _balances(json, marks.heldAfterIssue);
        uint256[] memory held = _balances(json, marks.heldAfterFill);
        assertGt(amountsOut[0], 0, "WETH leaves");
        assertEq(_uint(json, marks.paidToExecutor), amountsOut[0], "to the executor");
        for (uint256 i = 0; i < LEGS; ++i) {
            assertEq(units[i], newUnits[i], "the units are the ones named");
            assertEq(held[i], before[i] + amountsIn[i] - amountsOut[i], "every balance moved by the previewed amount");
            if (i != 0) assertGt(amountsIn[i], 0, "every stock came in");
        }
    }

    function _assertRedeemed(string memory json) internal view {
        uint256[] memory owed = abi.decode(_answer(json, marks.redeemPreview), (uint256[]));
        uint256[] memory before = _balances(json, marks.heldAfterFill);
        uint256[] memory held = _balances(json, marks.heldAfterRedeem);
        uint256[] memory back = _balances(json, marks.backAfterRedeem);
        assertEq(_uint(json, marks.supplyAfter), 0, "every share is burned");
        for (uint256 i = 0; i < LEGS; ++i) {
            assertGt(owed[i], 0);
            assertEq(back[i], owed[i], "the holder leaves in kind at the new units");
            assertEq(held[i], before[i] - owed[i], "and the index paid exactly that");
        }
    }
}
