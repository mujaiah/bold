// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IZapper} from "../src/Zappers/Interfaces/IZapper.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

interface IGCZ {
    function openTroveWithRawETH(IZapper.OpenTroveParams calldata) external payable returns (uint256);
    function withdrawColl(uint256, uint256) external;
    function closeTroveToRawETH(uint256) external;
}

interface IRegB {
    function boldToken() external view returns (address);
}

/// @notice Same class as LeftoverStuck, reproduced on the wstETH branch's GasCompZapper.
contract GasCompStuck is Test {
    address constant GCZ = 0xBD69D3e0eA967d146E925b7572B765c8E9C4127D;
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant COLLREG = 0xf949982B91C8c61e952B3bA942cbbfaef5386684;

    IERC20 wsteth;
    IERC20 bold;
    address user = address(0xA11CE);
    address bot = address(0xB0B);

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), 26_346_800);
        wsteth = IERC20(WSTETH);
        bold = IERC20(IRegB(COLLREG).boldToken());
        vm.deal(user, 1 ether);
    }

    function _open(address manager) internal returns (uint256 id) {
        deal(WSTETH, user, 2 ether);
        vm.startPrank(user);
        wsteth.approve(GCZ, type(uint256).max);
        IZapper.OpenTroveParams memory p = IZapper.OpenTroveParams({
            owner: user,
            ownerIndex: 0,
            collAmount: 1 ether,
            boldAmount: 2000e18,
            upperHint: 0,
            lowerHint: 0,
            annualInterestRate: 5e16,
            batchManager: address(0),
            maxUpfrontFee: type(uint256).max,
            addManager: address(0),
            removeManager: manager,
            receiver: GCZ
        });
        id = IGCZ(GCZ).openTroveWithRawETH{value: 0.0375 ether}(p);
        vm.stopPrank();
    }

    /// @notice a remove manager withdrawing collateral through the LST zapper loses 100% of it
    function testGasCompManagerWithdrawIsStuck() public {
        uint256 id = _open(bot);

        uint256 userBefore = wsteth.balanceOf(user);
        uint256 zapperBefore = wsteth.balanceOf(GCZ);

        vm.prank(bot);
        IGCZ(GCZ).withdrawColl(id, 0.1 ether);

        emit log_named_decimal_uint("wsteth gained by user", wsteth.balanceOf(user) - userBefore, 18);
        emit log_named_decimal_uint("wsteth stuck in zapper", wsteth.balanceOf(GCZ) - zapperBefore, 18);

        assertEq(wsteth.balanceOf(user), userBefore);
        assertGe(wsteth.balanceOf(GCZ) - zapperBefore, 0.1 ether - 1);
    }

    /// @notice the same when the OWNER (no manager) calls it: the receiver is still the zapper,
    /// because every zapper-opened trove must have the zapper as receiver
    function testGasCompOwnerWithdrawPaysOut() public {
        uint256 id = _open(bot);

        uint256 userBefore = wsteth.balanceOf(user);
        uint256 zapperBefore = wsteth.balanceOf(GCZ);

        vm.prank(user);
        IGCZ(GCZ).withdrawColl(id, 0.1 ether);

        emit log_named_decimal_uint("wsteth gained by user", wsteth.balanceOf(user) - userBefore, 18);
        emit log_named_decimal_uint("wsteth stuck in zapper", wsteth.balanceOf(GCZ) - zapperBefore, 18);

        // owner call resolves to the owner, so nothing is lost
        assertApproxEqRel(wsteth.balanceOf(user) - userBefore, 0.1 ether, 1e15);
        assertApproxEqAbs(wsteth.balanceOf(GCZ) - zapperBefore, 0, 1e9);
    }
}
