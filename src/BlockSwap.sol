// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/**
 * BlockSwap
 *
 * A genuine constant-product AMM (x*y=k, same core math as Uniswap
 * V2), managing three pools internally rather than deploying a
 * separate contract per pair — simpler to review and reason about as
 * a first build. Every pool is hubbed through USDC: USDC<->EURC,
 * USDC<->cirBTC, USDC<->BLOCK. Swapping between two non-USDC assets
 * (e.g. EURC->cirBTC) means two calls from the frontend — swap into
 * USDC, then out to the target — rather than building multi-hop
 * routing directly into the contract, which meaningfully increases
 * both complexity and attack surface for a first version.
 *
 * A real, honest note on AMM economics: whoever provides the FIRST
 * liquidity for a pool sets its initial exchange rate. Seed each pool
 * with amounts that reflect a realistic real-world ratio (e.g. if
 * EUR/USD is around 1.08, deposit correspondingly less EURC than
 * USDC) — an obviously mispriced pool is free money for the first
 * person who notices and trades against it.
 */
contract BlockSwap {
    IERC20 public immutable usdc;
    address public owner;

    uint256 public constant FEE_BPS = 30; // 0.3%, matching the Uniswap convention
    uint256 public constant MINIMUM_LIQUIDITY = 1000; // permanently locked, prevents empty-pool manipulation

    struct Pool {
        uint256 reserveUsdc;
        uint256 reserveToken;
        uint256 totalLp;
        bool exists;
    }

    // keyed by the non-USDC token's address
    mapping(address => Pool) public pools;
    mapping(address => mapping(address => uint256)) public lpBalance; // token => provider => LP amount

    event PoolCreated(address indexed token);
    event LiquidityAdded(address indexed token, address indexed provider, uint256 usdcAmount, uint256 tokenAmount, uint256 lpMinted);
    event LiquidityRemoved(address indexed token, address indexed provider, uint256 usdcAmount, uint256 tokenAmount, uint256 lpBurned);
    event Swap(address indexed token, address indexed trader, bool usdcIn, uint256 amountIn, uint256 amountOut);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor(address usdcAddress) {
        usdc = IERC20(usdcAddress);
        owner = msg.sender;
    }

    function sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    // ── Liquidity ────────────────────────────────────────────────
    // Reserves and LP balances update BEFORE any external token
    // transfer call, throughout this contract — standard
    // checks-effects-interactions ordering, the real defense against
    // reentrancy on a contract that moves value like this one does.

    function addLiquidity(address token, uint256 usdcAmount, uint256 tokenAmount) external returns (uint256 lpMinted) {
        require(usdcAmount > 0 && tokenAmount > 0, "Amounts must be positive");
        Pool storage pool = pools[token];

        if (!pool.exists) {
            pool.exists = true;
            emit PoolCreated(token);
        }

        if (pool.totalLp == 0) {
            lpMinted = sqrt(usdcAmount * tokenAmount);
            require(lpMinted > MINIMUM_LIQUIDITY, "Initial liquidity too small");
            lpMinted -= MINIMUM_LIQUIDITY;
            lpBalance[token][address(0)] += MINIMUM_LIQUIDITY; // permanently locked
            pool.totalLp = lpMinted + MINIMUM_LIQUIDITY;
        } else {
            uint256 lpFromUsdc = (usdcAmount * pool.totalLp) / pool.reserveUsdc;
            uint256 lpFromToken = (tokenAmount * pool.totalLp) / pool.reserveToken;
            lpMinted = lpFromUsdc < lpFromToken ? lpFromUsdc : lpFromToken;
            require(lpMinted > 0, "Insufficient liquidity minted");
            pool.totalLp += lpMinted;
        }

        pool.reserveUsdc += usdcAmount;
        pool.reserveToken += tokenAmount;
        lpBalance[token][msg.sender] += lpMinted;

        usdc.transferFrom(msg.sender, address(this), usdcAmount);
        IERC20(token).transferFrom(msg.sender, address(this), tokenAmount);

        emit LiquidityAdded(token, msg.sender, usdcAmount, tokenAmount, lpMinted);
    }

    function removeLiquidity(address token, uint256 lpAmount) external returns (uint256 usdcOut, uint256 tokenOut) {
        Pool storage pool = pools[token];
        require(lpBalance[token][msg.sender] >= lpAmount, "Insufficient LP balance");
        require(lpAmount > 0, "Invalid LP amount");

        usdcOut = (lpAmount * pool.reserveUsdc) / pool.totalLp;
        tokenOut = (lpAmount * pool.reserveToken) / pool.totalLp;
        require(usdcOut > 0 && tokenOut > 0, "Insufficient reserves for this amount");

        lpBalance[token][msg.sender] -= lpAmount;
        pool.totalLp -= lpAmount;
        pool.reserveUsdc -= usdcOut;
        pool.reserveToken -= tokenOut;

        usdc.transfer(msg.sender, usdcOut);
        IERC20(token).transfer(msg.sender, tokenOut);

        emit LiquidityRemoved(token, msg.sender, usdcOut, tokenOut, lpAmount);
    }

    // ── Swaps ────────────────────────────────────────────────────
    // Standard constant-product formula with the 0.3% fee already
    // baked into amountInWithFee, same approach as Uniswap V2.

    function getAmountOut(address token, uint256 amountIn, bool usdcIn) public view returns (uint256) {
        Pool storage pool = pools[token];
        require(pool.exists, "Pool doesn't exist");
        (uint256 reserveIn, uint256 reserveOut) = usdcIn
            ? (pool.reserveUsdc, pool.reserveToken)
            : (pool.reserveToken, pool.reserveUsdc);
        require(reserveIn > 0 && reserveOut > 0, "Empty pool");

        uint256 amountInWithFee = amountIn * (10000 - FEE_BPS);
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = (reserveIn * 10000) + amountInWithFee;
        return numerator / denominator;
    }

    function swapUsdcForToken(address token, uint256 usdcAmountIn, uint256 minTokenOut) external returns (uint256 tokenOut) {
        Pool storage pool = pools[token];
        require(pool.exists, "Pool doesn't exist");

        tokenOut = getAmountOut(token, usdcAmountIn, true);
        require(tokenOut >= minTokenOut, "Slippage: output below minimum");

        pool.reserveUsdc += usdcAmountIn;
        pool.reserveToken -= tokenOut;

        usdc.transferFrom(msg.sender, address(this), usdcAmountIn);
        IERC20(token).transfer(msg.sender, tokenOut);

        emit Swap(token, msg.sender, true, usdcAmountIn, tokenOut);
    }

    function swapTokenForUsdc(address token, uint256 tokenAmountIn, uint256 minUsdcOut) external returns (uint256 usdcOut) {
        Pool storage pool = pools[token];
        require(pool.exists, "Pool doesn't exist");

        usdcOut = getAmountOut(token, tokenAmountIn, false);
        require(usdcOut >= minUsdcOut, "Slippage: output below minimum");

        pool.reserveToken += tokenAmountIn;
        pool.reserveUsdc -= usdcOut;

        IERC20(token).transferFrom(msg.sender, address(this), tokenAmountIn);
        usdc.transfer(msg.sender, usdcOut);

        emit Swap(token, msg.sender, false, tokenAmountIn, usdcOut);
    }

    // ── Views ────────────────────────────────────────────────────

    function getPool(address token) external view returns (uint256 reserveUsdc, uint256 reserveToken, uint256 totalLp) {
        Pool storage pool = pools[token];
        return (pool.reserveUsdc, pool.reserveToken, pool.totalLp);
    }

    function getPrice(address token) external view returns (uint256 tokenPerUsdc1e18) {
        Pool storage pool = pools[token];
        require(pool.reserveUsdc > 0, "Empty pool");
        return (pool.reserveToken * 1e18) / pool.reserveUsdc;
    }
}
