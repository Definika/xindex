// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm, VmSafe} from "forge-std/Vm.sol";
import {IndexZap} from "../src/IndexZap.sol";
import {IIndexFactory} from "../src/interfaces/IIndexFactory.sol";
import {IUniversalRouter} from "../src/interfaces/IUniversalRouter.sol";
import {IXindexErrors} from "../src/interfaces/IXindexErrors.sol";

/// @notice Repository facts that security-review findings rest on and that no contract test can reach: the pinned
///         compiler (v1 I10), the pinned CI toolchain and required fork RPC (I11), the dependency lock against
///         `.gitmodules` (L08 and FR04) and the documented known limitations (I09); from the whole-repo audit, the CI
///         gates (XA-10, XA-64), the ignored chain-1 broadcasts (XA-43), the committed ABIs (XA-44), the single copy
///         of the agent instructions (XA-46) and the verification key (XA-58); from the logic review of 2026-09-18,
///         the test linking mode that lets checks after an expected constructor revert run (LR-01); from the security
///         audit of 2026-09-23, the ignored Sepolia-fork broadcasts (CR-I40). CI checks the submodule commits
///         themselves, which needs git; these tests check everything a local run can.
contract RepoTest is Test {
    /// @dev keccak256 of the files `test_A712_theCiConfigIsPinnedWhole` pins whole: CI's workflow and the two Foundry
    ///      configs it runs. A change to one fails that test, which prints the new hash, until it is pinned here.
    bytes32 private constant WORKFLOW_HASH = 0x61d572195ee06f987215585c11400a6ed24dae2af42e682cfd753b8802c6edbf;
    bytes32 private constant FOUNDRY_TOML_HASH = 0xad9de96ac8339b3cc1668438b0e9b63c65d70466cecb60d2702b9608293ab2cc;
    bytes32 private constant KEEPER_FOUNDRY_TOML_HASH =
        0x5426d5180cca7c4ac15d7fb182272a805a3ce19a143d6c6f8c158f61765d7592;

    function _read(string memory path) internal view returns (string memory) {
        return vm.readFile(string.concat(vm.projectRoot(), "/", path));
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        return vm.contains(haystack, needle);
    }

    /// @dev I10: the compiler is pinned in foundry.toml and every source and script file pins the same version.
    function test_I10_theCompilerIsPinned() public view {
        assertTrue(_contains(_read("foundry.toml"), 'solc = "0.8.28"'), "foundry.toml pins the compiler");
        _assertPragma("src");
        _assertPragma("script");
    }

    function _assertPragma(string memory dir) internal view {
        Vm.DirEntry[] memory entries = vm.readDir(string.concat(vm.projectRoot(), "/", dir), 3);
        uint256 checked = 0;
        for (uint256 i = 0; i < entries.length; ++i) {
            if (entries[i].isDir || !vm.contains(entries[i].path, ".sol")) continue;
            ++checked;
            assertTrue(
                vm.contains(vm.readFile(entries[i].path), "pragma solidity 0.8.28;"),
                string.concat(entries[i].path, " must pin pragma 0.8.28")
            );
        }
        assertGt(checked, 0, "the directory holds Solidity files");
    }

    /// @dev I11: CI pins Foundry and Wake and refuses to pass on main without the fork-test RPC. A7-12: each claim is
    ///      checked where it acts. Both jobs install the pinned Foundry, through the action's pinned commit; the step
    ///      that requires the secret is pinned whole, its condition included; and the RPC reaches the test step itself.
    ///      The name alone also stands in the step that requires the secret, so a test step that lost its `env:` passed
    ///      here while its fork suites skipped.
    function test_I11_A712_theCiToolchainIsPinned() public view {
        string memory workflow = _read(".github/workflows/test.yml");
        assertEq(_count(workflow, "foundry-rs/foundry-toolchain@"), 2, "each job installs Foundry once");
        assertEq(
            _count(
                workflow,
                string.concat(
                    "        uses: foundry-rs/foundry-toolchain@908c540300062bd5a7e473851cdb4282204cee09 # v1.9.1\n",
                    "        with:\n",
                    "          version: v1.8.1\n"
                )
            ),
            2,
            "and pins it, in both jobs"
        );
        assertTrue(_contains(workflow, "eth-wake==4.22.1"), "Wake is pinned");
        assertEq(
            _step(workflow, "Require the fork-test RPC on main and on pull requests into it"),
            string.concat(
                "        if: >-\n",
                "          (github.event_name == 'push' && github.ref == 'refs/heads/main') ||\n",
                "          (github.event_name == 'pull_request' && github.base_ref == 'main' &&\n",
                "          github.event.pull_request.head.repo.full_name == github.repository)\n",
                "        env:\n",
                "          MAINNET_RPC_URL: ${{ secrets.MAINNET_RPC_URL }}\n",
                "        run: |\n",
                "          if [ -z \"$MAINNET_RPC_URL\" ]; then\n",
                "            echo \"::error::Add the MAINNET_RPC_URL repository secret so the mainnet fork tests run.",
                "\"\n",
                "            exit 1\n",
                "          fi\n"
            ),
            "main and pull requests into it fail without the fork-test RPC"
        );
        assertEq(
            _step(workflow, "Run Forge tests"),
            string.concat(
                "        run: forge test -vvv\n",
                "        env:\n",
                "          MAINNET_RPC_URL: ${{ secrets.MAINNET_RPC_URL }}\n"
            ),
            "the fork-test RPC is passed to the tests"
        );
        assertTrue(_contains(workflow, "forge lint -D notes"), "lint fails on notes");
        assertTrue(_contains(workflow, "wake detect all src"), "the Wake detectors run");
    }

    /// @dev CF-6: Wake's run-time PyPI install never shares a job with Foundry's RPC cache, which the check job saves
    ///      and later fork-suite runs read as chain state; the Wake job keeps no cache of its own.
    function test_CF6_wakeRunsInAJobWithoutTheRpcCache() public view {
        string memory workflow = _read(".github/workflows/test.yml");
        uint256 wakeJob = vm.indexOf(workflow, "\n  wake:\n");
        assertTrue(wakeJob != type(uint256).max, "Wake has a job of its own");
        assertGt(vm.indexOf(workflow, "pipx install eth-wake"), wakeJob, "the PyPI install runs in it");
        assertLt(vm.indexOf(workflow, "run: forge test -vvv"), wakeJob, "the fork suites run in the check job");
        assertEq(_count(workflow, "pipx install"), 1, "nothing else installs from PyPI");
        assertGt(vm.indexOf(workflow, "cache: false"), wakeJob, "and the Wake job's Foundry keeps no RPC cache");
    }

    /// @dev L08 and FR04: every submodule is pinned in foundry.lock and every pinned path is a submodule. CI compares
    ///      the committed commits against the lock; that needs git, so it stays there.
    function test_L08_FR04_theDependencyLockAndGitmodulesAgree() public view {
        string memory gitmodules = _read(".gitmodules");
        string memory lock = _read("foundry.lock");
        string[] memory paths = new string[](3);
        paths[0] = "lib/forge-std";
        paths[1] = "lib/openzeppelin-contracts";
        paths[2] = "lib/openzeppelin-contracts-upgradeable";
        for (uint256 i = 0; i < paths.length; ++i) {
            assertTrue(_contains(gitmodules, string.concat("path = ", paths[i])), "submodule is declared");
            assertTrue(_contains(lock, string.concat('"', paths[i], '"')), "submodule is pinned");
        }
        // Both files list exactly these three, so neither can gain an unpinned or ghost entry unnoticed.
        assertEq(_count(gitmodules, "[submodule "), paths.length, ".gitmodules lists only the pinned submodules");
        assertEq(_count(lock, '"lib/'), paths.length, "foundry.lock pins only the declared submodules");
        assertTrue(_contains(lock, '"name": "v5.7.0"'), "OpenZeppelin stays on the reviewed release");
        assertTrue(_contains(lock, '"name": "v1.16.2"'), "forge-std stays on the reviewed release");
    }

    /// @dev I09: the residual risks the reviews accepted are written down for users. XS-17: each one is pinned by its
    ///      anchor inside the section itself, so a limitation cannot go missing while a cross-reference to the heading
    ///      keeps the old check green.
    function test_I09_XS17_theKnownLimitationsAreDocumented() public view {
        string memory section = _section(_read("docs/known-limitations.md"), "# Known limitations\n");
        string[23] memory anchors = [
            "**A lone executor can take up to 2% of what it trades.**",
            "**A wrong price costs at most the turnover cap.**",
            "**Rebalancing needs Pyth's Hermes, and Hermes needs a key.**",
            "**Wrapped legs rest on Wormhole.**",
            "**A collapsing coin can stop the fills.**",
            "**An issuer's corporate action is not accounted for.**",
            "**Price ids are data the owner maintains.**",
            "**Rebalances clear only when the moving value pays for the fill.**",
            "**An exit sent during the auction can be overtaken by the fill.**",
            "**The guardian can stall rebalancing.**",
            "**Issuers can freeze components, and some can burn them.**",
            "**A request's surplus goes to the fastest filler.**",
            "**Circle and Tether freeze differently, and `MintRequests` cannot tell.**",
            "**A request is an option held by every filler until it closes.**",
            "**Fees in shares only.**",
            "**The streaming fee is charged on the supply that was there.**",
            "**The basket builder is one custody point.**",
            "**Airdrops, rewards and governance votes**",
            "**A hooked V4 pool cannot be routed through.**",
            "**`PYTH` cannot be repointed.**",
            "**An executor that also builds the block sees further.**",
            "**A `tokenIn` that calls back into the zap is unsupported**",
            "**Zap gas grows with components and hops, and nothing on chain bounds it.**"
        ];
        for (uint256 i = 0; i < anchors.length; ++i) {
            assertTrue(_contains(section, anchors[i]), anchors[i]);
        }
        assertEq(_count(section, "\n- **"), anchors.length, "every limitation is pinned here, and only those");
        assertTrue(_contains(section, "until its own interval, 7 to 91 days"), "a fresh index waits its own interval");
        assertTrue(_contains(section, "restarts only `MIN_REBALANCE_INTERVAL` for a rebalance without a keep mask"));
        assertTrue(_contains(section, "fill lands at a reopening near `MU_MIN`"), "RX-3, fixed in the hub");
        assertTrue(_contains(section, "five of seven named guardians suffice to mint"), "RX-6");
    }

    /// @dev The text of `text` from `heading` up to the next second-level heading, or to its end.
    function _section(string memory text, string memory heading) internal pure returns (string memory) {
        bytes memory t = bytes(text);
        bytes memory h = bytes(heading);
        uint256 start = type(uint256).max;
        for (uint256 i = 0; i + h.length <= t.length; ++i) {
            if (keccak256(_slice(t, i, i + h.length)) == keccak256(h)) {
                start = i + h.length;
                break;
            }
        }
        assertTrue(start != type(uint256).max, heading);
        uint256 end = t.length;
        for (uint256 i = start; i + 4 <= t.length; ++i) {
            if (t[i] == "\n" && t[i + 1] == "#" && t[i + 2] == "#" && t[i + 3] == " ") {
                end = i;
                break;
            }
        }
        return string(_slice(t, start, end));
    }

    function _slice(bytes memory b, uint256 from, uint256 to) internal pure returns (bytes memory out) {
        out = new bytes(to - from);
        for (uint256 i = from; i < to; ++i) {
            out[i - from] = b[i];
        }
    }

    /// @dev XA-10: CI runs every gate of the definition of done. A7-12: each gate's step is pinned whole, keys and
    ///      script, as the path check's is: deleting the fmt, build or test step passed here, and a pin on a few words
    ///      of a step let an `if: false`, a `continue-on-error` or a dropped `exit 1` through. No step or job may fail
    ///      without failing CI, only the fork-test RPC's requirement runs on a condition (I11 pins it), and CI runs on
    ///      every push and pull request. A7-17: a compiler warning fails the build. Wake's generated config must leave
    ///      out `keeper/`, the bot's executor, a separate Foundry project whose remapping only it knows: Wake stops on
    ///      it before running a detector. The extension must ignore a local `wake.toml`, which would otherwise replace
    ///      its committed config.
    function test_XA10_A712_A717_ciRunsEveryGate() public view {
        string memory workflow = _read(".github/workflows/test.yml");
        assertTrue(
            _contains(workflow, "\non:\n  push:\n  pull_request:\n  workflow_dispatch:\n\njobs:\n"),
            "CI runs on every push and pull request"
        );
        assertEq(_count(workflow, "continue-on-error"), 0, "no step or job fails without failing CI");
        assertEq(_count(workflow, "if:"), 1, "only the fork-test RPC's requirement runs on a condition");
        assertEq(_count(workflow, '"if"') + _count(workflow, "'if'"), 0, "nor does a step behind a quoted key");
        assertEq(_step(workflow, "Run Forge fmt"), "        run: forge fmt --check\n", "formatting is checked");
        assertEq(
            _step(workflow, "Run Forge build"),
            "        run: forge build --sizes --deny warnings\n",
            "the build runs, and a compiler warning fails it"
        );
        assertEq(_step(workflow, "Run Forge lint"), "        run: forge lint -D notes\n", "lint fails on notes");
        assertTrue(_contains(_step(workflow, "Run Forge tests"), "        run: forge test -vvv\n"), "the tests run");
        assertEq(
            _step(workflow, "Check, build and test the keeper's executor"),
            string.concat(
                "        env:\n",
                "          MAINNET_RPC_URL: ${{ secrets.MAINNET_RPC_URL }}\n",
                "        run: |\n",
                "          set -euo pipefail\n",
                "          forge fmt --check --root keeper\n",
                "          forge build --root keeper --deny warnings\n",
                "          forge lint -D notes --root keeper\n",
                "          forge test --root keeper -vvv\n"
            ),
            "the keeper's executor gets the same gates"
        );
        assertEq(
            _step(workflow, "Run the keeper bot's unit tests"),
            "        run: node --test keeper/test/unit/*.test.mjs\n",
            "the keeper bot's unit tests run"
        );
        assertEq(
            _step(workflow, "Require 100% coverage on every file"),
            string.concat(
                string.concat(
                    "        run: |\n",
                    "          set -euo pipefail\n",
                    "          forge coverage --report summary --no-match-path 'test/fork/*' | tee coverage.txt\n",
                    "          python3 - <<'EOF'\n",
                    "          import re\n",
                    "          import sys\n",
                    "\n",
                    "          rows, short = 0, []\n",
                    "          for line in open(\"coverage.txt\"):\n",
                    "              cells = [cell.strip() for cell in line.strip().strip(\"|\").split(\"|\")]\n",
                    "              if not re.match(r\"^(src|script|test)/\", cells[0]):\n",
                    "                  continue\n"
                ),
                string.concat(
                    "              rows += 1\n",
                    "              if any(hit != total for hit, total in re.findall(r\"\\((\\d+)/(\\d+)\\)\", line)):",
                    "\n",
                    "                  short.append(cells[0])\n",
                    "          if rows == 0:\n",
                    "              print(\"::error::the coverage summary lists no files\")\n",
                    "              sys.exit(1)\n",
                    "          if short:\n",
                    "              print(\"::error::coverage is below 100% in \" + \", \".join(short))\n",
                    "              sys.exit(1)\n",
                    "          print(f\"100% coverage on all {rows} files\")\n",
                    "          EOF\n"
                )
            ),
            "coverage below 100% on any file fails"
        );
        assertEq(
            _step(workflow, "Run the Wake detectors on src"),
            string.concat(
                "        run: |\n",
                "          set -euo pipefail\n",
                "          pipx install eth-wake==4.22.1\n",
                "          wake init config --force\n",
                "          perl -pi -e 's/^exclude_paths = \\[/exclude_paths = [\"keeper\", /' wake.toml\n",
                "          if ! grep -q '^exclude_paths = \\[\"keeper\", ' wake.toml; then\n",
                "            echo \"::error::the generated wake.toml changed shape, so keeper/ is not excluded\"\n",
                "            exit 1\n",
                "          fi\n",
                "          wake detect all src\n"
            ),
            "the Wake detectors run on src, keeper/ left out"
        );
        string memory settings = _read(".vscode/settings.json");
        assertTrue(_contains(settings, '"keeper"'), "the Wake extension leaves out keeper/ too");
        assertTrue(
            _contains(settings, '"wake.configuration.use_toml_if_present": false'),
            "and no local wake.toml replaces the extension's committed config"
        );
    }

    /// @dev A7-12: CI's own files are pinned whole, the workflow and both Foundry configs, as the gates' steps are.
    ///      GitHub and Foundry read more than a step: a job's `defaults: run: shell`, a `FOUNDRY_*` variable on a
    ///      job, a `no_match_path` in either config, an install step before the gates or a `ref:` on the checkout
    ///      each made every gate a no-op, or pointed it at other code, while each step's pin still matched. Any
    ///      change to these files now fails here until its hash is pinned in the same commit, so none lands
    ///      unreviewed, and the step pins keep every gate through a change that is.
    function test_A712_theCiConfigIsPinnedWhole() public view {
        _assertPinnedWhole(".github/workflows/test.yml", WORKFLOW_HASH);
        _assertPinnedWhole("foundry.toml", FOUNDRY_TOML_HASH);
        _assertPinnedWhole("keeper/foundry.toml", KEEPER_FOUNDRY_TOML_HASH);
    }

    function _assertPinnedWhole(string memory path, bytes32 pinned) internal view {
        bytes32 actual = keccak256(bytes(_read(path)));
        assertEq(
            actual, pinned, string.concat(path, " changed: review the whole change, then pin ", vm.toString(actual))
        );
    }

    /// @dev XA-43: mainnet-fork rehearsals keep chain id 1, so chain-1 broadcast records stay out of git unless a real
    ///      deployment's record is added on purpose.
    function test_XA43_chainOneBroadcastsAreIgnored() public view {
        assertTrue(_contains(_read(".gitignore"), "\n/broadcast/*/1/\n"), "chain-1 broadcast records are ignored");
    }

    /// @dev CR-I40: a Sepolia-fork rehearsal keeps chain id 11155111, since SetupTestMarket refuses any other, so its
    ///      records landed beside the real Sepolia history and were committed with it, an aborted run among them.
    function test_CRI40_sepoliaForkBroadcastsAreIgnored() public view {
        assertTrue(
            _contains(_read(".gitignore"), "\n/broadcast/*/11155111/\n"), "Sepolia broadcast records are ignored"
        );
    }

    /// @dev XA-44: the ABIs the web app decodes with are committed, and CI regenerates them and fails on a diff: the zap,
    ///      the basket builder, `MintRequests`, and v5's weighted factory and index. v4's market-cap factory and hub are deleted, and their
    ///      ABIs with them; so are Stage B's hybrid factory, hybrid index and vault
    ///      (`audit/2026-10-07-stage-b-retirement.md`). A7-12: the step is pinned whole, so neither a contract left out
    ///      nor a diff that stops failing passes.
    function test_XA44_A712_theAbisAreCommittedAndChecked() public view {
        string[5] memory contracts =
            ["IndexZap", "BasketBuilder", "MintRequests", "WeightedIndexFactory", "WeightedHub"];
        for (uint256 i = 0; i < contracts.length; ++i) {
            assertTrue(
                _contains(_read(string.concat("abi/", contracts[i], ".json")), '"type": "function"'),
                string.concat("abi/", contracts[i], ".json is committed")
            );
        }
        assertEq(
            _step(_read(".github/workflows/test.yml"), "Check the committed ABIs are current"),
            string.concat(
                "        run: |\n",
                "          set -euo pipefail\n",
                "          for contract in IndexZap BasketBuilder MintRequests WeightedIndexFactory WeightedHub; do\n",
                "            forge inspect \"$contract\" abi --json > \"abi/$contract.json\"\n",
                "          done\n",
                "          git diff --exit-code abi/\n"
            ),
            "CI regenerates every ABI, and a stale one fails it"
        );
        assertFalse(vm.exists("abi/IndexFactory.json"), "v4's factory ABI is gone");
        assertFalse(vm.exists("abi/IndexHub.json"), "and its hub's");
        assertFalse(vm.exists("abi/HybridIndexFactory.json"), "Stage B's factory ABI is gone");
        assertFalse(vm.exists("abi/IHybridIndex.json"), "and its index's");
        assertFalse(vm.exists("abi/XindexVault.json"), "and its vault's");
    }

    /// @dev DA-10. A token config carried a list of excluded holders whose balances `IndexRule._supply` subtracted
    ///      with a live `balanceOf` inside the rebalance snapshot, so a config naming an address a third party could
    ///      fund and drain made that component's market cap manipulable inside one transaction: flash loan in, start a
    ///      rebalance, flash loan out. Nothing shipped used it, and a reference supply behind the listing timelock
    ///      covers the same need, so the field is gone from the config, the events, the rule and the listing script.
    ///      v5 lists a token with a price id and nothing else, and neither its listing ABIs nor its listing script's
    ///      entries carry an exclusion list.
    function test_DA10_noConfigCanCarryExclusions() public view {
        assertFalse(
            _contains(_read("abi/WeightedIndexFactory.json"), "excluded"), "the listing ABI has no exclusion list"
        );
        assertFalse(_contains(_read("script/ConfigureWeighted.s.sol"), "excluded"), "nor the listing script's entries");
    }

    /// @dev XA-46: the agent instructions have one copy; CLAUDE.md only imports AGENTS.md.
    function test_XA46_claudeMdOnlyImportsAgentsMd() public view {
        string memory claude = _read("CLAUDE.md");
        assertTrue(_contains(claude, "\n@AGENTS.md"), "CLAUDE.md imports AGENTS.md");
        assertFalse(_contains(claude, "\n## "), "and repeats none of its sections");
    }

    /// @dev XA-58: `--verify` finds its key: `.env.example` names it and foundry.toml uses it for mainnet and Sepolia.
    function test_XA58_verificationHasItsApiKey() public view {
        assertTrue(_contains(_read(".env.example"), "\nETHERSCAN_API_KEY="), "the example environment names the key");
        string memory config = _read("foundry.toml");
        assertTrue(_contains(config, 'mainnet = { key = "${ETHERSCAN_API_KEY}" }'), "mainnet verification uses it");
        assertTrue(_contains(config, 'sepolia = { key = "${ETHERSCAN_API_KEY}" }'), "Sepolia verification uses it");
    }

    /// @dev XA-64: CI clones only the direct submodules and checks the lock both ways, so a ghost lock entry fails.
    ///      A7-12: both checkouts clone only `lib/*`, and the check is pinned whole, keys and script: a pin on two of
    ///      its messages let an `exit 0` through.
    function test_XA64_A712_ciChecksOutDirectSubmodulesAndTheLockBothWays() public view {
        string memory workflow = _read(".github/workflows/test.yml");
        assertEq(_count(workflow, "          submodules: true\n"), 2, "each checkout clones only lib/*");
        assertFalse(_contains(workflow, "recursive"), "never the dependencies' nested submodules");
        assertEq(
            _step(workflow, "Check submodule commits match foundry.lock"),
            string.concat(
                string.concat(
                    "        run: |\n",
                    "          set -euo pipefail\n",
                    "          if ! jq -e 'type == \"object\" and length > 0' foundry.lock > /dev/null 2>&1; then\n",
                    "            echo \"::error::foundry.lock is missing, empty or not a JSON object\"\n",
                    "            exit 1\n",
                    "          fi\n",
                    "          failed=0\n",
                    "          checked=0\n",
                    "          while read -r _ dep; do\n",
                    "            checked=$((checked + 1))\n",
                    "            if ! want=$(jq -er --arg p \"$dep\" '.[$p] | to_entries[0].value | if type == \"objec",
                    "t\" then .rev else . end' foundry.lock 2>/dev/null); then\n"
                ),
                string.concat(
                    "              echo \"::error::$dep has no entry in foundry.lock\"\n",
                    "              failed=1\n",
                    "              continue\n",
                    "            fi\n",
                    "            have=$(git ls-tree HEAD \"$dep\" | awk '{print $3}')\n",
                    "            if [ \"$want\" != \"$have\" ]; then\n",
                    "              echo \"::error::$dep is committed at ${have:-nothing} but foundry.lock pins $want\"",
                    "\n",
                    "              failed=1\n",
                    "            fi\n",
                    "          done < <(git config -f .gitmodules --get-regexp '^submodule\\..*\\.path$')\n",
                    "          if [ \"$checked\" -eq 0 ]; then\n"
                ),
                string.concat(
                    "            echo \"::error::.gitmodules lists no submodules to check\"\n",
                    "            exit 1\n",
                    "          fi\n",
                    "          paths=$(git config -f .gitmodules --get-regexp '^submodule\\..*\\.path$' | awk '{print ",
                    "$2}')\n",
                    "          while read -r pinned; do\n",
                    "            if ! grep -qxF \"$pinned\" <<< \"$paths\"; then\n",
                    "              echo \"::error::foundry.lock pins $pinned but .gitmodules has no such submodule\"\n",
                    "              failed=1\n",
                    "            fi\n",
                    "          done < <(jq -r 'keys[]' foundry.lock)\n",
                    "          exit \"$failed\"\n"
                )
            ),
            "every submodule is pinned, and every pin is a submodule"
        );
    }

    /// @dev No committed file names a path on its author's machine: a home folder, a temporary folder, or the folder an
    ///      agent names after a home folder and keeps its scratchpad in. Three audit records showed the author's user
    ///      name so until 2026-10-25. CI greps every committed text file and fails on a match, and on a grep that could
    ///      not run, which would otherwise pass as a clean tree. The step is pinned whole, keys and script: a pin on a
    ///      few of its lines let an `if: false`, a `continue-on-error`, a commented-out `exit 1` and a dropped
    ///      `status=0` through (a match then leaves the status empty, which neither test catches). The brackets keep
    ///      each pattern from matching itself.
    function test_ciRefusesAPathOnItsAuthorsMachine() public view {
        assertEq(
            _step(_read(".github/workflows/test.yml"), "Check no committed file names a local path"),
            string.concat(
                "        run: |\n",
                "          users='/Use[r]s/|\\\\Use[r]s\\\\|-Use[r]s-'\n",
                "          rooted='(^|[^[:alnum:]._-])(/hom[e]/|-hom[e]-|/privat[e]/(tmp|var)/|/va[r]/folders/)'\n",
                "          status=0\n",
                "          git grep -n -I -E -e \"$users\" -e \"$rooted\" || status=$?\n",
                "          if [ \"$status\" -eq 0 ]; then\n",
                "            echo \"::error::the lines above name a path on their author's machine\"\n",
                "            exit 1\n",
                "          fi\n",
                "          if [ \"$status\" -ne 1 ]; then\n",
                "            echo \"::error::git grep could not run (status $status)\"\n",
                "            exit 1\n",
                "          fi\n"
            ),
            "CI runs exactly this step: no key added, no line changed"
        );
    }

    /// @dev The CI step named `name`, less its name line: the lines after it up to the next line indented less than a
    ///      step's keys that is not a comment (the next step or the next job), trailing blank and comment lines left
    ///      out. YAML reads a comment at any indentation, so one indented less is the step's when a key of the step
    ///      follows it (A7-12). The name line must start a line, indented as a step, and no other step may carry the
    ///      name, so neither a commented-out copy nor a second step stands in for it.
    function _step(string memory workflow, string memory name) internal pure returns (string memory) {
        bytes memory t = bytes(workflow);
        bytes memory h = bytes(string.concat("\n      - name: ", name, "\n"));
        uint256 at = _indexOf(t, h, 0);
        assertTrue(at < t.length, name);
        assertEq(_indexOf(t, h, at + 1), t.length, "no other step carries the name");
        uint256 start = at + h.length;
        uint256 end = start;
        for (uint256 line = start; line < t.length;) {
            uint256 next = _indexOf(t, bytes("\n"), line);
            uint256 indent = 0;
            while (line + indent < next && t[line + indent] == bytes1(" ")) {
                ++indent;
            }
            if (line + indent < next) {
                if (indent >= 8) end = next < t.length ? next + 1 : next;
                else if (t[line + indent] != bytes1("#")) break;
            }
            line = next + 1;
        }
        return string(_slice(t, start, end));
    }

    /// @dev A7-12: `_step` reads a step as YAML does. YAML gives a comment line's indentation no meaning, so a key
    ///      under the comment above the next step still belongs to this one: `shell: true {0}` there makes GitHub run
    ///      `true` in place of the step's script, and passed every pin while the cut stopped at the comment. Such a
    ///      key is part of the step's text now; a comment followed by the next step is not.
    function test_A712_aStepEndsWhereYamlEndsIt() public pure {
        string memory workflow = string.concat(
            "    steps:\n",
            "      - name: Gate\n",
            "        run: gate\n",
            "\n",
            "      # The next step's comment.\n",
            "        shell: true {0}\n",
            "      - name: Next\n",
            "        run: next\n",
            "\n",
            "  # The next job's comment.\n",
            "  other:\n"
        );
        assertEq(
            _step(workflow, "Gate"),
            "        run: gate\n\n      # The next step's comment.\n        shell: true {0}\n",
            "a key below the comment is the step's own"
        );
        assertEq(_step(workflow, "Next"), "        run: next\n", "a comment followed by the next job is not");
    }

    /// @dev Where `needle` first occurs in `t` at or after `from`, or `t.length` if it does not.
    function _indexOf(bytes memory t, bytes memory needle, uint256 from) internal pure returns (uint256) {
        for (uint256 i = from; i + needle.length <= t.length; ++i) {
            uint256 j = 0;
            while (j < needle.length && t[i + j] == needle[j]) {
                ++j;
            }
            if (j == needle.length) return i;
        }
        return t.length;
    }

    /// @dev A1a-06: modifier logic lives in a private function, as AGENTS.md's conventions say. Each modifier in
    ///      `src/` is its helper's call and `_;` alone, and the helper is the file's one function of its name, declared
    ///      `private`: no logic sits in a modifier, and no derived contract can call the check outside it
    ///      (`test_A1a06_aModifierHoldsItsHelperCallAlone` shows what the parse refuses).
    function test_A1a06_modifierLogicIsPrivate() public view {
        VmSafe.DirEntry[] memory entries = vm.readDir("src", 8);
        uint256 modifiers = 0;
        for (uint256 i = 0; i < entries.length; ++i) {
            if (entries[i].isDir || !_endsWith(entries[i].path, ".sol")) continue;
            bytes memory t = bytes(vm.readFile(entries[i].path));
            for (uint256 at = _indexOf(t, bytes("\n    modifier "), 0); at < t.length;) {
                ++modifiers;
                string memory line = string(_slice(t, at + 1, _indexOf(t, bytes("\n"), at + 1)));
                assertGt(bytes(_modifierHelper(t, at)).length, 0, string.concat(entries[i].path, ": ", line));
                at = _indexOf(t, bytes("\n    modifier "), at + 1);
            }
        }
        assertGe(modifiers, 2, "the modifiers of src/ are found");
    }

    /// @dev The private function the modifier declared at `at` in `t` calls, or "" unless the modifier's body is that
    ///      call and `_;` alone, each on a line of its own, and the file declares one function of the name, `private`.
    function _modifierHelper(bytes memory t, uint256 at) internal pure returns (string memory) {
        uint256 open = _indexOf(t, bytes("\n"), at + 1);
        if (open + 9 >= t.length || t[open - 1] != "{" || t[open - 2] != " ") return "";
        string memory helper = string(_slice(t, open + 9, _indexOf(t, bytes("("), open + 9)));
        bytes memory body = bytes(string.concat("        ", helper, "();\n        _;\n    }\n"));
        if (open + 1 + body.length > t.length) return "";
        if (keccak256(_slice(t, open + 1, open + 1 + body.length)) != keccak256(body)) return "";
        bytes memory declaration = bytes(string.concat("\n    function ", helper, "("));
        uint256 declared = _indexOf(t, declaration, 0);
        if (declared == t.length || _indexOf(t, declaration, declared + 1) != t.length) return "";
        if (!_contains(string(_slice(t, declared, _indexOf(t, bytes("{"), declared))), ") private")) return "";
        return helper;
    }

    /// @dev A1a-06: a modifier passes only if its body is its private helper's call and `_;`, each on a line of its
    ///      own, and no other function of the file takes the helper's name. The check read only a modifier's first
    ///      statement, so a second one, or a check after `_;`, passed; a body with no call passed on the next
    ///      function's call, read as its own; and the first function of the helper's name anywhere in the file, in
    ///      another contract as much, decided whether it was private.
    function test_A1a06_aModifierHoldsItsHelperCallAlone() public pure {
        string memory helper = "\n    function _check() private view {}\n}\n";
        bytes memory ok =
            bytes(string.concat("contract C {\n    modifier only() {\n        _check();\n        _;\n    }\n", helper));
        assertEq(_modifierHelper(ok, _indexOf(ok, bytes("\n    modifier "), 0)), "_check", "its helper's call alone");
        string[4] memory wrong = [
            string.concat(
                "contract C {\n    modifier only() {\n        _check();\n        require(ok);\n        _;\n    }\n",
                helper
            ),
            string.concat(
                "contract C {\n    modifier only() {\n        _check();\n        _;\n        _check();\n    }\n", helper
            ),
            string.concat(
                "contract C {\n    modifier only() { _; }\n\n",
                "    function g() external view {\n        _check();\n    }\n",
                helper
            ),
            string.concat(
                "contract A {\n    function _check() private view {}\n}\n\ncontract C {\n    modifier only() {\n",
                "        _check();\n        _;\n    }\n\n    function _check() internal view {}\n}\n"
            )
        ];
        string[4] memory why =
            ["a second statement", "a check after `_;`", "no call, the next function's read", "the name taken twice"];
        for (uint256 i = 0; i < wrong.length; ++i) {
            bytes memory t = bytes(wrong[i]);
            assertEq(_modifierHelper(t, _indexOf(t, bytes("\n    modifier "), 0)), "", why[i]);
        }
    }

    /// @dev A7-18: tests and scripts read only the files these checks need. No cheatcode can read `.env`, which holds
    ///      the RPC URLs and the Etherscan key, by its path or by climbing out of a readable folder; nor the keeper's
    ///      folder, the broadcast records or a root file nothing needs. Foundry refuses such a read before it looks for
    ///      the file, so the refusal shows where no `.env` exists, as in CI.
    function test_A718_noCheatcodeReadsTheEnvFile() public view {
        string[5] memory off =
            [".env", "src/../.env", "keeper/.env", "broadcast/DeployWeighted.s.sol/1/run-latest.json", "AGENTS.md"];
        for (uint256 i = 0; i < off.length; ++i) {
            try this.readForA718(off[i]) returns (string memory) {
                assertTrue(false, string.concat(off[i], " was read"));
            } catch (bytes memory err) {
                assertLt(_indexOf(err, bytes("not allowed"), 0), err.length, string.concat(off[i], " is refused"));
            }
        }
    }

    /// @dev Reads `path` through the cheatcode, as an external call, so a refusal can be caught and read.
    function readForA718(string calldata path) external view returns (string memory) {
        return vm.readFile(path);
    }

    /// @dev LR-01: forge's default `dynamic_test_linking` deploys a `src/` contract a test creates through a
    ///      cheatcode, and the test function then ended, reported as a pass, at the first expected constructor revert:
    ///      the checks after it never ran, and neither did an unmet `expectCall`. Nothing placed after such a revert
    ///      can detect that mode, so the setting is checked first; the rest shows what it buys, a marker call that is
    ///      only made if the function runs to its end.
    function test_LR01_checksAfterAnExpectedConstructorRevertStillRun() public {
        assertTrue(_contains(_read("foundry.toml"), "\ndynamic_test_linking = false\n"), "test linking stays static");
        vm.expectRevert(IXindexErrors.ZeroAddress.selector);
        new IndexZap(IIndexFactory(address(0)), IUniversalRouter(address(0)));
        vm.expectCall(address(this), abi.encodeCall(this.reachedAfterTheRevert, ()));
        this.reachedAfterTheRevert();
    }

    function reachedAfterTheRevert() external {}

    /// @dev No file in `src/` and no shipped ABI in `abi/` names a Chainlink feed, a pool's price or its oracle, and the
    ///      v3 price contracts are gone. Every file of both folders is read, Stage B's included, so a new file is covered
    ///      without being listed. v5's one price source is Pyth, read only by `WeightedHub`'s settlement
    ///      (`test_V5I4_onlyTheWeightedHubReadsAPrice`). A7-13: the words name the common ways to read a price
    ///      (`_priceWords`), not five of them, and `test_A713_theScanFindsEveryPriceWord` shows the scan finds each.
    function test_A713_noContractReadsAPrice() public view {
        string[47] memory priceWords = _priceWords();
        uint256 read = _assertNoPriceIn("src", priceWords) + _assertNoPriceIn("abi", priceWords);
        assertGt(read, 20, "every source and ABI file is read");
        string[5] memory gone = [
            "src/IndexRule.sol",
            "src/CompositeFeed.sol",
            "src/interfaces/IAggregatorV3.sol",
            "src/interfaces/IIndexRule.sol",
            "abi/IndexRule.json"
        ];
        for (uint256 i = 0; i < gone.length; ++i) {
            assertFalse(vm.exists(gone[i]), string.concat(gone[i], " is gone"));
        }
    }

    /// @dev A7-13: the scan names a price word wherever a text holds one, and nothing in a text that holds none. A line
    ///      reading each word is scanned as a file's text is.
    function test_A713_theScanFindsEveryPriceWord() public pure {
        string[47] memory priceWords = _priceWords();
        for (uint256 i = 0; i < priceWords.length; ++i) {
            string memory line = string.concat("        uint256 p = source.", priceWords[i], ");\n");
            assertEq(_priceWordIn(line, priceWords), priceWords[i], string.concat("the scan finds ", priceWords[i]));
        }
        assertEq(
            _priceWordIn("uint256 units = shares * unitsPerShare;\n", priceWords), "", "and none in a line with none"
        );
    }

    /// @dev The names of the common ways to read a price: Chainlink's feeds, legacy rounds included; a Uniswap V3 or V4
    ///      pool's slot 0, square-root price, observations and raw state; a V2 pair's reserves and cumulative prices;
    ///      TWAP oracles; quoters', routers' and ERC-7726 quotes; Curve's and Balancer's pool prices, rates and
    ///      queries; the lending markets', Band's, Chronicle's, Maker's, API3's and Tellor's oracles; a staked or vault
    ///      token's exchange rate; and the retired `navPerToken`. Pyth's getters are V5-I4's words, allowed in the hub
    ///      alone. A read through a name not listed here, or by raw selector, is review's to catch (A7-13).
    function _priceWords() internal pure returns (string[47] memory) {
        return [
            "latestRoundData",
            "latestAnswer",
            "getRoundData",
            "getAnswer",
            "AggregatorV3",
            "slot0",
            "Slot0",
            "sqrtPriceX96",
            "observe(",
            "observations",
            "extsload",
            "getReserves",
            "CumulativeLast",
            "CumulativePrices",
            "priceCumulative",
            "consult(",
            "getQuoteAtTick",
            "getQuote(",
            "quoteExact",
            "getAmountsOut",
            "getAmountOut",
            "getAmountsIn",
            "getAmountIn",
            "get_dy",
            "price_oracle",
            "get_virtual_price",
            "last_price",
            "price_scale",
            "get_p(",
            "ema_price",
            "getRate",
            "queryBatchSwap",
            "querySwap",
            "getAssetPrice",
            "getAssetsPrices",
            "getUnderlyingPrice",
            ".price(",
            "getReferenceData",
            ".read(",
            ".peek(",
            "getDataBefore",
            "getCurrentValue",
            "stEthPerToken",
            "exchangeRate",
            "convertToAssets",
            "pricePerShare",
            "navPerToken"
        ];
    }

    /// @dev The first of `priceWords` that `text` names, or "" if it names none.
    function _priceWordIn(string memory text, string[47] memory priceWords) internal pure returns (string memory) {
        for (uint256 j = 0; j < priceWords.length; ++j) {
            if (_contains(text, priceWords[j])) return priceWords[j];
        }
        return "";
    }

    /// @dev v5 reads one price source, Pyth, in one place: `WeightedHub`'s settlement. Only the hub, its interface (which
    ///      names Pyth's fee quote and takes Pyth's price struct for executors), its ABI and the vendored Pyth files name
    ///      Pyth's contract, its parse, its getters, its pushes or its price struct; the factory, the zap and
    ///      `MintRequests` name none of them. A new file is covered without being listed. The words cover every way to
    ///      read a Pyth price, not only the one the hub uses (V5-I4).
    function test_V5I4_onlyTheWeightedHubReadsAPrice() public view {
        string[6] memory allowed = [
            "src/WeightedHub.sol",
            "src/interfaces/IWeightedHub.sol",
            "src/interfaces/pyth/IPyth.sol",
            "src/interfaces/pyth/IPythEvents.sol",
            "src/interfaces/pyth/PythStructs.sol",
            "abi/WeightedHub.json"
        ];
        string[5] memory pythWords = ["IPyth", "parsePriceFeedUpdates", "getPrice", "updatePriceFeeds", "PythStructs"];
        uint256 read = 0;
        string[2] memory dirs = ["src", "abi"];
        for (uint256 d = 0; d < dirs.length; ++d) {
            VmSafe.DirEntry[] memory entries = vm.readDir(dirs[d], 8);
            for (uint256 i = 0; i < entries.length; ++i) {
                if (entries[i].isDir || _isFinderMetadata(entries[i].path)) continue;
                ++read;
                bool exempt = false;
                for (uint256 a = 0; a < allowed.length; ++a) {
                    exempt = exempt || _endsWith(entries[i].path, allowed[a]);
                }
                if (exempt) continue;
                string memory text = vm.readFile(entries[i].path);
                for (uint256 j = 0; j < pythWords.length; ++j) {
                    assertFalse(_contains(text, pythWords[j]), string.concat(entries[i].path, " names ", pythWords[j]));
                }
            }
        }
        assertGt(read, 20, "every source and ABI file is read");
        assertTrue(_contains(_read("src/WeightedHub.sol"), "parsePriceFeedUpdatesUnique"), "the hub reads Pyth");
        assertFalse(_contains(_read("src/WeightedIndexFactory.sol"), "Pyth("), "the factory never calls Pyth");
    }

    function _endsWith(string memory text, string memory suffix) internal pure returns (bool) {
        bytes memory t = bytes(text);
        bytes memory s = bytes(suffix);
        if (s.length > t.length) return false;
        for (uint256 i = 0; i < s.length; ++i) {
            if (t[t.length - s.length + i] != s[i]) return false;
        }
        return true;
    }

    /// @dev macOS Finder writes a binary `.DS_Store` into any folder it opens. It is never a source or an ABI, and
    ///      `vm.readFile` fails on it as invalid UTF-8, so the walks that read every file skip it and nothing else.
    function _isFinderMetadata(string memory path) internal pure returns (bool) {
        return _endsWith(path, "/.DS_Store");
    }

    /// @dev Reads every file under `dir`, Finder's `.DS_Store` aside, and fails on any price word; returns how many files
    ///      it read.
    function _assertNoPriceIn(string memory dir, string[47] memory priceWords) internal view returns (uint256 read) {
        VmSafe.DirEntry[] memory entries = vm.readDir(dir, 8);
        for (uint256 i = 0; i < entries.length; ++i) {
            if (entries[i].isDir || _isFinderMetadata(entries[i].path)) continue;
            string memory found = _priceWordIn(vm.readFile(entries[i].path), priceWords);
            assertEq(found, "", string.concat(entries[i].path, " names ", found));
            ++read;
        }
    }

    function _count(string memory haystack, string memory needle) internal pure returns (uint256 found) {
        bytes memory hay = bytes(haystack);
        bytes memory pin = bytes(needle);
        for (uint256 i = 0; i + pin.length <= hay.length; ++i) {
            bool hit = true;
            for (uint256 j = 0; j < pin.length; ++j) {
                if (hay[i + j] != pin[j]) {
                    hit = false;
                    break;
                }
            }
            if (hit) ++found;
        }
    }
}
