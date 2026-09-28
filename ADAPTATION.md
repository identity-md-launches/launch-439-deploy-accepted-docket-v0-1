# ADAPTATION

Adaptation of the accepted Docket v0.1 project
(https://github.com/identity-md-launches/launch-197-build-docket-v0-1-smallest) for launch through
ProjectFactory under the `evm_project` launch kind. Every change is listed with the file it touches and
the rule or finding that required it. Nothing else in the tree was changed.

## Unchanged, as the brief requires

| Path | Status |
| --- | --- |
| `src/Docket.sol` | byte-for-byte as accepted; no constructor arguments, no owner, admin, pause or upgrade path |
| `script/Deploy.s.sol` | as accepted |
| `test/Docket.t.sol`, `test/Docket.upvote.t.sol`, `test/Docket.invariant.t.sol`, `test/Docket.gas.t.sol`, `test/Deploy.t.sol`, `test/helpers/TestBase.sol` | as accepted |
| `foundry.toml` | as accepted: solc 0.8.26, optimizer 200 runs, `cancun`, `bytecode_hash = "none"` (protected build configuration) |
| `launch.json` | not written by this step; the manifest step re-derives it (see finding below) |

Docket already satisfies every constructor rule of the launch kind: a nonpayable constructor with no
arguments, no `msg.sender` use in the constructor, no privileged role, and a runtime with no
DELEGATECALL, CALLCODE or SELFDESTRUCT (asserted in `test/LaunchToken.t.sol`).

## Change 1: `src/LaunchToken.sol` (added)

**Rule.** The `evm_project` launch kind reference: "This project launch deploys a token with the
contracts, and it cannot deploy without one. Write it as the contract LaunchToken in
src/LaunchToken.sol, even when the brief never mentions a token. ... this step is rejected without
src/LaunchToken.sol." The previous attempt at this task delivered no token and was rejected for
exactly that reason (`src/LaunchToken.sol: missing`).

**Conflict with the brief, stated plainly.** The brief says there is no token and asks not to create,
mint or pair one. The launch kind cannot admit a tokenless project: the protected floor
(`Project.protected.t.sol`) unconditionally deploys `IMD_TOKEN_CREATION_CODE`, requires a positive
supply held by the factory, and the manifest schema requires a `token` object. The task rules say the
launch rules win where they disagree with the brief, and the acceptance criteria allow behaviour changes
"where the launch rules ... required a change". So the token is added as the protocol's reward artifact,
and the brief's intent is preserved as far as the launch kind allows:

- Docket does not reference, hold, require or interact with the token in any way. No Docket source,
  test or script changed.
- The token has no relation to Docket's behaviour; it is the launch kind's own reward token, minted once
  to the factory, which is the only party that can distribute it.
- Whether a pool is seeded is decided by the launch policy and the manifest step, not by this source.

**What it is.** A dependency-free fixed-supply ERC-20 (the project vendors no libraries and `lib/` is
protected, so nothing could be imported):

- name `Docket`, symbol `DOCKET`, 18 decimals (the brief names no token, so the project name is used);
- exactly 1,000,000,000 tokens (10^27 minor units) minted to `msg.sender` in the constructor, so the
  factory holds the whole supply at launch;
- `transfer`, `approve`, `transferFrom`, `allowance`, `balanceOf`, `totalSupply` plus `Transfer` and
  `Approval` events; `totalSupply` is a compile-time constant, so no code path can change it;
- no constructor arguments, no owner, mint, burn, pause, blocklist, fee, hook, proxy or upgrade
  function; no DELEGATECALL, CALLCODE or SELFDESTRUCT; no `receive`/`fallback`, so it rejects ETH;
- runtime 2,449 bytes, far under EIP-170.

## Change 2: `test/LaunchToken.t.sol` (added)

**Rule.** "Every application contract needs meaningful tests" and "every change is tested". Written
against the project's own cheatcode shim (`test/helpers/TestBase.sol`), like the accepted suite, because
the project has no forge-std. Thirteen tests, including a fuzz test:

- metadata, 18 decimals and the exact 10^27 supply;
- the constructor's single mint `Transfer` event from the zero address to the deployer;
- `transfer` moves exactly the amount and conserves supply (unit and fuzz, including the round trip and
  the one-more-than-balance revert);
- insufficient balance, zero recipient, insufficient allowance, and allowance-without-balance reverts;
- infinite allowance is not decremented;
- every selector the protected token floor probes (`mint`, `issue`, `setOwner`, `transferOwnership`,
  `upgradeTo`, `initialize`, `unpause`, `setMinter`) reverts and leaves supply and balances unchanged,
  including when the deployer calls;
- ETH and unknown selectors are rejected;
- a factory stand-in deploys the token and then Docket with CREATE2 from one address, and the factory
  still holds the whole supply after Docket's constructor (mirrors `Project.protected.t.sol`);
- both runtimes are non-empty, at most 24,576 bytes, and contain no DELEGATECALL, CALLCODE or
  SELFDESTRUCT after stepping over PUSH immediates (mirrors both protected floors).

## Change 3: `README.md` (section added)

A short "Launch through ProjectFactory" section describing the token and the manifest shape, so the
README no longer states that no token was added. The accepted README content is otherwise untouched.

## Audit finding

### `45d7c9e53ac8db3d9ee2abe9b15f5778df42a6684060c9ea182d88c6da86aa6c` (medium) — the supplied manifest cannot admit the tokenless project

**Reproduced.** `launch.json` in the tree as it arrived has `"token": null` and a non-null `pool`;
`jq '.token' launch.json` prints `null`, and a JSON Schema requiring `token` to be an object rejects
it, exactly as the finding describes. The protected project floor also reads `IMD_TOKEN_CREATION_CODE`
unconditionally and requires a positive supply, so there was no admissible path for the tree as it
arrived.

**Disposition: fixed at the root cause, within this task's scope.** The manifest could not be valid
because the tree had no token contract for it to name. `src/LaunchToken.sol` now exists and satisfies
every check the protected token floor and project floor make (fixed supply to the deployer, decimals,
exact transfer, no mint or admin selectors, no escape opcodes), so the manifest step can write a
conforming `launch.json` with `token` naming `LaunchToken` (`Docket` / `DOCKET` / 18) and `contracts`
= `[{"contract": "Docket", "constructorArgs": []}]`. `launch.json` itself is not rewritten here because
the reference assigns it to the next step ("The manifest is written by the step after you; do not write
launch.json"). The finding's alternative resolution, an authorised contract-only admission path, is not
something this repository can provide; the prior attempt that waited for one was rejected.

**Test.** `testFactoryDeploymentKeepsSupplyWithFactoryAcrossDocketConstructor`,
`testNoAdminOrMintSelectorExists` and `testRuntimeIsBoundedAndHasNoEscapeOpcodes` in
`test/LaunchToken.t.sol` reproduce the protected floors' checks against the delivered creation code.

## Checks run

```
forge build --offline --force          # clean compile, no compiler warnings
forge test --offline                   # 57 passed, 0 failed (44 accepted + 13 new)
forge test --offline --isolate --match-contract LaunchTokenTest   # 13 passed
forge fmt --check                      # clean
```

`forge build --deny warnings` on Foundry 1.8.3 aborts on three post-build *linter* hints
(`environment-read-across-mutation`, `block.chainid` after `vm.chainId`) in the accepted
`test/Docket.t.sol`. They are lint notes from a Foundry release newer than the one the README was
written against (1.7.1), not compiler warnings, and they are in an accepted test the brief says to reuse
unchanged, so they were left alone. No new warning or lint note comes from the added files.

## Out of scope for this step

Admission, deployment to the allowed chain, recording of address, transaction hash and block, explorer
verification and publication are performed by the network's own deployer after review. A contributor
task never holds a key or broadcasts. The chain is whatever the request's policy allows; nothing in this
tree is chain-specific (no constructor arguments, no chain constants).
