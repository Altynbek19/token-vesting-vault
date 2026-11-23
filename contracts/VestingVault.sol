// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title VestingVault — token vesting with cliff, linear unlock and revocation (STUDENT STARTER)
/// @notice One vault holds tokens for many beneficiaries. The owner (e.g. the project team)
///         creates schedules; beneficiaries (team, investors, advisors) receive tokens over time.
contract VestingVault is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============================================================
    //  PROVIDED PART (identical to the student starter file)
    // ============================================================
    struct Schedule {
        address beneficiary;
        uint256 total;      // total tokens promised
        uint256 released;   // tokens already paid out
        uint64 start;       // unix time when vesting starts
        uint64 cliff;       // seconds after `start` before ANY token vests
        uint64 duration;    // seconds after `start` when 100% is vested
        uint64 revokedAt;   // 0 while not revoked
        bool revocable;
        bool revoked;
    }

    IERC20 public immutable token;
    uint256 public scheduleCount;                       // ids start from 1
    uint256 public totalAllocated;                      // tokens promised to beneficiaries and not yet paid out
    mapping(uint256 => Schedule) public schedules;
    mapping(address => uint256[]) private _schedulesOf;

    event ScheduleCreated(uint256 indexed id, address indexed beneficiary, uint256 amount, uint64 start, uint64 cliff, uint64 duration, bool revocable);
    event Released(uint256 indexed id, address indexed beneficiary, uint256 amount);
    event Revoked(uint256 indexed id, uint256 returnedToOwner);
    event ScheduleTransferred(uint256 indexed id, address indexed from, address indexed to);

    constructor(IERC20 token_) Ownable(msg.sender) {
        require(address(token_) != address(0), "zero token");
        token = token_;
    }

    // ============================================================
    //  YOUR CODE STARTS HERE
    // ============================================================

    /// @notice Creates a new vesting schedule for a beneficiary.
    /// @param beneficiary Address that will receive the vested tokens.
    /// @param amount Total amount of tokens locked in this schedule.
    /// @param start Unix timestamp when vesting begins.
    /// @param cliff Duration in seconds after `start` before any tokens vest.
    /// @param duration Total vesting duration in seconds from `start`.
    /// @param revocable Whether the owner can revoke unvested tokens.
    /// @return id The unique identifier of the created schedule.
    function createSchedule(
        address beneficiary,
        uint256 amount,
        uint64 start,
        uint64 cliff,
        uint64 duration,
        bool revocable
    ) external onlyOwner returns (uint256 id) {
        require(beneficiary != address(0), "zero beneficiary");
        require(amount > 0, "zero amount");
        require(duration > 0, "zero duration");
        require(cliff <= duration, "cliff > duration");

        uint256 available = token.balanceOf(address(this)) - totalAllocated;
        require(available >= amount, "insufficient unallocated balance");

        id = ++scheduleCount;
        schedules[id] = Schedule({
            beneficiary: beneficiary,
            total: amount,
            released: 0,
            start: start,
            cliff: cliff,
            duration: duration,
            revokedAt: 0,
            revocable: revocable,
            revoked: false
        });

        _schedulesOf[beneficiary].push(id);
        totalAllocated += amount;

        emit ScheduleCreated(id, beneficiary, amount, start, cliff, duration, revocable);
    }

    /// @notice Calculates the total amount of tokens vested for a schedule up to the current time (or revocation time).
    /// @param id The schedule identifier.
    /// @return The amount of vested tokens.
    function vestedAmount(uint256 id) public view returns (uint256) {
        _requireExists(id);
        return _vested(schedules[id]);
    }

    /// @notice Calculates the amount of tokens currently available for withdrawal.
    /// @param id The schedule identifier.
    /// @return The releasable token amount (`vested - released`).
    function releasable(uint256 id) public view returns (uint256) {
        _requireExists(id);
        Schedule storage s = schedules[id];
        return _vested(s) - s.released;
    }

    /// @notice Transfers all currently releasable tokens of a schedule to its beneficiary.
    /// @dev Anyone can trigger this function; tokens are always sent to `schedule.beneficiary`.
    /// @param id The schedule identifier.
    function release(uint256 id) external nonReentrant {
        _requireExists(id);
        Schedule storage s = schedules[id];

        uint256 amount = _vested(s) - s.released;
        require(amount > 0, "nothing to release");

        s.released += amount;
        totalAllocated -= amount;

        emit Released(id, s.beneficiary, amount);
        token.safeTransfer(s.beneficiary, amount);
    }

    /// @notice Revokes an active revocable schedule, returning unvested tokens to the owner.
    /// @dev Freezes vesting at `block.timestamp`. Already vested tokens remain claimable by the beneficiary.
    /// @param id The schedule identifier.
    function revoke(uint256 id) external onlyOwner nonReentrant {
        _requireExists(id);
        Schedule storage s = schedules[id];

        require(s.revocable, "not revocable");
        require(!s.revoked, "already revoked");

        uint256 vested = _vested(s);
        uint256 unvested = s.total - vested;

        s.revoked = true;
        s.revokedAt = uint64(block.timestamp);

        if (unvested > 0) {
            totalAllocated -= unvested;
        }

        emit Revoked(id, unvested);

        if (unvested > 0) {
            token.safeTransfer(owner(), unvested);
        }
    }

    /// @notice Withdraws tokens held by the vault that are not allocated to any schedule.
    /// @param to Recipient address for the unallocated tokens.
    /// @return amount The amount of tokens withdrawn.
    function withdrawUnallocated(address to) external onlyOwner nonReentrant returns (uint256 amount) {
        require(to != address(0), "zero address");
        uint256 balance = token.balanceOf(address(this));
        amount = balance - totalAllocated;
        require(amount > 0, "nothing to withdraw");

        token.safeTransfer(to, amount);
    }

    /// @notice Returns all schedule IDs currently owned by a given beneficiary.
    /// @param beneficiary Address to query.
    /// @return Array of schedule IDs.
    function schedulesOf(address beneficiary) external view returns (uint256[] memory) {
        return _schedulesOf[beneficiary];
    }

    /// @notice Transfers ownership of a vesting schedule to a new beneficiary address.
    /// @param id The schedule identifier.
    /// @param newBeneficiary The new recipient address.
    function transferSchedule(uint256 id, address newBeneficiary) external {
        _requireExists(id);
        Schedule storage s = schedules[id];

        address oldBeneficiary = s.beneficiary;
        require(msg.sender == oldBeneficiary, "not beneficiary");
        require(newBeneficiary != address(0), "zero beneficiary");
        require(newBeneficiary != oldBeneficiary, "same beneficiary");

        s.beneficiary = newBeneficiary;

        uint256[] storage oldList = _schedulesOf[oldBeneficiary];
        uint256 len = oldList.length;
        for (uint256 i = 0; i < len; i++) {
            if (oldList[i] == id) {
                oldList[i] = oldList[len - 1];
                oldList.pop();
                break;
            }
        }

        _schedulesOf[newBeneficiary].push(id);

        emit ScheduleTransferred(id, oldBeneficiary, newBeneficiary);
    }

    function _requireExists(uint256 id) internal view {
        require(id > 0 && id <= scheduleCount, "unknown schedule");
    }

    function _vested(Schedule storage s) internal view returns (uint256) {
        uint256 t = s.revoked ? uint256(s.revokedAt) : block.timestamp;
        uint256 start = uint256(s.start);
        uint256 cliffEnd = start + uint256(s.cliff);
        uint256 end = start + uint256(s.duration);

        if (t < cliffEnd) {
            return 0;
        }
        if (t >= end) {
            return s.total;
        }
        return (s.total * (t - start)) / uint256(s.duration);
    }
}