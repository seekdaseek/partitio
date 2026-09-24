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
/// mock stock token, a mock v3 venue priced off the same feed the guard reads, and a mock
/// allowlisted aggregator whose route quality the fuzzer controls.
///
/// No fork. The 4663 RPC serves roughly 90 minutes of state (see script/pin.sh), which cannot
/// support a fuzzing campaign; the fork-dependent behaviour is covered by the forge PoCs in
/// test/review instead. What the fuzzer explores here is partitio's own accounting.
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
    uint256 public aggFills;
    bool public brokeMinOut;
    bool public brokeFeeCap;
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
        router = new PartitioRouterV2(IPoolManager(address(0xdead)), root);

        agg = new FuzzAggregator();
        entry = new GaslessEntry(IUSDG(address(usdg)), router, [address(agg), address(0), address(0), address(0)]);

        usdg.mint(address(pool), 1e18);
        stock.mint(address(pool), 1e30);
        stock.mint(address(agg), 1e30);
        usdg.mint(user, 1e18);
    }

    // ---- handlers -----------------------------------------------------

    function h_setSlip(uint16 bps) public { pool.setSlip(bps % 3000); }
    /// 90-100% of the leg. Shaped deliberately: a real v3 pool that exhausts its liquidity
    /// against the price limit leaves a small residue, and a small residue is exactly the case
    /// that still clears the oracle band and therefore goes unnoticed. A 50% short fill would be
    /// rejected by the guard and would never reach the stranding path.
    function h_setFill(uint16 bps) public { pool.setFill(9_000 + (bps % 1_001)); }
    function h_setPrice(uint64 p) public { feed.set(int256(uint256(p % 1e12) + 1e8)); }

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
            address(usdg), address(stock), legs,
            OracleGuard.Params({feed: address(feed), stockIsInput: false, maxDevBps: 50 + (band % 1951)}),
            0, address(this), block.timestamp
        ) {} catch {}
    }

    /// Gasless fill. The signer commits amountIn, maxFee, minOut and the guard band; the relayer
    /// (this harness) picks the fee, the leg size and whether to use the aggregator.
    function h_fill(uint32 amountIn, uint16 feeBps, uint16 minOutBps, uint16 band, uint16 legBps, uint16 aggMode)
        public
    {
        uint256 amt = uint256(amountIn) % 1e9 + 1e6;
        usdg.mint(user, amt);

        uint256 maxFee = (amt * (feeBps % 2_000)) / 10_000;
        uint256 oracleOut = _oracleStockOut(amt);
        uint256 minOut = (oracleOut * (minOutBps % 10_001)) / 10_000;
        uint256 dev = 50 + (band % 1951);

        GaslessEntry.Output[] memory outs = new GaslessEntry.Output[](1);
        outs[0] = GaslessEntry.Output({
            token: address(stock), weightBps: 10_000, minOut: minOut,
            guard: OracleGuard.Params({feed: address(feed), stockIsInput: false, maxDevBps: dev})
        });
        GaslessEntry.Order memory o = GaslessEntry.Order({
            owner: user, tokenIn: address(usdg), amountIn: amt, maxFee: maxFee,
            deadline: block.timestamp + 300, salt: bytes32(++saltCounter), outputs: outs
        });

        bytes32 oh = entry.hashOrder(o);
        GaslessEntry.Auth memory a = _auth(o, oh);
        GaslessEntry.Route memory r = _route(o, aggMode, legBps, minOut);

        uint256 feeNow = (maxFee * (legBps % 10_001)) / 10_000;
        uint256 relayerBefore = usdg.balanceOf(address(this));
        uint256 userBefore = stock.balanceOf(user);

        try entry.fill(o, a, r, feeNow) returns (uint256[] memory got) {
            fills++;
            timesFilled[oh]++;
            if (timesFilled[oh] > 1) brokeNonce = true;
            if (got[0] < minOut) brokeMinOut = true;
            if (stock.balanceOf(user) - userBefore < minOut) brokeMinOut = true;
            if (usdg.balanceOf(address(this)) - relayerBefore > maxFee) brokeFeeCap = true;

            if (r.aggregator != address(0)) {
                aggFills++;
                uint256 spent = amt - feeNow;
                uint256 floorOut = (_oracleStockOut(spent) * (10_000 - dev)) / 10_000;
                if (got[0] < floorOut) {
                    aggBelowOracleFloor = true;
                    uint256 sf = floorOut == 0 ? 0 : ((floorOut - got[0]) * 10_000) / floorOut;
                    if (sf > worstAggShortfallBps) worstAggShortfallBps = sf;
                }
            }
        } catch {}
    }

    /// A second fill attempt with the very same order and signature.
    function h_replayLast(uint32 amountIn, uint16 feeBps) public {
        h_fill(amountIn, feeBps, 0, 300, 5_000, 0);
        // deliberately re-derive the same salt and retry
        uint256 amt = uint256(amountIn) % 1e9 + 1e6;
        GaslessEntry.Output[] memory outs = new GaslessEntry.Output[](1);
        outs[0] = GaslessEntry.Output({
            token: address(stock), weightBps: 10_000, minOut: 0,
            guard: OracleGuard.Params({feed: address(feed), stockIsInput: false, maxDevBps: 300})
        });
        GaslessEntry.Order memory o = GaslessEntry.Order({
            owner: user, tokenIn: address(usdg), amountIn: amt,
            maxFee: (amt * (feeBps % 2_000)) / 10_000,
            deadline: block.timestamp + 300, salt: bytes32(saltCounter), outputs: outs
        });
        bytes32 oh = entry.hashOrder(o);
        try entry.fill(o, _auth(o, oh), _route(o, 0, 5_000, 0), 0) {
            timesFilled[oh]++;
            if (timesFilled[oh] > 1) brokeNonce = true;
        } catch {}
    }

    // ---- properties ---------------------------------------------------

    /// P1  Every successful fill delivered at least the signed minOut.
    function property_outputNeverBelowMinOut() public view returns (bool) { return !brokeMinOut; }

    /// P2  No order hash ever executed twice.
    function property_nonceExecutesOnce() public view returns (bool) { return !brokeNonce; }

    /// P3  The relayer never took more than the signed maxFee.
    function property_feeNeverAboveMaxFee() public view returns (bool) { return !brokeFeeCap; }

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

    /// P6  Every aggregator fill cleared the oracle floor the signer chose. The contract's own
    /// header claims this ("enforced on the final balance either way").
    function property_aggregatorFillsClearTheOracleFloor() public view returns (bool) {
        return !aggBelowOracleFloor;
    }

    // ---- internals ----------------------------------------------------

    function _oracleStockOut(uint256 usdgIn) internal view returns (uint256) {
        (, int256 p,,,) = feed.latestRoundData();
        return (usdgIn * 1e18 * 1e8) / (1e6 * uint256(p));
    }

    function _auth(GaslessEntry.Order memory o, bytes32 oh)
        internal view returns (GaslessEntry.Auth memory a)
    {
        (uint8 v, bytes32 r, bytes32 s) = VM.sign(USER_PK, oh);
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01", usdg.DOMAIN_SEPARATOR(),
                keccak256(abi.encode(
                    keccak256("ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"),
                    o.owner, address(entry), o.amountIn, uint256(0), o.deadline, oh
                ))
            )
        );
        (uint8 pv, bytes32 pr, bytes32 ps) = VM.sign(USER_PK, digest);
        a = GaslessEntry.Auth({v: v, r: r, s: s, pv: pv, pr: pr, ps: ps, validAfter: 0, validBefore: o.deadline});
    }

    function _route(GaslessEntry.Order memory o, uint16 aggMode, uint16 legBps, uint256 minOut)
        internal view returns (GaslessEntry.Route memory)
    {
        uint256 spendable = o.amountIn - (o.maxFee * (legBps % 10_001)) / 10_000;
        PartitioRouterV2.Leg[] memory legs = new PartitioRouterV2.Leg[](1);
        legs[0] = PartitioRouterV2.Leg(venue, new bytes32[](0), spendable == 0 ? 1 : spendable);

        if (aggMode % 3 == 0) return GaslessEntry.Route({aggregator: address(0), callData: "", aggMinOut: 0, legs: legs});

        // relayer-chosen aggregator calldata: deliver only what minOut forces, keep the rest
        uint256 deliver = aggMode % 3 == 1 ? minOut : 0;
        return GaslessEntry.Route({
            aggregator: address(agg),
            callData: abi.encodeCall(
                FuzzAggregator.route, (address(usdg), spendable, address(stock), deliver, SKIM)
            ),
            aggMinOut: 0,
            legs: legs
        });
    }
}
