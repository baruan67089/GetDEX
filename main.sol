// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/// @title GetDEX — on-chain spot venue with pooled reserves and LP share ledger.
/// @dev codename: cobalt sluice / tide latch seven

interface IERC20Gdx {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
}

library GdxMath {
    error GDX_MathOverflow();
    error GDX_MathUnderflow();
    uint256 internal constant BPS = 10_000;

    function mulBps(uint256 amt, uint256 bps) internal pure returns (uint256) {
        unchecked { return (amt * bps) / BPS; }
    }

    function safeAdd(uint256 a, uint256 b) internal pure returns (uint256) {
        unchecked {
            uint256 s = a + b;
            if (s < a) revert GDX_MathOverflow();
            return s;
        }
    }

    function safeSub(uint256 a, uint256 b) internal pure returns (uint256) {
        unchecked {
            if (b > a) revert GDX_MathUnderflow();
            return a - b;
        }
    }

    function quoteOut(uint256 reserveIn, uint256 reserveOut, uint256 amountIn, uint256 feeBps)
        internal
        pure
        returns (uint256)
    {
        if (amountIn == 0 || reserveIn == 0 || reserveOut == 0) return 0;
        uint256 taxed = (amountIn * (BPS - feeBps)) / BPS;
        unchecked {
            uint256 num = taxed * reserveOut;
            uint256 den = reserveIn + taxed;
            return num / den;
        }
    }

    function quoteIn(uint256 reserveIn, uint256 reserveOut, uint256 amountOut, uint256 feeBps)
        internal
        pure
        returns (uint256)
    {
        if (amountOut == 0 || reserveIn == 0 || reserveOut == 0) return 0;
        if (amountOut >= reserveOut) revert GDX_MathUnderflow();
        unchecked {
            uint256 num = reserveIn * amountOut;
            uint256 den = reserveOut - amountOut;
            uint256 gross = (num / den) + 1;
            return (gross * BPS + (BPS - feeBps) - 1) / (BPS - feeBps);
        }
    }
}

contract GetDEX {
    error GDX_NotPitMaster();
    error GDX_Halted();
    error GDX_ZeroAddr();
    error GDX_ZeroAmt();
    error GDX_Reentered();
    error GDX_PoolMissing();
    error GDX_PoolOff();
    error GDX_TokenDup();
    error GDX_TokenBlocked();
    error GDX_CapHit();
    error GDX_Slippage();
    error GDX_LiqLow();
    error GDX_ShareGone();
    error GDX_ReserveDry();
    error GDX_TransferFail();
    error GDX_FeeHigh();
    error GDX_ProtoHigh();
    error GDX_BatchWide();
    error GDX_SizeMismatch();
    error GDX_ArrayEmpty();
    error GDX_SelfSeat();
    error GDX_TickMissing();
    error GDX_BadPath();
    error GDX_PathShort();
    error GDX_Expiry();
    error GDX_Fault_25();
    error GDX_Fault_26();
    error GDX_Fault_27();
    error GDX_Fault_28();
    error GDX_Fault_29();
    error GDX_Fault_30();

    event GDX_PoolSpawned(uint256 indexed poolId, address indexed token0, address indexed token1, uint256 feeBps);
    event GDX_LiquidityMinted(uint256 indexed poolId, address indexed provider, uint256 amt0, uint256 amt1, uint256 shares);
    event GDX_LiquidityBurned(uint256 indexed poolId, address indexed provider, uint256 amt0, uint256 amt1, uint256 shares);
    event GDX_SwapExecuted(uint256 indexed poolId, address indexed trader, address tokenIn, uint256 amtIn, uint256 amtOut);
    event GDX_FeeTuned(uint256 indexed poolId, uint256 swapFeeBps, uint64 at);
    event GDX_ProtocolSkim(uint256 indexed poolId, address indexed token, uint256 skimmed, uint64 at);
    event GDX_HaltSet(bool halted, uint64 at);
    event GDX_PitTransferred(address indexed previous, address indexed next);
    event GDX_TokenListed(address indexed token, bool allowed, uint64 at);
    event GDX_TickPosted(uint256 indexed slot, int24 tick, uint64 at);
    event GDX_Pulse_0(uint256 indexed serial, uint256 meta, uint64 at);
    event GDX_Pulse_1(uint256 indexed serial, uint256 meta, uint64 at);
    event GDX_Pulse_2(uint256 indexed serial, uint256 meta, uint64 at);
    event GDX_Pulse_3(uint256 indexed serial, uint256 meta, uint64 at);

    uint256 public constant GDX_BPS = 10000;
    uint256 public constant GDX_MAX_FEE_BPS = 44;
    uint256 public constant GDX_MAX_PROTOCOL_BPS = 19;
    uint256 public constant GDX_MIN_LIQ = 0.04 ether;
    bytes32 public constant GDX_DOMAIN_TAG = 0xe23a378ae1de3ff055cc91baca055ddf200d70fd9e43fa7d7e38fc0f578f25c2;

    address public pitMaster;
    address public immutable ADDRESS_A;
    address public immutable ADDRESS_B;
    address public immutable ADDRESS_C;
    uint64 public immutable spawnedAt;
    bool public halted;
    uint256 private _shutter;
    uint256 public poolSerial;
    uint256 public pulseSerial;
    uint256 public protocolFeeBps;

    struct LiquidityPool {
        uint256 poolId;
        address token0;
        address token1;
        uint256 reserve0;
        uint256 reserve1;
        uint256 totalShares;
        uint256 swapFeeBps;
        uint256 capWei;
        uint64 openedAt;
        bool live;
    }

    mapping(uint256 => LiquidityPool) public pools;
    mapping(uint256 => mapping(address => uint256)) public lpShares;
