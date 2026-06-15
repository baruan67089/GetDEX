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
    mapping(bytes32 => uint256) public pairIndex;
    mapping(address => bool) public tokenListed;
    mapping(uint256 => int24) public tickSlot;
    mapping(address => uint256[]) private _providerPools;
    uint256[] private _poolIds;

    modifier nonReentrant() {
        if (_shutter == 2) revert GDX_Reentered();
        _shutter = 2;
        _;
        _shutter = 1;
    }

    modifier onlyPitMaster() {
        if (msg.sender != pitMaster) revert GDX_NotPitMaster();
        _;
    }

    modifier whenLive() {
        if (halted) revert GDX_Halted();
        _;
    }

    constructor() {
        pitMaster = msg.sender;
        ADDRESS_A = 0x05937fCB3A183a97B6d8f93CaC3392E0fE8963DA;
        ADDRESS_B = 0xb8960142670282cA826e2EA199A3BcA26a8c4199;
        ADDRESS_C = 0x0B50ebe2C7B0502756676DbbD965Ae493763ABff;
        spawnedAt = uint64(block.timestamp);
        _shutter = 1;
        protocolFeeBps = 8;
        tokenListed[address(0)] = true;
    }

    function setHalted(bool flag) external onlyPitMaster {
        halted = flag;
        emit GDX_HaltSet(flag, uint64(block.timestamp));
    }

    function transferPit(address next) external onlyPitMaster {
        if (next == address(0)) revert GDX_ZeroAddr();
        if (next == pitMaster) revert GDX_SelfSeat();
        address prev = pitMaster;
        pitMaster = next;
        emit GDX_PitTransferred(prev, next);
    }

    function setProtocolFee(uint256 bps) external onlyPitMaster {
        if (bps > GDX_MAX_PROTOCOL_BPS) revert GDX_ProtoHigh();
        protocolFeeBps = bps;
    }

    function listToken(address token, bool allowed) external onlyPitMaster {
        if (token == address(0)) revert GDX_ZeroAddr();
        tokenListed[token] = allowed;
        emit GDX_TokenListed(token, allowed, uint64(block.timestamp));
    }

    function setPoolFee(uint256 poolId, uint256 swapFeeBps) external onlyPitMaster {
        LiquidityPool storage p = pools[poolId];
        if (p.poolId == 0) revert GDX_PoolMissing();
        if (swapFeeBps > GDX_MAX_FEE_BPS) revert GDX_FeeHigh();
        p.swapFeeBps = swapFeeBps;
        emit GDX_FeeTuned(poolId, swapFeeBps, uint64(block.timestamp));
    }

    function togglePool(uint256 poolId, bool live) external onlyPitMaster {
        LiquidityPool storage p = pools[poolId];
        if (p.poolId == 0) revert GDX_PoolMissing();
        p.live = live;
    }

    function postTick(uint256 slot, int24 tick) external onlyPitMaster {
        tickSlot[slot] = tick;
        emit GDX_TickPosted(slot, tick, uint64(block.timestamp));
    }

    function spawnPool(address token0, address token1, uint256 swapFeeBps, uint256 capWei)
        external
        onlyPitMaster
        returns (uint256 poolId)
    {
        if (token0 == address(0) || token1 == address(0)) revert GDX_ZeroAddr();
        if (token0 == token1) revert GDX_TokenDup();
        if (!tokenListed[token0] || !tokenListed[token1]) revert GDX_TokenBlocked();
        if (swapFeeBps > GDX_MAX_FEE_BPS) revert GDX_FeeHigh();
        if (capWei < 5 ether) revert GDX_LiqLow();
        if (token0 > token1) (token0, token1) = (token1, token0);
        bytes32 key = keccak256(abi.encodePacked(token0, token1));
        if (pairIndex[key] != 0) revert GDX_TokenDup();
        poolId = ++poolSerial;
        LiquidityPool storage p = pools[poolId];
        p.poolId = poolId;
        p.token0 = token0;
        p.token1 = token1;
        p.swapFeeBps = swapFeeBps;
        p.capWei = capWei;
        p.openedAt = uint64(block.timestamp);
        p.live = true;
        pairIndex[key] = poolId;
        _poolIds.push(poolId);
        emit GDX_PoolSpawned(poolId, token0, token1, swapFeeBps);
    }

    function addLiquidity(
        uint256 poolId,
        uint256 amt0Desired,
        uint256 amt1Desired,
        uint256 amt0Min,
        uint256 amt1Min,
        uint256 deadline
    ) external whenLive nonReentrant returns (uint256 shares) {
        if (block.timestamp > deadline) revert GDX_Expiry();
        LiquidityPool storage p = pools[poolId];
        if (p.poolId == 0) revert GDX_PoolMissing();
        if (!p.live) revert GDX_PoolOff();
        (uint256 use0, uint256 use1) = _calcDeposit(p, amt0Desired, amt1Desired);
        if (use0 < amt0Min || use1 < amt1Min) revert GDX_Slippage();
        if (use0 == 0 && use1 == 0) revert GDX_ZeroAmt();
        _pullToken(p.token0, msg.sender, use0);
        _pullToken(p.token1, msg.sender, use1);
        shares = _mintShares(p, use0, use1);
        p.reserve0 = GdxMath.safeAdd(p.reserve0, use0);
        p.reserve1 = GdxMath.safeAdd(p.reserve1, use1);
        if (p.reserve0 + p.reserve1 > p.capWei) revert GDX_CapHit();
        lpShares[poolId][msg.sender] = GdxMath.safeAdd(lpShares[poolId][msg.sender], shares);
        _providerPools[msg.sender].push(poolId);
        emit GDX_LiquidityMinted(poolId, msg.sender, use0, use1, shares);
    }

    function removeLiquidity(
        uint256 poolId,
        uint256 shareAmt,
        uint256 amt0Min,
        uint256 amt1Min,
        uint256 deadline
    ) external whenLive nonReentrant returns (uint256 out0, uint256 out1) {
        if (block.timestamp > deadline) revert GDX_Expiry();
        if (shareAmt == 0) revert GDX_ZeroAmt();
        LiquidityPool storage p = pools[poolId];
        if (p.poolId == 0) revert GDX_PoolMissing();
        uint256 held = lpShares[poolId][msg.sender];
        if (held < shareAmt) revert GDX_ShareGone();
        out0 = (shareAmt * p.reserve0) / p.totalShares;
        out1 = (shareAmt * p.reserve1) / p.totalShares;
        if (out0 < amt0Min || out1 < amt1Min) revert GDX_Slippage();
        lpShares[poolId][msg.sender] = held - shareAmt;
        p.totalShares -= shareAmt;
        p.reserve0 -= out0;
        p.reserve1 -= out1;
        _pushToken(p.token0, msg.sender, out0);
        _pushToken(p.token1, msg.sender, out1);
        emit GDX_LiquidityBurned(poolId, msg.sender, out0, out1, shareAmt);
    }

    function swapExactIn(
        uint256 poolId,
        address tokenIn,
        uint256 amtIn,
        uint256 amtOutMin,
        uint256 deadline
    ) external whenLive nonReentrant returns (uint256 amtOut) {
        if (block.timestamp > deadline) revert GDX_Expiry();
        if (amtIn == 0) revert GDX_ZeroAmt();
        LiquidityPool storage p = pools[poolId];
        if (p.poolId == 0) revert GDX_PoolMissing();
        if (!p.live) revert GDX_PoolOff();
        bool zeroForOne = tokenIn == p.token0;
        if (!zeroForOne && tokenIn != p.token1) revert GDX_BadPath();
        (uint256 rIn, uint256 rOut) = zeroForOne ? (p.reserve0, p.reserve1) : (p.reserve1, p.reserve0);
        amtOut = GdxMath.quoteOut(rIn, rOut, amtIn, p.swapFeeBps);
        if (amtOut < amtOutMin) revert GDX_Slippage();
        if (amtOut == 0 || amtOut >= rOut) revert GDX_ReserveDry();
        _pullToken(tokenIn, msg.sender, amtIn);
        if (zeroForOne) {
            p.reserve0 = GdxMath.safeAdd(p.reserve0, amtIn);
            p.reserve1 -= amtOut;
            _pushToken(p.token1, msg.sender, amtOut);
        } else {
            p.reserve1 = GdxMath.safeAdd(p.reserve1, amtIn);
            p.reserve0 -= amtOut;
            _pushToken(p.token0, msg.sender, amtOut);
        }
        emit GDX_SwapExecuted(poolId, msg.sender, tokenIn, amtIn, amtOut);
    }

    function skimProtocol(uint256 poolId, address token) external onlyPitMaster nonReentrant {
        LiquidityPool storage p = pools[poolId];
        if (p.poolId == 0) revert GDX_PoolMissing();
        if (protocolFeeBps == 0) revert GDX_ZeroAmt();
        uint256 bal = IERC20Gdx(token).balanceOf(address(this));
        uint256 tracked = token == p.token0 ? p.reserve0 : token == p.token1 ? p.reserve1 : 0;
        if (tracked == 0 && token != p.token0 && token != p.token1) revert GDX_BadPath();
        if (bal <= tracked) revert GDX_ZeroAmt();
        uint256 surplus = bal - tracked;
        uint256 skim = GdxMath.mulBps(surplus, protocolFeeBps);
        if (skim == 0) revert GDX_ZeroAmt();
        _pushToken(token, pitMaster, skim);
        emit GDX_ProtocolSkim(poolId, token, skim, uint64(block.timestamp));
    }

    function _calcDeposit(LiquidityPool storage p, uint256 amt0, uint256 amt1)
        private
        view
        returns (uint256 use0, uint256 use1)
    {
        if (p.totalShares == 0) {
            return (amt0, amt1);
        }
        if (amt0 > 0) {
            use1 = (amt0 * p.reserve1) / p.reserve0;
            if (use1 <= amt1) return (amt0, use1);
        }
        use0 = (amt1 * p.reserve0) / p.reserve1;
        use1 = amt1;
    }

    function _mintShares(LiquidityPool storage p, uint256 use0, uint256 use1) private returns (uint256 shares) {
        if (p.totalShares == 0) {
            shares = _sqrt(use0 * use1);
            if (shares < GDX_MIN_LIQ) revert GDX_LiqLow();
        } else {
            uint256 s0 = (use0 * p.totalShares) / p.reserve0;
            uint256 s1 = (use1 * p.totalShares) / p.reserve1;
            shares = s0 < s1 ? s0 : s1;
            if (shares == 0) revert GDX_LiqLow();
        }
        p.totalShares = GdxMath.safeAdd(p.totalShares, shares);
    }

    function _sqrt(uint256 x) private pure returns (uint256 z) {
        if (x == 0) return 0;
        z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }

    function _pullToken(address token, address from, uint256 amt) private {
        if (amt == 0) return;
        if (!tokenListed[token]) revert GDX_TokenBlocked();
        bool ok = IERC20Gdx(token).transferFrom(from, address(this), amt);
        if (!ok) revert GDX_TransferFail();
    }

    function _pushToken(address token, address to, uint256 amt) private {
        if (amt == 0) return;
        bool ok = IERC20Gdx(token).transfer(to, amt);
        if (!ok) revert GDX_TransferFail();
    }

    function poolDigest(uint256 poolId) external view returns (bytes32) {
        LiquidityPool storage p = pools[poolId];
        bytes32 hA = keccak256(abi.encode(p.token0, p.token1, p.reserve0, p.reserve1));
        bytes32 hB = keccak256(abi.encode(p.totalShares, p.swapFeeBps, p.live, GDX_DOMAIN_TAG));
        return keccak256(abi.encodePacked(hA, hB));
    }

    function seatDigest() external view returns (bytes32) {
        bytes32 hA = keccak256(abi.encode(ADDRESS_A, ADDRESS_B, spawnedAt));
        bytes32 hB = keccak256(abi.encode(ADDRESS_C, poolSerial, protocolFeeBps));
        return keccak256(abi.encodePacked(hA, hB));
    }

    function poolCount() external view returns (uint256) {
        return _poolIds.length;
    }

    function poolAt(uint256 index) external view returns (uint256 poolId) {
        return _poolIds[index];
    }

    function providerPoolAt(address provider, uint256 index) external view returns (uint256 poolId) {
        return _providerPools[provider][index];
    }

    function quoteExactIn(uint256 poolId, address tokenIn, uint256 amtIn) external view returns (uint256 amtOut) {
        LiquidityPool storage p = pools[poolId];
        if (p.poolId == 0) revert GDX_PoolMissing();
        bool z = tokenIn == p.token0;
        if (!z && tokenIn != p.token1) revert GDX_BadPath();
        (uint256 rIn, uint256 rOut) = z ? (p.reserve0, p.reserve1) : (p.reserve1, p.reserve0);
        return GdxMath.quoteOut(rIn, rOut, amtIn, p.swapFeeBps);
    }

    function quoteExactOut(uint256 poolId, address tokenOut, uint256 amtOut) external view returns (uint256 amtIn) {
        LiquidityPool storage p = pools[poolId];
        if (p.poolId == 0) revert GDX_PoolMissing();
        bool z = tokenOut == p.token1;
        if (!z && tokenOut != p.token0) revert GDX_BadPath();
        (uint256 rIn, uint256 rOut) = z ? (p.reserve0, p.reserve1) : (p.reserve1, p.reserve0);
        return GdxMath.quoteIn(rIn, rOut, amtOut, p.swapFeeBps);
    }

    function _bootPool_1() private {
        poolSerial = 1;
        LiquidityPool storage p = pools[1];
        p.poolId = 1;
        p.token0 = 0x082db679d9433EF8AEFc2f7063fFed1B4ccEcA2C;
        p.token1 = 0xF59450C8AEEf3294d686ef3b3Fc6B1f9cD8269e5;
        p.swapFeeBps = 73;
        p.capWei = 32.2 ether;
        p.openedAt = spawnedAt;
        p.live = true;
        pairIndex[keccak256(abi.encodePacked(0x082db679d9433EF8AEFc2f7063fFed1B4ccEcA2C, 0xF59450C8AEEf3294d686ef3b3Fc6B1f9cD8269e5))] = 1;
        _poolIds.push(1);
        tokenListed[0x082db679d9433EF8AEFc2f7063fFed1B4ccEcA2C] = true;
        tokenListed[0xF59450C8AEEf3294d686ef3b3Fc6B1f9cD8269e5] = true;
        emit GDX_PoolSpawned(1, 0x082db679d9433EF8AEFc2f7063fFed1B4ccEcA2C, 0xF59450C8AEEf3294d686ef3b3Fc6B1f9cD8269e5, 73);
    }

    function _bootPool_2() private {
        poolSerial = 2;
        LiquidityPool storage p = pools[2];
        p.poolId = 2;
        p.token0 = 0x9096A65e15aB220ed93C75130129e56D91ec3A00;
        p.token1 = 0x94be3649a6A7Cd2d76aCD893c3939BF1f10c1a63;
        p.swapFeeBps = 54;
        p.capWei = 51.6 ether;
        p.openedAt = spawnedAt;
        p.live = true;
        pairIndex[keccak256(abi.encodePacked(0x9096A65e15aB220ed93C75130129e56D91ec3A00, 0x94be3649a6A7Cd2d76aCD893c3939BF1f10c1a63))] = 2;
        _poolIds.push(2);
        tokenListed[0x9096A65e15aB220ed93C75130129e56D91ec3A00] = true;
        tokenListed[0x94be3649a6A7Cd2d76aCD893c3939BF1f10c1a63] = true;
        emit GDX_PoolSpawned(2, 0x9096A65e15aB220ed93C75130129e56D91ec3A00, 0x94be3649a6A7Cd2d76aCD893c3939BF1f10c1a63, 54);
    }

    function _bootPool_3() private {
        poolSerial = 3;
        LiquidityPool storage p = pools[3];
        p.poolId = 3;
        p.token0 = 0x30509a96251363A39C182e95983734ef1DCC476F;
        p.token1 = 0x95E6FB603107F456cf87a55cA4cdB391959df63C;
        p.swapFeeBps = 61;
        p.capWei = 27.4 ether;
        p.openedAt = spawnedAt;
        p.live = true;
        pairIndex[keccak256(abi.encodePacked(0x30509a96251363A39C182e95983734ef1DCC476F, 0x95E6FB603107F456cf87a55cA4cdB391959df63C))] = 3;
        _poolIds.push(3);
        tokenListed[0x30509a96251363A39C182e95983734ef1DCC476F] = true;
        tokenListed[0x95E6FB603107F456cf87a55cA4cdB391959df63C] = true;
        emit GDX_PoolSpawned(3, 0x30509a96251363A39C182e95983734ef1DCC476F, 0x95E6FB603107F456cf87a55cA4cdB391959df63C, 61);
    }

    function _bootPool_4() private {
        poolSerial = 4;
        LiquidityPool storage p = pools[4];
        p.poolId = 4;
        p.token0 = 0xB7EE3979e531816887a7c84a49a1C53e1be01C23;
        p.token1 = 0xE71286b7E6eb0dae83293dF3035782c0F2B98734;
        p.swapFeeBps = 72;
        p.capWei = 41.5 ether;
        p.openedAt = spawnedAt;
        p.live = true;
        pairIndex[keccak256(abi.encodePacked(0xB7EE3979e531816887a7c84a49a1C53e1be01C23, 0xE71286b7E6eb0dae83293dF3035782c0F2B98734))] = 4;
        _poolIds.push(4);
        tokenListed[0xB7EE3979e531816887a7c84a49a1C53e1be01C23] = true;
        tokenListed[0xE71286b7E6eb0dae83293dF3035782c0F2B98734] = true;
        emit GDX_PoolSpawned(4, 0xB7EE3979e531816887a7c84a49a1C53e1be01C23, 0xE71286b7E6eb0dae83293dF3035782c0F2B98734, 72);
    }

    function _bootPool_5() private {
        poolSerial = 5;
        LiquidityPool storage p = pools[5];
        p.poolId = 5;
        p.token0 = 0x7e4c6a1392dfEE7848668cE2Ec4AE0eCEe6EA1D0;
        p.token1 = 0x7EB39905082Ed8F973F70E4e998E652281c630BB;
        p.swapFeeBps = 55;
        p.capWei = 52.8 ether;
        p.openedAt = spawnedAt;
        p.live = true;
        pairIndex[keccak256(abi.encodePacked(0x7e4c6a1392dfEE7848668cE2Ec4AE0eCEe6EA1D0, 0x7EB39905082Ed8F973F70E4e998E652281c630BB))] = 5;
        _poolIds.push(5);
        tokenListed[0x7e4c6a1392dfEE7848668cE2Ec4AE0eCEe6EA1D0] = true;
        tokenListed[0x7EB39905082Ed8F973F70E4e998E652281c630BB] = true;
        emit GDX_PoolSpawned(5, 0x7e4c6a1392dfEE7848668cE2Ec4AE0eCEe6EA1D0, 0x7EB39905082Ed8F973F70E4e998E652281c630BB, 55);
    }

    function _bootPool_6() private {
        poolSerial = 6;
        LiquidityPool storage p = pools[6];
        p.poolId = 6;
        p.token0 = 0x570B5c77f14a78F59F278695e273d8a50240a302;
        p.token1 = 0xFb830c8a8CE97e66fE18A0a6Cf05DE85B01C1e5E;
        p.swapFeeBps = 65;
        p.capWei = 24.2 ether;
        p.openedAt = spawnedAt;
        p.live = true;
        pairIndex[keccak256(abi.encodePacked(0x570B5c77f14a78F59F278695e273d8a50240a302, 0xFb830c8a8CE97e66fE18A0a6Cf05DE85B01C1e5E))] = 6;
        _poolIds.push(6);
        tokenListed[0x570B5c77f14a78F59F278695e273d8a50240a302] = true;
        tokenListed[0xFb830c8a8CE97e66fE18A0a6Cf05DE85B01C1e5E] = true;
        emit GDX_PoolSpawned(6, 0x570B5c77f14a78F59F278695e273d8a50240a302, 0xFb830c8a8CE97e66fE18A0a6Cf05DE85B01C1e5E, 65);
    }

    function _bootPool_7() private {
        poolSerial = 7;
        LiquidityPool storage p = pools[7];
        p.poolId = 7;
        p.token0 = 0x5DbDE6e3191388C0b8523881f19672157216c6Ad;
        p.token1 = 0xCEe4210914D3d8982664dbAeE540b050578f4e14;
        p.swapFeeBps = 64;
        p.capWei = 39.8 ether;
        p.openedAt = spawnedAt;
        p.live = true;
        pairIndex[keccak256(abi.encodePacked(0x5DbDE6e3191388C0b8523881f19672157216c6Ad, 0xCEe4210914D3d8982664dbAeE540b050578f4e14))] = 7;
        _poolIds.push(7);
        tokenListed[0x5DbDE6e3191388C0b8523881f19672157216c6Ad] = true;
        tokenListed[0xCEe4210914D3d8982664dbAeE540b050578f4e14] = true;
        emit GDX_PoolSpawned(7, 0x5DbDE6e3191388C0b8523881f19672157216c6Ad, 0xCEe4210914D3d8982664dbAeE540b050578f4e14, 64);
    }

    function _bootPool_8() private {
        poolSerial = 8;
        LiquidityPool storage p = pools[8];
        p.poolId = 8;
        p.token0 = 0x6f7f2B750dA66E25B9EDdF74a22fF8409f18a376;
        p.token1 = 0xDFe74a6cD59f012C2cfB4ecE5c36F22E334ab58F;
        p.swapFeeBps = 71;
        p.capWei = 71.8 ether;
        p.openedAt = spawnedAt;
        p.live = true;
        pairIndex[keccak256(abi.encodePacked(0x6f7f2B750dA66E25B9EDdF74a22fF8409f18a376, 0xDFe74a6cD59f012C2cfB4ecE5c36F22E334ab58F))] = 8;
        _poolIds.push(8);
        tokenListed[0x6f7f2B750dA66E25B9EDdF74a22fF8409f18a376] = true;
        tokenListed[0xDFe74a6cD59f012C2cfB4ecE5c36F22E334ab58F] = true;
        emit GDX_PoolSpawned(8, 0x6f7f2B750dA66E25B9EDdF74a22fF8409f18a376, 0xDFe74a6cD59f012C2cfB4ecE5c36F22E334ab58F, 71);
    }

    function _bootPool_9() private {
        poolSerial = 9;
        LiquidityPool storage p = pools[9];
        p.poolId = 9;
        p.token0 = 0x0913b4C4b2F6E0eE7231699d3195d86EB3aa28ba;
        p.token1 = 0x9EE54C4dF5Ad38C54f53c52d841Ef6EC8878F1DD;
        p.swapFeeBps = 64;
        p.capWei = 35.2 ether;
