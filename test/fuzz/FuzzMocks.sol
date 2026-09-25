// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IUniswapV3SwapCallback} from "../../src/interfaces/IUniswapV3Pool.sol";

/// Minimal ERC20 with settable decimals. No hooks, no fee-on-transfer: the properties are about
/// partitio's accounting, not about exotic tokens.
contract FuzzToken {
    string public name;
    uint8 public immutable decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    event Transfer(address indexed from, address indexed to, uint256 v);
    event Approval(address indexed o, address indexed s, uint256 v);

    bytes32 public immutable DOMAIN_SEPARATOR;
    bytes32 public constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    mapping(address => uint256) public nonces;

    error PermitExpired();
    error BadPermit();

    constructor(string memory n, uint8 d) {
        name = n;
        decimals = d;
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(n)), keccak256("1"), block.chainid, address(this)
            )
        );
    }

    function permit(address owner, address spender, uint256 value, uint256 deadline,
                    uint8 v, bytes32 r, bytes32 s) external {
        if (block.timestamp > deadline) revert PermitExpired();
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01", DOMAIN_SEPARATOR,
                keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonces[owner]++, deadline))
            )
        );
        if (ecrecover(digest, v, r, s) != owner || owner == address(0)) revert BadPermit();
        allowance[owner][spender] = value;
        emit Approval(owner, spender, value);
    }

    function mint(address to, uint256 v) public { balanceOf[to] += v; totalSupply += v; emit Transfer(address(0), to, v); }
    function approve(address s, uint256 v) public returns (bool) { allowance[msg.sender][s] = v; emit Approval(msg.sender, s, v); return true; }
    function transfer(address to, uint256 v) public returns (bool) { _move(msg.sender, to, v); return true; }

    function transferFrom(address f, address to, uint256 v) public returns (bool) {
        uint256 a = allowance[f][msg.sender];
        require(a >= v, "allowance");
        if (a != type(uint256).max) allowance[f][msg.sender] = a - v;
        _move(f, to, v);
        return true;
    }

    function _move(address f, address t, uint256 v) internal {
        require(balanceOf[f] >= v, "balance");
        unchecked { balanceOf[f] -= v; }
        balanceOf[t] += v;
        emit Transfer(f, t, v);
    }
}

/// EIP-3009 receiveWithAuthorization, payee-bound and nonce-bound, as USDG behaves on 4663.
contract FuzzUSDG is FuzzToken {
    // DOMAIN_SEPARATOR is inherited: FuzzToken already builds it from (name, "1", chainid, this),
    // which is byte-identical to what this contract used to compute for itself.
    bytes32 constant RECEIVE_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    mapping(address => mapping(bytes32 => bool)) public authorizationState;

    error CallerMustBePayee();
    error AuthorizationUsed();
    error BadAuthSignature();

    constructor() FuzzToken("USDG", 6) {}

    function receiveWithAuthorization(
        address from, address to, uint256 value,
        uint256 validAfter, uint256 validBefore, bytes32 nonce,
        uint8 v, bytes32 r, bytes32 s
    ) external {
        if (msg.sender != to) revert CallerMustBePayee();
        if (authorizationState[from][nonce]) revert AuthorizationUsed();
        require(block.timestamp > validAfter && block.timestamp < validBefore, "window");
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01", DOMAIN_SEPARATOR,
                keccak256(abi.encode(RECEIVE_TYPEHASH, from, to, value, validAfter, validBefore, nonce))
            )
        );
        if (ecrecover(digest, v, r, s) != from) revert BadAuthSignature();
        authorizationState[from][nonce] = true;
        _move(from, to, value);
    }
}

/// A v3-shaped venue priced off the same feed the guard reads, with fuzzer-settable slippage and
/// a fill ratio so short fills can be explored.
contract FuzzPool is IUniswapV3SwapCallback {
    address public token0;
    address public token1;
    address public feed;
    uint256 public slipBps;   // how far below the oracle this venue executes
    uint256 public fillBps;   // how much of amountSpecified it actually consumes

    constructor(address t0, address t1, address f) {
        token0 = t0; token1 = t1; feed = f; slipBps = 30; fillBps = 10_000;
    }

    function setSlip(uint256 b) external { slipBps = b; }
    function setFill(uint256 b) external { fillBps = b; }

    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1)
    {
        uint256 want = (uint256(amountSpecified) * fillBps) / 10_000;
        require(want > 0, "dust");
        (, int256 price,,,) = IFeed(feed).latestRoundData();
        uint8 fd = IFeed(feed).decimals();
        uint256 out = zeroForOne
            ? (want * 1e18 * (10 ** uint256(fd))) / (1e6 * uint256(price))   // USDG(6) -> STOCK(18)
            : (want * uint256(price) * 1e6) / (1e18 * (10 ** uint256(fd)));  // STOCK(18) -> USDG(6)
        out = (out * (10_000 - slipBps)) / 10_000;
        require(out > 0, "dust out");
        address tOut = zeroForOne ? token1 : token0;
        FuzzToken(tOut).transfer(recipient, out);
        if (zeroForOne) { amount0 = int256(want); amount1 = -int256(out); }
        else { amount1 = int256(want); amount0 = -int256(out); }
        IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
    }

    function uniswapV3SwapCallback(int256, int256, bytes calldata) external pure override {}
}

/// An allowlisted aggregator whose route quality the fuzzer controls, including routes that send
/// the proceeds to the operator. Models relayer-chosen calldata on a real aggregator.
contract FuzzAggregator {
    function route(address tokenIn, uint256 amountIn, address outToken, uint256 deliver, address beneficiary)
        external
    {
        FuzzToken(tokenIn).transferFrom(msg.sender, beneficiary, amountIn);
        if (deliver != 0) FuzzToken(outToken).transfer(msg.sender, deliver);
    }
}

interface IFeed {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

contract FuzzFeed {
    int256 public answer;
    uint256 public updatedAt;
    uint8 public constant dec = 8;

    constructor(int256 a) { answer = a; updatedAt = block.timestamp; }
    function set(int256 a) external { answer = a; updatedAt = block.timestamp; }

    /// Set the reported timestamp explicitly, including AHEAD of the block.
    /// Without this the harness can only ever produce a fresh-or-stale feed, so
    /// OracleGuard's FeedFromTheFuture branch is unreachable and R-10 carries zero fuzz
    /// coverage - measured, it had 0 hits across 211,126 guard evaluations.
    function setAt(int256 a, uint256 ts) external { answer = a; updatedAt = ts; }
    function decimals() external pure returns (uint8) { return dec; }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}
