// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "remix_tests.sol";
import "remix_accounts.sol";
import "../contracts/VestingVault.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./UnauthorizedCaller.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Mock", "MCK") {
        _mint(msg.sender, 10_000_000 ether);
    }
}
// contract UnauthorizedCaller {
//     function callCreate(VestingVault vault, address beneficiary) external {
//         vault.createSchedule(beneficiary, 100 ether, uint64(block.timestamp), 0, 100, false);
//     }

//     function callRevoke(VestingVault vault, uint256 id) external {
//         vault.revoke(id);
//     }

//     function callWithdrawUnallocated(VestingVault vault, address to) external {
//         vault.withdrawUnallocated(to);
//     }

//     function callTransferSchedule(VestingVault vault, uint256 id, address to) external {
//         vault.transferSchedule(id, to);
//     }
// }

contract VestingVaultTest {
    MockToken token;
    VestingVault vault;
    UnauthorizedCaller stranger;
    address charlie;

    address alice;
    address bob;

    function beforeAll() public {
        alice = TestsAccounts.getAccount(1);
        bob = TestsAccounts.getAccount(2);

        token = new MockToken();
        vault = new VestingVault(IERC20(address(token)));
        // Отправляем в хранилище 500 000 токенов
        charlie = TestsAccounts.getAccount(3);
        stranger = new UnauthorizedCaller();
        token.transfer(address(vault), 4_500_000 ether);
    }

    // 1. Создание расписания и проверка до конца cliff
    function testCreateAndCliff() public {
        uint64 start = uint64(block.timestamp);
        uint256 id = vault.createSchedule(alice, 100_000 ether, start, 1000, 10000, true);

        Assert.equal(id, uint256(1), "Schedule ID should be 1");
        Assert.equal(vault.vestedAmount(id), uint256(0), "Should be 0 during cliff");
        Assert.equal(vault.releasable(id), uint256(0), "Releasable should be 0 during cliff");
        Assert.equal(vault.totalAllocated(), 100_000 ether, "totalAllocated should be 100k");
    }

    // 2. Ретроактивный старт в прошлом: половина срока уже прошла -> 50% доступно сразу
    function testPastStartAndRelease() public {
        uint64 start = uint64(block.timestamp - 500);
        uint256 id = vault.createSchedule(alice, 100_000 ether, start, 100, 1000, true);

        Assert.equal(vault.vestedAmount(id), 50_000 ether, "Half should be vested");
        Assert.equal(vault.releasable(id), 50_000 ether, "Half should be releasable");

        vault.release(id);

        Assert.equal(token.balanceOf(alice), 50_000 ether, "Alice should receive 50k");
        Assert.equal(vault.releasable(id), uint256(0), "Releasable should be 0 after release");
        Assert.equal(vault.totalAllocated(), 150_000 ether, "totalAllocated should drop by 50k");
    }

    // 3. Проверка отзыва (revoke): неразблокированное возвращается владельцу
    function testRevoke() public {
        uint64 start = uint64(block.timestamp - 200);
        uint256 id = vault.createSchedule(alice, 100_000 ether, start, 100, 1000, true);
        // Разблокировано 20% (20 000), не разблокировано 80% (80 000)

        uint256 ownerBefore = token.balanceOf(address(this));
        vault.revoke(id);
        uint256 ownerAfter = token.balanceOf(address(this));

        Assert.equal(ownerAfter - ownerBefore, 80_000 ether, "Owner should get back unvested 80k");
        Assert.equal(vault.vestedAmount(id), 20_000 ether, "Vested should stay frozen at 20k");
    }

    // 4. Нельзя пообещать больше токенов, чем свободно в хранилище
    function testCannotOverAllocate() public {
        uint64 start = uint64(block.timestamp);
        try vault.createSchedule(alice, 10_000_000 ether, start, 0, 1000, false) {
            Assert.ok(false, "Should revert on over-allocation");
        } catch Error(string memory reason) {
            Assert.equal(reason, "insufficient unallocated balance", "Wrong revert reason");
        }
    }

    // 5. Вывод нераспределённых токенов (withdrawUnallocated)
    function testWithdrawUnallocated() public {
        uint256 expectedUnallocated = token.balanceOf(address(vault)) - vault.totalAllocated();
        uint256 withdrawn = vault.withdrawUnallocated(bob);

        Assert.equal(withdrawn, expectedUnallocated, "Should withdraw exact unallocated surplus");
        Assert.equal(token.balanceOf(bob), expectedUnallocated, "Bob should receive surplus");
    }
    // 6. Бонус: передача расписания другому получателю (transferSchedule)
    function testTransferSchedule() public {
        uint64 start = uint64(block.timestamp);
        // Сначала пополняем хранилище на 10 000 токенов и создаём расписание на address(this)
        token.transfer(address(vault), 10_000 ether);
        uint256 id = vault.createSchedule(address(this), 10_000 ether, start, 0, 1000, true);

        // Передаём расписание Бобу
        vault.transferSchedule(id, bob);

        uint256[] memory selfSchedules = vault.schedulesOf(address(this));
        uint256[] memory bobSchedules = vault.schedulesOf(bob);

        Assert.equal(selfSchedules.length, uint256(0), "Old beneficiary should have 0 schedules");
        Assert.equal(bobSchedules.length, uint256(1), "Bob should have 1 schedule now");
        Assert.equal(bobSchedules[0], id, "Transferred schedule ID should match");
    }
    // 7. Контрольные точки формулы: до start, ровно на cliff, ровно на duration, после конца
    function testVestingTimelineCheckpoints() public {
        uint64 nowTs = uint64(block.timestamp);
        uint256 amount = 100_000 ether;
        token.transfer(address(vault), 500_000 ether);

        uint256 idBeforeStart = vault.createSchedule(charlie, amount, nowTs + 500, 200, 1000, false);
        Assert.equal(vault.vestedAmount(idBeforeStart), uint256(0), "Before start must be 0");

        uint256 idAtCliff = vault.createSchedule(charlie, amount, nowTs - 200, 200, 1000, false);
        Assert.equal(vault.vestedAmount(idAtCliff), 20_000 ether, "At exact cliff must unlock 20%");

        uint256 idAtEnd = vault.createSchedule(charlie, amount, nowTs - 1000, 200, 1000, false);
        Assert.equal(vault.vestedAmount(idAtEnd), amount, "At exact duration must be 100%");

        uint256 idAfterEnd = vault.createSchedule(charlie, amount, nowTs - 5000, 200, 1000, false);
        Assert.equal(vault.vestedAmount(idAfterEnd), amount, "After duration must cap at 100%");
    }

    // 8. Выплата доступного остатка и запрет повторного release при releasable == 0
    function testSequentialReleaseAndZeroReleasableRevert() public {
        uint64 nowTs = uint64(block.timestamp);
        uint256 id = vault.createSchedule(charlie, 40_000 ether, nowTs - 1000, 0, 1000, false);

        uint256 charlieBefore = token.balanceOf(charlie);
        vault.release(id);
        uint256 charlieAfter = token.balanceOf(charlie);

        // Assert.equal(paid, 40_000 ether, "Should release full 40k");
        Assert.equal(charlieAfter - charlieBefore, 40_000 ether, "Charlie balance should increase by 40k");
        Assert.equal(vault.releasable(id), uint256(0), "Nothing left to release");

        try vault.release(id) {
            Assert.ok(false, "Second release with 0 releasable should revert");
        } catch {
            Assert.ok(true, "Reverted as expected");
        }
    }

    // 9. Отзыв до окончания cliff: возвращается 100% суммы
    function testRevokeBeforeCliff() public {
        uint64 nowTs = uint64(block.timestamp);
        uint256 id = vault.createSchedule(charlie, 30_000 ether, nowTs, 500, 1000, true);

        uint256 ownerBefore = token.balanceOf(address(this));
        vault.revoke(id);
        uint256 ownerAfter = token.balanceOf(address(this));

        // Assert.equal(returned, 30_000 ether, "All 30k should return before cliff");
        Assert.equal(ownerAfter - ownerBefore, 30_000 ether, "Owner should receive all 30k");
        Assert.equal(vault.vestedAmount(id), uint256(0), "Vested must remain 0");
    }

    // 10. После revoke получатель забирает только разблокированную до отзыва часть
    function testReleaseAfterRevokeClaimsOnlyVested() public {
        token.transfer(address(vault), 500_000 ether);
        uint64 nowTs = uint64(block.timestamp);
        uint256 id = vault.createSchedule(charlie, 100_000 ether, nowTs - 300, 100, 1000, true);
        // token.transfer(address(vault), 500_000 ether);

        vault.revoke(id);

        uint256 charlieBefore = token.balanceOf(charlie);
        vault.release(id);
        uint256 charlieAfter = token.balanceOf(charlie);

        // Assert.equal(claimed, 30_000 ether, "Charlie should claim only vested 30k");
        Assert.equal(charlieAfter - charlieBefore, 30_000 ether, "Charlie balance should increase by 30k");
        Assert.equal(vault.releasable(id), uint256(0), "No further tokens releasable after claim");
    }

    // 11. Отзыв после полного окончания вестинга возвращает 0
    function testRevokeAfterFullVesting() public {
        // token.transfer(address(vault), 500_000 ether);
        uint64 nowTs = uint64(block.timestamp);
        uint256 id = vault.createSchedule(charlie, 25_000 ether, nowTs - 2000, 100, 1000, true);

        uint256 ownerBefore = token.balanceOf(address(this));
        vault.revoke(id);
        uint256 ownerAfter = token.balanceOf(address(this));

        Assert.equal(ownerAfter - ownerBefore, uint256(0), "Unvested returned should be 0 after full duration");
        Assert.equal(vault.releasable(id), 25_000 ether, "Full 25k must still be releasable");
    }

    // 12. Нельзя отозвать неотзывное расписание (revocable == false)
    function testCannotRevokeNonRevocable() public {
        token.transfer(address(vault), 500_000 ether);
        uint64 nowTs = uint64(block.timestamp);
        uint256 id = vault.createSchedule(charlie, 10_000 ether, nowTs, 0, 1000, false);

        try vault.revoke(id) {
            Assert.ok(false, "Revoking non-revocable schedule must revert");
        } catch {
            Assert.ok(true, "Reverted as expected");
        }
    }

    // 13. Проверка прав доступа посторонним адресом
    function testAccessControl() public {
        token.transfer(address(vault), 500_000 ether);
        uint64 nowTs = uint64(block.timestamp);
        uint256 id = vault.createSchedule(charlie, 10_000 ether, nowTs, 0, 1000, true);

        try stranger.callCreate(vault, charlie) {
            Assert.ok(false, "Stranger should not create schedule");
        } catch {
            Assert.ok(true, "Create access control passed");
        }

        try stranger.callRevoke(vault, id) {
            Assert.ok(false, "Stranger should not revoke");
        } catch {
            Assert.ok(true, "Revoke access control passed");
        }

        try stranger.callWithdrawUnallocated(vault, address(stranger)) {
            Assert.ok(false, "Stranger should not withdraw unallocated");
        } catch {
            Assert.ok(true, "Withdraw access control passed");
        }

        try stranger.callTransferSchedule(vault, id, address(stranger)) {
            Assert.ok(false, "Stranger should not transfer schedule");
        } catch {
            Assert.ok(true, "TransferSchedule access control passed");
        }
    }

    // 14. Fuzz-проверка: vestedAmount <= total и неубывание со временем
    function testFuzzVestedAmountBounds() public {
        token.transfer(address(vault), 500_000 ether);
        uint64 nowTs = uint64(block.timestamp);
        uint64 duration = 10_000;
        uint64 cliff = 1_000;

        for (uint256 i = 1; i <= 10; i++) {
            uint256 rand = uint256(keccak256(abi.encodePacked(nowTs, i)));
            uint256 amount = (rand % 10_000 ether) + 1 ether;
            uint64 elapsedEarlier = uint64(rand % 12_000);
            uint64 elapsedLater = elapsedEarlier + uint64((rand >> 16) % 5_000);

            uint256 idEarlier = vault.createSchedule(charlie, amount, nowTs - elapsedEarlier, cliff, duration, false);
            uint256 idLater = vault.createSchedule(charlie, amount, nowTs - elapsedLater, cliff, duration, false);

            uint256 vestedEarlier = vault.vestedAmount(idEarlier);
            uint256 vestedLater = vault.vestedAmount(idLater);

            Assert.ok(vestedEarlier <= amount, "Fuzz: vestedEarlier must not exceed total");
            Assert.ok(vestedLater <= amount, "Fuzz: vestedLater must not exceed total");
            Assert.ok(vestedLater >= vestedEarlier, "Fuzz: vested amount must be monotonic over time");
        }
    }
    
    
}