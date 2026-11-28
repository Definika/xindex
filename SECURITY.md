# Security

## Reporting a vulnerability

Please do not open a public issue. Report vulnerabilities privately through GitHub: on this repository's **Security**
tab, choose **Report a vulnerability**.

## Reviews

Xindex has not been audited externally yet. An external audit comes before any mainnet deployment; its brief is
[audits/audit-package.md](audits/audit-package.md).

Internal reviews of the current design:

| Review | Report |
|---|---|
| v5 design review | [audits/internal/v5-review.md](audits/internal/v5-review.md) |
| v5 logic review | [audits/internal/v5-logic-review.md](audits/internal/v5-logic-review.md) |
| Security audit | [audits/internal/security-audit-cf.md](audits/internal/security-audit-cf.md) |
| Security audit of the fee, cadence and builder engine | [audits/internal/security-audit-xs.md](audits/internal/security-audit-xs.md) |
| Red team | [audits/internal/red-team-rx.md](audits/internal/red-team-rx.md) |
| Keeper restock review | [audits/internal/restock-review-rs.md](audits/internal/restock-review-rs.md) |
| Skills audit | [audits/internal/skills-audit-a7.md](audits/internal/skills-audit-a7.md) |
| Red team of the oracle-free rebalance | [audits/internal/red-team-rw.md](audits/internal/red-team-rw.md) |
| Consolidated audit | [audits/internal/consolidated-audit-ca.md](audits/internal/consolidated-audit-ca.md) |
| Attack replays against past DeFi hacks | [audits/internal/attack-replay.md](audits/internal/attack-replay.md), [audits/internal/attack-replay-ii.md](audits/internal/attack-replay-ii.md) |

Each finding is fixed or recorded as a known limitation ([docs/known-limitations.md](docs/known-limitations.md)). Every
testable finding keeps a regression test named after its id, so `grep -r RX8 test/` finds the test for RX-8. Reviews
of earlier designs, and the records of what each redesign retired, are in [audits/](audits).

## Guarantees the tests hold

- The backing invariant: every component's balance covers the shares' backing plus open claims.
- Issue, redeem, `redeemSkipping` and claims never read a price.
- 100% line, statement, branch and function coverage on every file, fuzz and invariant suites, and mainnet fork tests.
- Static analysis with Aderyn, Wake and Foundry's linter reports nothing on `src/`.
