# Security

## Reporting a vulnerability

Please do not open a public issue. Report vulnerabilities privately through GitHub: on this repository's **Security**
tab, choose **Report a vulnerability**.

## Reviews

Xindex has not been audited externally yet. An external audit comes before any mainnet deployment.

Internal reviews of the current design:

| Review | Report |
|---|---|
| v5 design review | [audit/2026-10-05-v5-review.md](audit/2026-10-05-v5-review.md) |
| v5 logic review | [audit/2026-10-07-v5-logic-review.md](audit/2026-10-07-v5-logic-review.md) |
| Security audit | [audit/2026-10-13-security-audit.md](audit/2026-10-13-security-audit.md) |
| Security audit of the fee, cadence and builder engine | [audit/2026-10-16-security-audit.md](audit/2026-10-16-security-audit.md) |
| Red team | [audit/2026-10-18-red-team.md](audit/2026-10-18-red-team.md) |
| Keeper restock review | [audit/2026-10-25-restock-review.md](audit/2026-10-25-restock-review.md) |
| Skills audit | [audit/2026-10-25-skills-audit-port.md](audit/2026-10-25-skills-audit-port.md) |
| Rebalance review | [audit/2026-10-28-rebalance-review.md](audit/2026-10-28-rebalance-review.md) |
| Review | [audit/2026-10-31-review.md](audit/2026-10-31-review.md) |
| Red teams | [audit/2026-10-31-red-team.md](audit/2026-10-31-red-team.md), [audit/2026-10-31-red-team-ii.md](audit/2026-10-31-red-team-ii.md) |
| Review of every protocol used, against its own documentation | [audit/2026-11-01-protocol-docs-review.md](audit/2026-11-01-protocol-docs-review.md) |
| Red team of the oracle-free rebalance | [audit/2026-11-14-red-team.md](audit/2026-11-14-red-team.md) |
| Audit of the whole repository | [audit/2026-11-21-consolidated-audit.md](audit/2026-11-21-consolidated-audit.md) |

The brief for the external auditors, with the candidate commit, the scope and every open id, is
[audit/2026-11-21-external-audit-package.md](audit/2026-11-21-external-audit-package.md).

Each finding is fixed or recorded as a known limitation ([docs/known-limitations.md](docs/known-limitations.md)). Every
testable finding keeps a regression test named after its id, so `grep -r RX8 test/` finds the test for RX-8. Reviews
of earlier designs, and the records of what each redesign retired, are in [audit/](audit/).

## Guarantees the tests hold

- The backing invariant: every component's balance covers the shares' backing plus open claims.
- Issue, redeem, `redeemSkipping` and claims never read a price.
- 100% line, statement, branch and function coverage on every file, fuzz and invariant suites, and mainnet fork tests.
- Static analysis with Aderyn, Wake and Foundry's linter reports nothing on `src/`.
