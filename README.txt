# VestingVault

An ERC-20 token vesting vault for token projects, DAOs, and teams to manage cliff and linear vesting schedules with optional revocability and beneficiary schedule transfers.

## Vesting Schedule & Release Behavior

Example schedule with a **12-month cliff** inside a **48-month total linear vesting window** (100,000 tokens total):

| Timeline Point | Elapsed Since `start` | Vested % | Vested Tokens | Notes |
| :--- | :--- | :--- | :--- | :--- |
| Before `start` | `< 0` | `0%` | `0` | Vesting has not started (`block.timestamp < start`) |
| During Cliff (e.g., Month 6) | `6 mo` (`< cliff`) | `0%` | `0` | Locked until `start + cliff`; `releasable` is `0` |
| Cliff Reached (Month 12) | `12 mo` (`== cliff`) | `25%` | `25,000` | Linear curve unlocks `12 / 48` once cliff is reached |
| Mid-Vesting (Month 30) | `30 mo` | `62.5%` | `62,500` | Proportional to `total * (t - start) / duration` (floor division) |
| Fully Vested (Month 48+) | `>= 48 mo` (`>= duration`) | `100%` | `100,000` | Capped at total schedule allocation |

```text
0%                                     25% (Cliff)                        100%
|----------------[ Locked ]------------|==========[ Linear Vest ]==========|---> Time
start                              start+cliff                      start+duration
```

## Running Tests & Coverage

* **Foundry:**
  * Run `forge test` to execute the test suite.
  * Run `forge coverage` to view line, branch, and function coverage.
* **Hardhat:**
  * Run `npx hardhat test` to execute the test suite.
  * Run `npx hardhat coverage` (with `solidity-coverage`) to inspect coverage reports.
* **Remix IDE (Solidity Unit Testing):**
  * Compile `VestingVault.sol` and `VestingVault_test.sol` in Remix IDE, open the **Solidity Unit Testing** plugin tab, and run the test suite.

**Coverage Result:** The unit test suite passes all checks and covers core schedule creation, cliff/linear/full vesting calculations, `release`, `revoke`, `withdrawUnallocated`, and `transferSchedule`, alongside edge-case, access-control, and fuzz testing scenarios.

## Security Model

### Roles & Permissions
* **Owner (`onlyOwner` via OpenZeppelin `Ownable`):**
  * Creates vesting schedules via `createSchedule` when available unallocated balance (`token.balanceOf(address(this)) - totalAllocated`) is sufficient.
  * Revokes revocable schedules (`revocable == true`) via `revoke`, freezing vesting at `revokedAt`, returning unvested tokens to `owner`, and preserving vested tokens for `beneficiary`.
  * Withdraws unallocated surplus tokens via `withdrawUnallocated(to)` (`balance - totalAllocated`).
  * Transfers or renounces ownership.
* **Beneficiary (`s.beneficiary`):**
  * Transfers schedule ownership to a non-zero `newBeneficiary` via `transferSchedule(id, newBeneficiary)`, updating `schedulesOf`.
* **Any Caller (`msg.sender`):**
  * Calls `release(id)` to send `releasable` tokens directly to `s.beneficiary`.
  * Reads contract state via view functions (`vestedAmount`, `releasable`, `schedules`, `schedulesOf`, `totalAllocated`, `scheduleCount`, `token`, `owner`).

### What Happens If the Owner Is Malicious or the Owner Key Is Compromised
* **What an attacker/malicious owner CANNOT do:**
  * Cannot steal tokens reserved for active schedules via `withdrawUnallocated`, because `withdrawUnallocated` only transfers `balance - totalAllocated`.
  * Cannot revoke non-revocable schedules (`revocable == false`) or claw back already vested portions of schedules.
* **What an attacker/malicious owner CAN do:**
  * Can create new schedules up to the vault's unallocated token balance.
  * Can revoke schedules marked `revocable == true`, returning their unvested portion to the owner.
  * Can transfer contract ownership if ownership is not guarded by a multisig or timelock.

### Risks Mitigated & Not Mitigated
* **Mitigated:**
  * **Reentrancy:** `release` uses OpenZeppelin `ReentrancyGuard` (`nonReentrant`) and follows Checks-Effects-Interactions (updating `released` and `totalAllocated` before `safeTransfer`).
  * **Integer Overflow / Underflow:** Protected by Solidity `^0.8.x` checked arithmetic, with multiplication before division (`total * (t - start) / duration`) and floor rounding.
  * **Over-allocation / Unbacked Promises:** Enforced by checking `token.balanceOf(address(this)) - totalAllocated >= amount` in `createSchedule` and restricting `withdrawUnallocated` to unallocated tokens.
* **Not Mitigated:**
  * **Centralized Single-Owner Risk:** No multisig, timelock, or granular access control is enforced out of the box.
  * **Unclaimed Vested Tokens After Revocation:** Vested tokens remain in the vault for `beneficiary` to claim via `release` rather than being automatically swept.
  * **Block Timestamp Variance:** Relies on `block.timestamp`, which is appropriate for multi-day/multi-month vesting schedules rather than sub-minute precision.

## Known Limitations

* **Fee-on-Transfer / Deflationary Tokens:** Not supported accurately because accounting tracks nominal `amount` and `totalAllocated` rather than measuring actual post-transfer balance changes.
* **Rebasing Tokens:** Elastic or rebasing token balances that change without transfers can cause `token.balanceOf(address(this))` to diverge from `totalAllocated`.
* **Non-Standard or Restrictive ERC-20s:** Tokens with transfer hooks, blacklists, or pauses may cause `release`, `revoke`, or `withdrawUnallocated` to revert.
* **Linear Schedules Only:** Supports cliff + linear release; custom milestone or step-vesting curves are not supported.