// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ILeverageZapper} from "../src/Zappers/Interfaces/ILeverageZapper.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

interface IWZ {
    function withdrawCollToRawETH(uint256, uint256) external;
    function closeTroveToRawETH(uint256) external;
}
interface IWZ2 { function closeTroveToRawETH(uint256) external; }

interface IReg {
    function boldToken() external view returns (address);
    function troveManager() external view returns (address);
}

/// @notice PoC: leverage-zap leftovers are permanently trapped in the zapper when the
/// operation is driven by a remove manager (the intended automation path), because the
/// trove's receiver must be the zapper and _returnLeftovers() then self-transfers.
contract SubmissionReceiverValidation is Test {
    function payoutReceiver() internal view virtual returns (address) { return ZAPPER; }
    address constant ZAPPER = 0xdCcBD7A365aeE086aa3b4EDe8afe895B20770AE3;
    address constant REGISTRY = 0x20F7C9ad66983F6523a0881d0f82406541417526;
    address constant COLLREG = 0xf949982B91C8c61e952B3bA942cbbfaef5386684;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    address user = address(0xA11CE);
    address bot = address(0xB0B);

    IERC20 bold;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), 26_346_800);
        bold = IERC20(IReg(COLLREG).boldToken());
    }

    function testLeftoversAreStuckInZapper() public {
        vm.deal(user, 10 ether);
        uint256 collAmount = 2 ether;

        ILeverageZapper.OpenLeveragedTroveParams memory p;
        p.owner = user;
        p.ownerIndex = 0;
        p.collAmount = collAmount;
        p.flashLoanAmount = 1 ether;
        p.boldAmount = 4500e18;
        p.annualInterestRate = 5e16;
        p.maxUpfrontFee = type(uint256).max;
        p.removeManager = bot;
        p.receiver = payoutReceiver(); // required for any later zapper call

        vm.prank(user);
        ILeverageZapper(ZAPPER).openLeveragedTroveWithRawETH{value: collAmount + 0.0375 ether}(p);

        uint256 ownerIndex = uint256(keccak256(abi.encode(user, uint256(0))));
        uint256 troveId = uint256(keccak256(abi.encode(ZAPPER, user, ownerIndex)));

        uint256 zapperBoldBefore = bold.balanceOf(ZAPPER);
        uint256 userBoldBefore = bold.balanceOf(user);

        // manager drives a deleverage whose swap output exceeds (debt - MIN_DEBT):
        // BO caps the repayment, the surplus BOLD is left in the zapper and returned to
        // the receiver - which is the zapper itself.
        vm.prank(bot);
        ILeverageZapper(ZAPPER).leverDownTrove(
            ILeverageZapper.LeverDownTroveParams({troveId: troveId, flashLoanAmount: 1.5 ether, minBoldAmount: 1})
        );

        uint256 stuck = bold.balanceOf(ZAPPER) - zapperBoldBefore;
        emit log_named_uint("bold stuck in zapper", stuck);
        emit log_named_uint("bold gained by user", bold.balanceOf(user) - userBoldBefore);
        if (payoutReceiver() == ZAPPER) {
            assertGt(stuck, 100e18);
            assertEq(bold.balanceOf(user) - userBoldBefore, 0);
        } else {
            assertEq(stuck, 0);
            assertGt(bold.balanceOf(user) - userBoldBefore, 100e18);
        }

        // a later owner-driven zap does not sweep the stuck balance either
        vm.prank(user);
        IWZ(ZAPPER).withdrawCollToRawETH(troveId, 0.01 ether);
        assertEq(bold.balanceOf(ZAPPER), zapperBoldBefore + stuck);
        emit log_named_uint("still stuck after second zap", bold.balanceOf(ZAPPER));
    }

    /// @notice second, worse variant: when a remove manager withdraws collateral through the
    /// zapper, 100% of the withdrawn collateral lands on the receiver == the zapper.
    function testManagerWithdrawCollIsStuck() public {
        vm.deal(user, 10 ether);
        uint256 collAmount = 2 ether;

        ILeverageZapper.OpenLeveragedTroveParams memory p;
        p.owner = user;
        p.ownerIndex = 0;
        p.collAmount = collAmount;
        p.flashLoanAmount = 0;
        p.boldAmount = 3000e18;
        p.annualInterestRate = 5e16;
        p.maxUpfrontFee = type(uint256).max;
        p.removeManager = bot;
        p.receiver = payoutReceiver();

        vm.prank(user);
        ILeverageZapper(ZAPPER).openLeveragedTroveWithRawETH{value: collAmount + 0.0375 ether}(p);

        uint256 ownerIndex = uint256(keccak256(abi.encode(user, uint256(0))));
        uint256 troveId = uint256(keccak256(abi.encode(ZAPPER, user, ownerIndex)));

        uint256 userWeth = user.balance;
        uint256 zapperWeth = ZAPPER.balance;

        vm.prank(bot);
        IWZ(ZAPPER).withdrawCollToRawETH(troveId, 0.5 ether);

        emit log_named_uint("eth gained by user", user.balance - userWeth);
        emit log_named_uint("eth stuck in zapper", ZAPPER.balance - zapperWeth);
        assertEq(user.balance - userWeth, payoutReceiver() == ZAPPER ? 0 : 0.5 ether);
        assertEq(ZAPPER.balance - zapperWeth, payoutReceiver() == ZAPPER ? 0.5 ether : 0);
    }

    /// @notice third variant: closing the trove from a remove manager loses the entire
    /// collateral plus the gas compensation to the zapper.
    function testManagerCloseTroveIsStuck() public {
        vm.deal(user, 10 ether);
        uint256 collAmount = 2 ether;

        ILeverageZapper.OpenLeveragedTroveParams memory p;
        p.owner = user;
        p.ownerIndex = 0;
        p.collAmount = collAmount;
        p.flashLoanAmount = 0;
        p.boldAmount = 3000e18;
        p.annualInterestRate = 5e16;
        p.maxUpfrontFee = type(uint256).max;
        p.removeManager = bot;
        p.receiver = payoutReceiver();

        vm.prank(user);
        ILeverageZapper(ZAPPER).openLeveragedTroveWithRawETH{value: collAmount + 0.0375 ether}(p);

        uint256 ownerIndex = uint256(keccak256(abi.encode(user, uint256(0))));
        uint256 troveId = uint256(keccak256(abi.encode(ZAPPER, user, ownerIndex)));

        // bot must be able to fund the full repayment
        deal(address(bold), bot, 1e24);
        uint256 userEth = user.balance;
        uint256 zapperEth = ZAPPER.balance;

        vm.prank(bot);
        bold.approve(ZAPPER, type(uint256).max);
        uint256 collBeforeClose = ZAPPER.balance;
        vm.prank(bot);
        IWZ2(ZAPPER).closeTroveToRawETH(troveId);

        emit log_named_uint("eth gained by user", user.balance - userEth);
        emit log_named_uint("eth stuck in zapper", ZAPPER.balance - zapperEth);
        assertEq(user.balance - userEth, payoutReceiver() == ZAPPER ? 0 : collAmount + 0.0375 ether);
        assertEq(ZAPPER.balance - collBeforeClose, payoutReceiver() == ZAPPER ? collAmount + 0.0375 ether : 0);
    }
}

contract SubmissionOwnerReceiverControl is SubmissionReceiverValidation {
    function payoutReceiver() internal view override returns (address) { return user; }
}
