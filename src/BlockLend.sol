// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IBlockSwap {
    function getPool(address token) external view returns (uint256 reserveUsdc, uint256 reserveToken, uint256 totalLp);
}

/**
 * BlockLend — full multi-asset version: USDC, EURC, cirBTC, and BLOCK
 * can each be deposited to earn interest AND borrowed against
 * collateral posted in any of the other three.
 *
 * This is a genuinely large step up in complexity from the
 * USDC-only version, for a real reason: each asset now needs its own
 * independent lending pool (its own share accounting, its own
 * interest index) rather than one shared pool. A position's
 * collateral can be posted in a DIFFERENT asset than what's borrowed
 * against it, which means valuing that collateral correctly now
 * sometimes requires reading TWO separate BlockSwap pool prices and
 * converting through USDC as an intermediate step (the same two-hop
 * routing your Swap page already does for non-USDC pairs) — doubling
 * the oracle-manipulation exposure already documented as this
 * contract's single biggest weakness in every earlier version.
 *
 * USDC remains special-cased throughout: it's the hub every BlockSwap
 * pool is already built around, so it never needs a price conversion
 * step, while EURC/cirBTC/BLOCK always do when paired against each
 * other.
 *
 * REAL, HONEST LIMITATIONS — still true, now more consequential:
 *
 * 1. Price oracle is still your own thin BlockSwap pools. This risk
 *    directly scales with this version, since two-hop valuations
 *    compound the manipulation surface of a single swap.
 * 2. Bad debt still isn't backstopped in any pool.
 * 3. A position still holds ONE collateral type and ONE borrowed
 *    asset at a time (not simultaneous multi-collateral or
 *    multi-borrow) — kept this restriction deliberately, since
 *    lifting it too is a substantially bigger undertaking on top of
 *    everything else already added here.
 */
contract BlockLend {
    address public immutable usdc;
    IBlockSwap public swapContract;
    address public owner;
    bool public paused;

    uint256 public ltvBps = 6600;
    uint256 public liquidationThresholdBps = 7500;
    uint256 public liquidationBonusBps = 800;
    uint256 public borrowAprBps = 800;
    uint256 public maxUtilizationBps = 8500;

    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 constant INDEX_PRECISION = 1e18;

    // One independent pool per asset — USDC, EURC, cirBTC, and BLOCK
    // each accrue interest and track lender shares completely
    // separately from one another.
    struct AssetPool {
        uint256 totalShares;
        uint256 totalPoolValue;
        uint256 borrowIndex;
        uint256 totalBorrowPrincipalScaled;
        uint256 lastAccrualTime;
        bool initialized;
    }
    mapping(address => AssetPool) public pools; // asset => pool
    mapping(address => mapping(address => uint256)) public lenderShares; // asset => lender => shares

    struct Position {
        address collateralToken;
        uint256 collateralAmount;
        address borrowedAsset;
        uint256 borrowScaled; // scaled against borrowedAsset's pool borrowIndex
    }
    mapping(address => Position) public positions;

    event Deposited(address indexed asset, address indexed lender, uint256 amount, uint256 sharesMinted);
    event Withdrawn(address indexed asset, address indexed lender, uint256 amount, uint256 sharesBurned);
    event CollateralPosted(address indexed borrower, address token, uint256 amount);
    event Borrowed(address indexed borrower, address indexed asset, uint256 amount);
    event Repaid(address indexed borrower, address indexed asset, uint256 amount);
    event CollateralWithdrawn(address indexed borrower, uint256 amount);
    event Liquidated(address indexed borrower, address indexed liquidator, address indexed asset, uint256 debtRepaid, uint256 collateralSeized);
    event ParametersUpdated();
    event Paused(bool isPaused);
    event PriceOracleUpdated(address newOracle);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "New deposits and borrows are currently paused");
        _;
    }

    constructor(address usdcAddress, address swapAddress) {
        usdc = usdcAddress;
        swapContract = IBlockSwap(swapAddress);
        owner = msg.sender;
        _initPool(usdcAddress);
    }

    function _initPool(address asset) internal {
        if (!pools[asset].initialized) {
            pools[asset].initialized = true;
            pools[asset].borrowIndex = INDEX_PRECISION;
            pools[asset].lastAccrualTime = block.timestamp;
        }
    }

    // ── Owner controls ───────────────────────────────────────────

    function setRiskParameters(
        uint256 newLtvBps, uint256 newLiquidationThresholdBps, uint256 newLiquidationBonusBps,
        uint256 newBorrowAprBps, uint256 newMaxUtilizationBps
    ) external onlyOwner {
        require(newLtvBps < newLiquidationThresholdBps, "LTV must stay below the liquidation threshold");
        require(newLiquidationThresholdBps <= 10000, "Invalid threshold");
        require(newMaxUtilizationBps <= 10000, "Invalid utilization cap");
        ltvBps = newLtvBps;
        liquidationThresholdBps = newLiquidationThresholdBps;
        liquidationBonusBps = newLiquidationBonusBps;
        borrowAprBps = newBorrowAprBps;
        maxUtilizationBps = newMaxUtilizationBps;
        emit ParametersUpdated();
    }

    function setPaused(bool isPaused) external onlyOwner {
        paused = isPaused;
        emit Paused(isPaused);
    }

    function setPriceOracle(address newOracle) external onlyOwner {
        require(newOracle != address(0), "Invalid oracle address");
        swapContract = IBlockSwap(newOracle);
        emit PriceOracleUpdated(newOracle);
    }

    function withdrawReserve(address asset, uint256 amount, address to) external onlyOwner {
        require(to != address(0), "Invalid recipient");
        IERC20(asset).transfer(to, amount);
    }

    // ── Interest accrual, per-pool ───────────────────────────────

    function _accrueInterest(address asset) internal {
        AssetPool storage pool = pools[asset];
        if (block.timestamp == pool.lastAccrualTime) return;
        uint256 elapsed = block.timestamp - pool.lastAccrualTime;

        uint256 currentBorrows = (pool.totalBorrowPrincipalScaled * pool.borrowIndex) / INDEX_PRECISION;
        if (currentBorrows > 0) {
            uint256 interestAccrued = (currentBorrows * borrowAprBps * elapsed) / (10000 * SECONDS_PER_YEAR);
            pool.borrowIndex += (pool.borrowIndex * interestAccrued) / currentBorrows;
            pool.totalPoolValue += interestAccrued;
        }
        pool.lastAccrualTime = block.timestamp;
    }

    function currentDebt(address borrower) public view returns (uint256) {
        Position storage pos = positions[borrower];
        if (pos.borrowScaled == 0) return 0;
        AssetPool storage pool = pools[pos.borrowedAsset];
        uint256 elapsed = block.timestamp - pool.lastAccrualTime;
        uint256 projectedIndex = pool.borrowIndex;
        if (elapsed > 0) {
            uint256 currentBorrows = (pool.totalBorrowPrincipalScaled * pool.borrowIndex) / INDEX_PRECISION;
            if (currentBorrows > 0) {
                uint256 interestAccrued = (currentBorrows * borrowAprBps * elapsed) / (10000 * SECONDS_PER_YEAR);
                projectedIndex += (pool.borrowIndex * interestAccrued) / currentBorrows;
            }
        }
        return (pos.borrowScaled * projectedIndex) / INDEX_PRECISION;
    }

    // ── Lender side, works for any of the 4 assets ──────────────

    function deposit(address asset, uint256 amount) external whenNotPaused {
        require(amount > 0, "Invalid amount");
        _initPool(asset);
        _accrueInterest(asset);
        AssetPool storage pool = pools[asset];

        uint256 sharesToMint = pool.totalShares == 0
            ? amount
            : (amount * pool.totalShares) / pool.totalPoolValue;

        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        lenderShares[asset][msg.sender] += sharesToMint;
        pool.totalShares += sharesToMint;
        pool.totalPoolValue += amount;

        emit Deposited(asset, msg.sender, amount, sharesToMint);
    }

    function withdraw(address asset, uint256 shareAmount) external {
        _accrueInterest(asset);
        AssetPool storage pool = pools[asset];
        require(lenderShares[asset][msg.sender] >= shareAmount, "Insufficient share balance");

        uint256 owed = (shareAmount * pool.totalPoolValue) / pool.totalShares;
        uint256 available = IERC20(asset).balanceOf(address(this));
        require(available >= owed, "Not enough liquidity in this pool right now");

        lenderShares[asset][msg.sender] -= shareAmount;
        pool.totalShares -= shareAmount;
        pool.totalPoolValue -= owed;

        IERC20(asset).transfer(msg.sender, owed);
        emit Withdrawn(asset, msg.sender, owed, shareAmount);
    }

    function lenderBalance(address asset, address lender) external view returns (uint256) {
        AssetPool storage pool = pools[asset];
        if (pool.totalShares == 0) return 0;
        return (lenderShares[asset][lender] * pool.totalPoolValue) / pool.totalShares;
    }

    // ── Price conversion ─────────────────────────────────────────
    // Values `amount` of `fromToken` in terms of `toToken`. Direct
    // pool lookup when either side is USDC (the hub every pool is
    // built around); a genuine two-hop conversion through USDC when
    // neither side is — the exact same routing principle your Swap
    // page already uses, just applied to a valuation instead of an
    // actual trade.

    function _valueInUsdc(address token, uint256 amount) internal view returns (uint256) {
        if (token == usdc) return amount;
        (uint256 reserveUsdc, uint256 reserveToken, ) = swapContract.getPool(token);
        require(reserveToken > 0, "No pool liquidity for this token");
        return (amount * reserveUsdc) / reserveToken;
    }

    function _valueFromUsdc(address token, uint256 usdcAmount) internal view returns (uint256) {
        if (token == usdc) return usdcAmount;
        (uint256 reserveUsdc, uint256 reserveToken, ) = swapContract.getPool(token);
        require(reserveUsdc > 0, "No pool liquidity for this token");
        return (usdcAmount * reserveToken) / reserveUsdc;
    }

    function convertValue(address fromToken, uint256 amount, address toToken) public view returns (uint256) {
        if (fromToken == toToken) return amount;
        uint256 usdcValue = _valueInUsdc(fromToken, amount);
        return _valueFromUsdc(toToken, usdcValue);
    }

    // ── Borrower side ────────────────────────────────────────────

    function postCollateral(address token, uint256 amount) external whenNotPaused {
        require(amount > 0, "Invalid amount");
        Position storage pos = positions[msg.sender];
        require(pos.collateralAmount == 0 || pos.collateralToken == token, "Already have different collateral posted");

        IERC20(token).transferFrom(msg.sender, address(this), amount);
        pos.collateralToken = token;
        pos.collateralAmount += amount;
        emit CollateralPosted(msg.sender, token, amount);
    }

    // Max additional amount of `asset` this borrower could take out
    // right now, valued in `asset`'s own terms.
    function maxBorrowable(address borrower, address asset) public view returns (uint256) {
        Position storage pos = positions[borrower];
        if (pos.collateralAmount == 0) return 0;
        if (pos.borrowedAsset != address(0) && pos.borrowedAsset != asset) return 0; // already borrowing a different asset

        uint256 collateralValueInAsset = convertValue(pos.collateralToken, pos.collateralAmount, asset);
        uint256 maxTotal = (collateralValueInAsset * ltvBps) / 10000;
        uint256 owed = currentDebt(borrower);
        if (maxTotal <= owed) return 0;
        return maxTotal - owed;
    }

    function borrow(address asset, uint256 amount) external whenNotPaused {
        require(amount > 0, "Invalid amount");
        _initPool(asset);
        _accrueInterest(asset);
        require(amount <= maxBorrowable(msg.sender, asset), "Exceeds your available borrowing capacity");

        AssetPool storage pool = pools[asset];
        uint256 available = IERC20(asset).balanceOf(address(this));
        require(available >= amount, "Not enough liquidity in this lending pool right now");

        uint256 currentBorrows = (pool.totalBorrowPrincipalScaled * pool.borrowIndex) / INDEX_PRECISION;
        require(
            (currentBorrows + amount) * 10000 <= pool.totalPoolValue * maxUtilizationBps,
            "This would push pool utilization above the safe limit"
        );

        Position storage pos = positions[msg.sender];
        pos.borrowedAsset = asset;
        uint256 scaledAmount = (amount * INDEX_PRECISION) / pool.borrowIndex;
        pos.borrowScaled += scaledAmount;
        pool.totalBorrowPrincipalScaled += scaledAmount;

        IERC20(asset).transfer(msg.sender, amount);
        emit Borrowed(msg.sender, asset, amount);
    }

    function repay(uint256 amount) external {
        Position storage pos = positions[msg.sender];
        address asset = pos.borrowedAsset;
        _accrueInterest(asset);
        uint256 owed = currentDebt(msg.sender);
        require(amount > 0 && amount <= owed, "Invalid repay amount");

        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        _reduceDebt(pos, asset, amount);

        emit Repaid(msg.sender, asset, amount);
    }

    function withdrawCollateral(uint256 amount) external {
        Position storage pos = positions[msg.sender];
        if (pos.borrowedAsset != address(0)) _accrueInterest(pos.borrowedAsset);
        require(amount > 0 && amount <= pos.collateralAmount, "Invalid amount");

        uint256 remaining = pos.collateralAmount - amount;
        uint256 owed = currentDebt(msg.sender);
        if (owed > 0) {
            uint256 remainingValueInBorrowed = convertValue(pos.collateralToken, remaining, pos.borrowedAsset);
            uint256 maxAllowed = (remainingValueInBorrowed * ltvBps) / 10000;
            require(maxAllowed >= owed, "Would leave your borrow undercollateralized");
        }

        pos.collateralAmount = remaining;
        IERC20(pos.collateralToken).transfer(msg.sender, amount);
        emit CollateralWithdrawn(msg.sender, amount);
    }

    function _reduceDebt(Position storage pos, address asset, uint256 amount) internal {
        AssetPool storage pool = pools[asset];
        uint256 scaledRepaid = (amount * INDEX_PRECISION) / pool.borrowIndex;
        pos.borrowScaled -= scaledRepaid > pos.borrowScaled ? pos.borrowScaled : scaledRepaid;
        pool.totalBorrowPrincipalScaled -= scaledRepaid > pool.totalBorrowPrincipalScaled ? pool.totalBorrowPrincipalScaled : scaledRepaid;
    }

    // ── Liquidations ─────────────────────────────────────────────

    function isLiquidatable(address borrower) public view returns (bool) {
        Position storage pos = positions[borrower];
        if (pos.borrowScaled == 0) return false;
        uint256 collateralValueInBorrowed = convertValue(pos.collateralToken, pos.collateralAmount, pos.borrowedAsset);
        uint256 debt = currentDebt(borrower);
        uint256 threshold = (collateralValueInBorrowed * liquidationThresholdBps) / 10000;
        return debt > threshold;
    }

    function liquidate(address borrower, uint256 repayAmount) external {
        Position storage pos = positions[borrower];
        address asset = pos.borrowedAsset;
        _accrueInterest(asset);
        require(isLiquidatable(borrower), "Position is healthy, cannot liquidate");

        uint256 debt = currentDebt(borrower);
        require(repayAmount > 0 && repayAmount <= debt, "Invalid repay amount");

        IERC20(asset).transferFrom(msg.sender, address(this), repayAmount);
        _reduceDebt(pos, asset, repayAmount);

        uint256 repayValueBonus = (repayAmount * (10000 + liquidationBonusBps)) / 10000;
        uint256 collateralToSeize = convertValue(asset, repayValueBonus, pos.collateralToken);

        if (collateralToSeize > pos.collateralAmount) {
            collateralToSeize = pos.collateralAmount;
        }

        pos.collateralAmount -= collateralToSeize;
        IERC20(pos.collateralToken).transfer(msg.sender, collateralToSeize);

        emit Liquidated(borrower, msg.sender, asset, repayAmount, collateralToSeize);
    }

    // ── Views ────────────────────────────────────────────────────

    function getPosition(address borrower) external view returns (
        address collateralToken, uint256 collateralAmount, address borrowedAsset,
        uint256 borrowedAmount, bool liquidatable
    ) {
        Position storage pos = positions[borrower];
        return (pos.collateralToken, pos.collateralAmount, pos.borrowedAsset, currentDebt(borrower), isLiquidatable(borrower));
    }

    function getUtilization(address asset) external view returns (uint256) {
        AssetPool storage pool = pools[asset];
        if (pool.totalPoolValue == 0) return 0;
        uint256 currentBorrows = (pool.totalBorrowPrincipalScaled * pool.borrowIndex) / INDEX_PRECISION;
        return (currentBorrows * 10000) / pool.totalPoolValue;
    }
}
