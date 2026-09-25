// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PartitioRouterV2} from "../../src/v2/PartitioRouterV2.sol";
import {GaslessEntry} from "../../src/v2/GaslessEntry.sol";
import {OracleGuard} from "../../src/v2/OracleGuard.sol";
import {IUSDG} from "../../src/v2/IUSDG.sol";
import {IPoolManager} from "../../src/interfaces/IPoolManager.sol";
import {FuzzToken, FuzzUSDG, FuzzPool, FuzzAggregator, FuzzFeed} from "./FuzzMocks.sol";

interface IVm {
    function sign(uint256 pk, bytes32 digest) external pure returns (uint8, bytes32, bytes32);
    function addr(uint256 pk) external pure returns (address);
}

/// @notice Medusa property harness. Self-contained: mock USDG (with real EIP-3009 semantics), a
/// mock stock token (with real EIP-2612 permit), a mock v3 venue priced off the same feed the
/// guard reads, and a mock allowlisted aggregator whose route quality the fuzzer controls.
///
/// No fork. The 4663 RPC serves roughly 90 minutes of state (see script/pin.sh), which cannot
/// support a fuzzing campaign; the fork-dependent behaviour is covered by the forge tests in
/// test/review instead. What the fuzzer explores here is partitio's own accounting.
///
/// BOTH DIRECTIONS. The first version of this harness only ever built buys (tokenIn == USDG). That
/// hid two real bugs — the fee cap being denominated in tokenIn while the fee is paid in USDG, and
/// the oracle floor being taken on gross rather than on what the signer nets — because on a buy
/// the two denominations coincide and the fee never touches the output. `h_fillSell` exists so
/// those properties are actually exercised.
contract PartitioProps {
    IVm constant VM = IVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 constant USER_PK = 0xA11CE;

    FuzzUSDG public usdg;
    FuzzToken public stock;
    FuzzFeed public feed;
    FuzzPool public pool;
    FuzzAggregator public agg;
    PartitioRouterV2 public router;
    GaslessEntry public entry;

    address public user;
    address public constant SKIM = address(0x5111);
    PartitioRouterV2.Venue internal venue;

    // ---- ghosts -------------------------------------------------------
    uint256 public donatedUsdgToEntry;
    uint256 public donatedStockToEntry;
    uint256 public donatedUsdgToRouter;
    uint256 public donatedStockToRouter;

    uint256 public fills;
    uint256 public sellFills;
    uint256 public aggFills;
    bool public brokeMinOut;
    bool public brokeFeeCap;
    bool public brokeFeeBps;
    bool public brokeNonce;
    bool public aggBelowOracleFloor;
    uint256 public worstAggShortfallBps;
    mapping(bytes32 => uint256) public timesFilled;

    uint256 internal saltCounter;

    constructor() {
        user = VM.addr(USER_PK);
        usdg = new FuzzUSDG();
        stock = new FuzzToken("STOCK", 18);
        feed = new FuzzFeed(338_09628128);
        pool = new FuzzPool(address(usdg), address(stock), address(feed));

        venue = PartitioRouterV2.Venue(
            PartitioRouterV2.Kind.V3, address(pool), address(usdg), address(stock), 0, 0, address(0)
        );
        bytes32 root = keccak256(bytes.concat(keccak256(abi.encode(venue))));

        address[] memory toks = new address[](1);
        address[] memory fds = new address[](1);
        toks[0] = address(stock);
        fds[0] = address(feed);
        router = new PartitioRouterV2(IPoolManager(address(0xdead)), root, toks, fds);

        agg = new FuzzAggregator();
        entry = new GaslessEntry(IUSDG(address(usdg)), router, [address(agg), address(0), address(0), address(0)]);

        usdg.mint(address(pool), 1e18);
        stock.mint(address(pool), 1e30);
        stock.mint(address(agg), 1e30);
        usdg.mint(address(agg), 1e18);
        usdg.mint(user, 1e18);
    }

    // ---- handlers -----------------------------------------------------

    function h_setSlip(uint16 bps) public { pool.setSlip(bps % 3000); }

    /// 90-100% of the leg. Shaped deliberately: a real v3 pool that exhausts its liquidity against
    /// the price limit leaves a small residue, and a small residue is exactly the case that still
    /// clears the oracle band and therefore goes unnoticed. A 50% short fill would be rejected by
    /// the guard and would never reach the stranding path.
    function h_setFill(uint16 bps) public { pool.setFill(9_000 + (bps % 1_001)); }

    function h_setPrice(uint64 p) public { feed.set(int256(uint256(p % 1e12) + 1e8)); }

    /// Walk the feed's reported timestamp across the whole range the guard cares about: well
    /// stale, ordinary, and AHEAD of the block. The last case is the only way to reach
    /// OracleGuard.FeedFromTheFuture from this harness.
    function h_setFeedAge(int32 skew) public {
        int256 s = int256(skew) % int256(int32(11 days));
        int256 ts = int256(block.timestamp) + s;
        if (ts < 1) ts = 1;
        (, int256 a,,,) = feed.latestRoundData();
        feed.setAt(a, uint256(ts));
    }

    function h_donateToEntry(uint64 amt, bool isStock) public {
        uint256 a = uint256(amt) % 1e9 + 1;
        if (isStock) { stock.mint(address(this), a); stock.transfer(address(entry), a); donatedStockToEntry += a; }
        else { usdg.mint(address(this), a); usdg.transfer(address(entry), a); donatedUsdgToEntry += a; }
    }

    function h_donateToRouter(uint64 amt, bool isStock) public {
        uint256 a = uint256(amt) % 1e9 + 1;
        if (isStock) { stock.mint(address(this), a); stock.transfer(address(router), a); donatedStockToRouter += a; }
        else { usdg.mint(address(this), a); usdg.transfer(address(router), a); donatedUsdgToRouter += a; }
    }

    /// Direct router use: the leg amount is exactly what the caller funds.
    function h_routerSwap(uint32 amountIn, uint16 band) public {
        uint256 amt = uint256(amountIn) % 1e9 + 1e6;
        usdg.mint(address(this), amt);
        usdg.approve(address(router), amt);
        PartitioRouterV2.Leg[] memory legs = new PartitioRouterV2.Leg[](1);
        legs[0] = PartitioRouterV2.Leg(venue, new bytes32[](0), amt);
        try router.swapExactIn(
            address(usdg), address(stock), legs, OracleGuard.Params({maxDevBps: 50 + (band % 1951)}),
            0, address(this), block.timestamp
        ) {} catch {}
    }

    /// BUY: USDG in, stock out. The fee comes off the input.
    function h_fill(uint32 amountIn, uint16 feeBps, uint16 minOutBps, uint16 band, uint16 feePick, uint16 aggMode)
        public
    {
        uint256 amt = uint256(amountIn) % 1e9 + 1e6;
        usdg.mint(user, amt);
        uint256 maxFee = (amt * (feeBps % 60)) / 10_000;   // straddles the 50 bps contract cap
        uint256 minOut = (_oracleStockOut(amt) * (minOutBps % 10_001)) / 10_000;
        uint256 dev = 50 + (band % 1951);
        uint256 feeNow = (maxFee * (feePick % 10_001)) / 10_000;

        GaslessEntry.Order memory o = GaslessEntry.Order({
            owner: user, tokenIn: address(usdg), amountIn: amt, tokenOut: address(stock),
            minOut: minOut, maxFeeUsdg: maxFee, deadline: block.timestamp + 300,
            salt: bytes32(++saltCounter), guard: OracleGuard.Params({maxDevBps: dev})
        });
        _run(o, feeNow, aggMode, amt - feeNow, minOut, true);
    }

    /// SELL: stock in, USDG out. The fee comes out of the OUTPUT, which is the case the buy-only
    /// harness could not see.
    function h_fillSell(uint32 amountIn, uint16 feeBps, uint16 minOutBps, uint16 band, uint16 aggMode) public {
        uint256 amt = uint256(amountIn) % 1e18 + 1e15;
        stock.mint(user, amt);
        uint256 gross = _oracleUsdgOut(amt);
        uint256 maxFee = (gross * (feeBps % 60)) / 10_000;
        uint256 minOut = (gross * (minOutBps % 10_001)) / 10_000;
        uint256 dev = 50 + (band % 1951);

        GaslessEntry.Order memory o = GaslessEntry.Order({
            owner: user, tokenIn: address(stock), amountIn: amt, tokenOut: address(usdg),
            minOut: minOut, maxFeeUsdg: maxFee, deadline: block.timestamp + 300,
            salt: bytes32(++saltCounter), guard: OracleGuard.Params({maxDevBps: dev})
        });
        _run(o, maxFee, aggMode, amt, minOut, false);
    }

    function _run(
        GaslessEntry.Order memory o, uint256 feeNow, uint16 aggMode,
        uint256 spendable, uint256 minOut, bool isBuy
    ) internal {
        bytes32 oh = entry.hashOrder(o);
        GaslessEntry.Auth memory a = _auth(o, oh, isBuy);
        GaslessEntry.Route memory r = _route(o, aggMode, spendable, minOut);

        uint256 relayerUsdgBefore = usdg.balanceOf(address(this));
        uint256 userOutBefore = FuzzToken(o.tokenOut).balanceOf(user);

        try entry.fill(o, a, r, feeNow) returns (uint256 got) {
            fills++;
            if (!isBuy) sellFills++;
            timesFilled[oh]++;
            if (timesFilled[oh] > 1) brokeNonce = true;
            if (got < minOut) brokeMinOut = true;
            if (FuzzToken(o.tokenOut).balanceOf(user) - userOutBefore < minOut) brokeMinOut = true;

            uint256 feeTaken = usdg.balanceOf(address(this)) - relayerUsdgBefore;
            if (feeTaken > o.maxFeeUsdg) brokeFeeCap = true;
            // the percentage cap applies to the USDG side of the trade
            uint256 basis = isBuy ? o.amountIn : got + feeTaken;
            if (feeTaken * 10_000 > basis * entry.MAX_FEE_BPS()) brokeFeeBps = true;

            if (r.aggregator != address(0)) {
                aggFills++;
                // The floor bounds catastrophe. Use half the oracle value of the whole spendable
                // amount as the catastrophe line: coarse enough to survive legitimate short fills
                // and price impact, tight enough that a skimming route cannot hide under it.
                uint256 gross = got + feeTaken;
                if (gross * 2 < _oracleOutFor(o, spendable)) aggBelowOracleFloor = true;
            }
        } catch {}
    }

    /// A second fill attempt with the very same order and signature.
    function h_replayLast(uint32 amountIn, uint16 feeBps) public {
        h_fill(amountIn, feeBps, 0, 300, 5_000, 0);
        uint256 amt = uint256(amountIn) % 1e9 + 1e6;
        uint256 maxFee = (amt * (feeBps % 60)) / 10_000;
        GaslessEntry.Order memory o = GaslessEntry.Order({
            owner: user, tokenIn: address(usdg), amountIn: amt, tokenOut: address(stock),
            minOut: 0, maxFeeUsdg: maxFee, deadline: block.timestamp + 300,
            salt: bytes32(saltCounter), guard: OracleGuard.Params({maxDevBps: 300})
        });
        bytes32 oh = entry.hashOrder(o);
        try entry.fill(o, _auth(o, oh, true), _route(o, 0, amt, 0), 0) {
            timesFilled[oh]++;
            if (timesFilled[oh] > 1) brokeNonce = true;
        } catch {}
    }

    // ---- properties ---------------------------------------------------

    /// P1  Every successful fill delivered at least the signed minOut.
    function property_outputNeverBelowMinOut() public view returns (bool) { return !brokeMinOut; }

    /// P2  No order hash ever executed twice.
    function property_nonceExecutesOnce() public view returns (bool) { return !brokeNonce; }

    /// P3  The relayer never took more than the signed maxFeeUsdg.
    function property_feeNeverAboveMaxFee() public view returns (bool) { return !brokeFeeCap; }

    /// P3b The relayer never took more than MAX_FEE_BPS of the USDG side, on either direction.
    function property_feeNeverAbovePercentageCap() public view returns (bool) { return !brokeFeeBps; }

    /// P4  GaslessEntry holds nothing except what was donated to it.
    function property_noFundsAtRestInEntry() public view returns (bool) {
        return usdg.balanceOf(address(entry)) <= donatedUsdgToEntry
            && stock.balanceOf(address(entry)) <= donatedStockToEntry;
    }

    /// P5  PartitioRouterV2 holds nothing except what was donated to it.
    function property_noFundsAtRestInRouter() public view returns (bool) {
        return usdg.balanceOf(address(router)) <= donatedUsdgToRouter
            && stock.balanceOf(address(router)) <= donatedStockToRouter;
    }

    /// P6  Every aggregator fill cleared the oracle floor the signer chose.
    function property_aggregatorFillsClearTheOracleFloor() public view returns (bool) {
        return !aggBelowOracleFloor;
    }

    // ---- internals ----------------------------------------------------

    function _oracleStockOut(uint256 usdgIn) internal view returns (uint256) {
        (, int256 p,,,) = feed.latestRoundData();
        return (usdgIn * 1e18 * 1e8) / (1e6 * uint256(p));
    }

    function _oracleOutFor(GaslessEntry.Order memory o, uint256 amountIn) internal view returns (uint256) {
        return o.tokenIn == address(usdg) ? _oracleStockOut(amountIn) : _oracleUsdgOut(amountIn);
    }

    function _oracleUsdgOut(uint256 stockIn) internal view returns (uint256) {
        (, int256 p,,,) = feed.latestRoundData();
        return (stockIn * uint256(p) * 1e6) / (1e18 * 1e8);
    }

    function _auth(GaslessEntry.Order memory o, bytes32 oh, bool isBuy)
        internal view returns (GaslessEntry.Auth memory a)
    {
        (uint8 v, bytes32 r, bytes32 s) = VM.sign(USER_PK, oh);
        bytes32 digest;
        if (isBuy) {
            digest = keccak256(
                abi.encodePacked(
                    "\x19\x01", usdg.DOMAIN_SEPARATOR(),
                    keccak256(abi.encode(
                        keccak256("ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"),
                        o.owner, address(entry), o.amountIn, uint256(0), o.deadline, oh
                    ))
                )
            );
        } else {
            digest = keccak256(
                abi.encodePacked(
                    "\x19\x01", stock.DOMAIN_SEPARATOR(),
                    keccak256(abi.encode(
                        stock.PERMIT_TYPEHASH(), o.owner, address(entry), o.amountIn,
                        stock.nonces(o.owner), o.deadline
                    ))
                )
            );
        }
        (uint8 pv, bytes32 pr, bytes32 ps) = VM.sign(USER_PK, digest);
        a = GaslessEntry.Auth({v: v, r: r, s: s, pv: pv, pr: pr, ps: ps, validAfter: 0, validBefore: o.deadline});
    }

    /// Legs must sum to exactly `spendable` (R-04), so the fuzzer cannot under-route by shrinking
    /// them; what it still controls is whether an aggregator is used and how good its route is.
    function _route(GaslessEntry.Order memory o, uint16 aggMode, uint256 spendable, uint256 minOut)
        internal view returns (GaslessEntry.Route memory)
    {
        PartitioRouterV2.Leg[] memory legs = new PartitioRouterV2.Leg[](1);
        legs[0] = PartitioRouterV2.Leg(venue, new bytes32[](0), spendable);

        if (aggMode % 4 == 0) {
            return GaslessEntry.Route({aggregator: address(0), callData: "", aggMinOut: 0, legs: legs});
        }
        // Mode 3 is an HONEST aggregator route, and it has to exist: every skimming route now
        // reverts on the oracle floor, so without a route that can actually complete, the
        // aggregator branch is never exercised end to end and its property is vacuously true.
        // That is not hypothetical - it happened, and test/fuzz/HarnessReachability.t.sol exists
        // to catch it.
        uint256 deliver;
        if (aggMode % 4 == 3) deliver = (_oracleOutFor(o, spendable) * 9_950) / 10_000;
        else if (aggMode % 4 == 1) deliver = minOut;
        else deliver = 0;
        return GaslessEntry.Route({
            aggregator: address(agg),
            callData: abi.encodeCall(
                FuzzAggregator.route, (o.tokenIn, spendable, o.tokenOut, deliver, SKIM)
            ),
            aggMinOut: 0,
            legs: legs
        });
    }
}
