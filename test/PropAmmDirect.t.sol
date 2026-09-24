// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IPropPair} from "../src/interfaces/IPropPair.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

/// @notice Settles Rialto propAMM legs DIRECTLY from a contract, with no RialtoRouter involved.
///
/// This exists because the earlier eth_call evidence was not proof. Identical
/// `ERC20InsufficientAllowance` reverts from an EOA and from the RialtoRouter only show there is no
/// gate BEFORE the token pull — a check placed after the pull would look exactly the same. The only
/// proof is a settled swap, so that is what this does: deal, approve, call, and check the balance.
contract PropAmmDirect is Test {
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    struct Maker {
        string name;
        address pair;
        address stock;
    }

    Maker[] makers;

    function setUp() public {
        makers.push(Maker("fermi-prop AAPL", 0x89E211D43BBcf8cA5eaa9E5FBdEF078cF520ecF1, 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9));
        makers.push(Maker("fermi-prop TSLA", 0x6AF2ceE71BabFa22f9F55A16507CC4dC6369304b, 0x322F0929c4625eD5bAd873c95208D54E1c003b2d));
        makers.push(Maker("fermi-prop NVDA", 0x5744E9C5165973bA5A332135477f3000C143f16F, 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC));
        makers.push(Maker("fermi-prop SPY",  0x894b9322662F4e4Ce05882F38095C6C7BCf1cC73, 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C));
    }

    function _proveDirectSettlement(Maker memory m) internal {
        IPropPair pair = IPropPair(m.pair);
        address t0 = pair.token0();
        bool zeroForOne = (t0 == m.stock);
        assertTrue(zeroForOne || pair.token1() == m.stock, "stock not in pair");

        uint256 amountIn = 1e18;
        uint256 quoted = pair.getAmountOut(zeroForOne, amountIn);
        if (quoted == 0) {
            console2.log(string.concat(m.name, ": maker declined 1 unit - skipped, not a failure"));
            return;
        }

        deal(m.stock, address(this), amountIn);
        IERC20(m.stock).approve(m.pair, amountIn);

        uint256 before = IERC20(USDG).balanceOf(address(this));
        // Called by THIS CONTRACT. No RialtoRouter anywhere in the call stack.
        uint256 returned = pair.swapExactIn(zeroForOne, amountIn, 0, address(this), block.timestamp + 300);
        uint256 received = IERC20(USDG).balanceOf(address(this)) - before;

        console2.log(m.name);
        console2.log("   quoted  ", quoted);
        console2.log("   returned", returned);
        console2.log("   received", received);

        assertGt(received, 0, "no USDG received - settlement did not happen");
        assertEq(received, returned, "return value disagrees with balance delta");
        assertEq(received, quoted, "fill differs from quote at same block");
    }

    function test_propAmmSettlesDirectlyFromAContract() public {
        for (uint256 i = 0; i < makers.length; i++) {
            _proveDirectSettlement(makers[i]);
        }
    }

    /// @notice The caller is a contract with no relationship to RialtoRouter, stated as an assertion.
    function test_callerIsAContractNotTheRialtoRouter() public view {
        address RIALTO_ROUTER = 0xC94135b63772b91D79d0A2DaAb2a8801f32359bD;
        assertGt(address(this).code.length, 0, "caller must be a contract");
        assertTrue(address(this) != RIALTO_ROUTER, "caller must not be the router");
    }
}
