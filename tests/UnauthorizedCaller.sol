// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../contracts/VestingVault.sol";

contract UnauthorizedCaller {
    function callCreate(VestingVault vault, address beneficiary) external {
        vault.createSchedule(beneficiary, 100 ether, uint64(block.timestamp), 0, 100, false);
    }

    function callRevoke(VestingVault vault, uint256 id) external {
        vault.revoke(id);
    }

    function callWithdrawUnallocated(VestingVault vault, address to) external {
        vault.withdrawUnallocated(to);
    }

    function callTransferSchedule(VestingVault vault, uint256 id, address to) external {
        vault.transferSchedule(id, to);
    }
}