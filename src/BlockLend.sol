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
 * BlockLend — Stage 3: adds liquidations on top of Stage 1's core
 * mechanics and Stage 2's interest accrual.
 *
 * A position becomes liquidatable once its debt exceeds 75% of its
 * collateral's value (a real buffer above the 66% max-borrow limit,
 * so ordinary interest accrual doesn't immediately put a healthy
 * borrower at risk). Anyone can then repay part or all of that debt
 * on the borrower's behalf and receive their proportional collateral
 * back PLUS an 8% bonus — the real incentive that makes liquidators
 * actually show up when a position goes unsafe, the same mechanism
 * every major lending protocol relies on.
 *
 * REAL, HONEST LIMITATIONS — still true even with this stage added:
 *
 * 1. Price oracle is still your own thin BlockSwap pools. A large
 *    enough swap can move a token's price before this contract reads
 *    it — meaning both borrowing power AND liquidation eligibility
 *    can be manipulated by someone with enough capital to move the
 *    pool temporarily. This is the single biggest reason this
 *    contract isn't safe for real value without a proper external
 *    price oracle.
 * 2. "Bad debt" isn't handled. If a collateral's price crashes fast
 *    enough that even seizing 100% of it doesn't cover the debt, the
 *    liquidator gets capped at whatever collateral actually exists —
 *    the shortfall becomes a real loss for lenders, silently. Real
 *    protocols address this with insurance funds or backstop
 *    mechanisms; this version does not.
 * 3. No liquidation is guaranteed to happen promptly — it depends on
 *    someone actually noticing and acting, same as any permissionless
 *    liquidation system.
 */
contract BlockLend {
    IERC20 public immutable usdc;
    IBlockSwap public immutable swapContract;
    address public owner;

    uint256 public constant LTV_BPS = 6600; // 66% max borrow against collateral
    uint256 public constant LIQUIDATION_THRESHOLD_BPS = 7500; // 75% — liquidatable above this
    uint256 public constant LIQUIDATION_BONUS_BPS = 800; // 8% bonus to the liquidator
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 public constant BORROW_APR_BPS = 800; // 8% annual interest on borrowed USDC
    uint256 constant INDEX_PRECISION = 1e18;

    uint256 public totalShares;
    uint256 public totalPoolValue;
    mapping(address => uint256) public lenderShares;

    uint256 public borrowIndex = INDEX_PRECISION;
    uint256 public totalBorrowPrincipalScaled;
    uint256 public lastAccrualTime;

    struct Position {
        address collateralToken;
        uint256 collateralAmount;
        uint256 borrowScaled;
    }
    mapping(address => Position) public positions;

    event Deposited(address indexed lender, uint256 usdcAmount, uint256 sharesMinted);
    event Withdrawn(address indexed lender, uint256 usdcAmount, uint256 sharesBurned);
    event CollateralPosted(address indexed borrower, address token, uint256 amount);
    event Borrowed(address indexed borrower, uint256 amount);
    event Repaid(address indexed borrower, uint256 amount);
    event CollateralWithdrawn(address indexed borrower, uint256 amount);
    event InterestAccrued(uint256 totalBorrowsAfter, uint256 totalPoolValueAfter);
    event Liquidated(address indexed borrower, address indexed liquidator, uint256 debtRepaid, uint256 collateralSeized);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor(address usdcAddress, address swapAddress) {
        usdc = IERC20(usdcAddress);
        swapContract = IBlockSwap(swapAddress);
        owner = msg.sender;
        lastAccrualTime = block.timestamp;
    }

    function _accrueInterest() internal {
        if (block.timestamp == lastAccrualTime) return;
        uint256 elapsed = block.timestamp - lastAccrualTime;

        uint256 currentBorrows = (totalBorrowPrincipalScaled * borrowIndex) / INDEX_PRECISION;
        if (currentBorrows > 0) {
            uint256 interestAccrued = (currentBorrows * BORROW_APR_BPS * elapsed) / (10000 * SECONDS_PER_YEAR);
            borrowIndex += (borrowIndex * interestAccrued) / currentBorrows;
            totalPoolValue += interestAccrued;
            emit InterestAccrued(currentBorrows + interestAccrued, totalPoolValue);
        }
        lastAccrualTime = block.timestamp;
    }

    function currentDebt(address borrower) public view returns (uint256) {
        Position storage pos = positions[borrower];
        if (pos.borrowScaled == 0) return 0;
        uint256 elapsed = block.timestamp - lastAccrualTime;
        uint256 projectedIndex = borrowIndex;
        if (elapsed > 0) {
            uint256 currentBorrows = (totalBorrowPrincipalScaled * borrowIndex) / INDEX_PRECISION;
            if (currentBorrows > 0) {
                uint256 interestAccrued = (currentBorrows * BORROW_APR_BPS * elapsed) / (10000 * SECONDS_PER_YEAR);
                projectedIndex += (borrowIndex * interestAccrued) / currentBorrows;
            }
        }
        return (pos.borrowScaled * projectedIndex) / INDEX_PRECISION;
    }

    // ── Lender side ──────────────────────────────────────────────

    function deposit(uint256 amount) external {
        require(amount > 0, "Invalid amount");
        _accrueInterest();

        uint256 sharesToMint;
        if (totalShares == 0) {
            sharesToMint = amount;
        } else {
            sharesToMint = (amount * totalShares) / totalPoolValue;
        }

        usdc.transferFrom(msg.sender, address(this), amount);
        lenderShares[msg.sender] += sharesToMint;
        totalShares += sharesToMint;
        totalPoolValue += amount;

        emit Deposited(msg.sender, amount, sharesToMint);
    }

    function withdraw(uint256 shareAmount) external {
        _accrueInterest();
        require(lenderShares[msg.sender] >= shareAmount, "Insufficient share balance");

        uint256 usdcOwed = (shareAmount * totalPoolValue) / totalShares;
        uint256 availableLiquidity = usdc.balanceOf(address(this));
        require(availableLiquidity >= usdcOwed, "Not enough liquidity in the pool right now");

        lenderShares[msg.sender] -= shareAmount;
        totalShares -= shareAmount;
        totalPoolValue -= usdcOwed;

        usdc.transfer(msg.sender, usdcOwed);
        emit Withdrawn(msg.sender, usdcOwed, shareAmount);
    }

    function lenderBalance(address lender) external view returns (uint256) {
        if (totalShares == 0) return 0;
        return (lenderShares[lender] * totalPoolValue) / totalShares;
    }

    // ── Borrower side ────────────────────────────────────────────

    function getCollateralValueUsdc(address token, uint256 amount) public view returns (uint256) {
        (uint256 reserveUsdc, uint256 reserveToken, ) = swapContract.getPool(token);
        require(reserveToken > 0, "No pool liquidity for this token");
        return (amount * reserveUsdc) / reserveToken;
    }

    function postCollateral(address token, uint256 amount) external {
        require(amount > 0, "Invalid amount");
        Position storage pos = positions[msg.sender];
        require(pos.collateralAmount == 0 || pos.collateralToken == token, "Already have different collateral posted");

        IERC20(token).transferFrom(msg.sender, address(this), amount);
        pos.collateralToken = token;
        pos.collateralAmount += amount;
        emit CollateralPosted(msg.sender, token, amount);
    }

    function maxBorrowable(address borrower) public view returns (uint256) {
        Position storage pos = positions[borrower];
        if (pos.collateralAmount == 0) return 0;
        uint256 collateralValue = getCollateralValueUsdc(pos.collateralToken, pos.collateralAmount);
        uint256 maxTotal = (collateralValue * LTV_BPS) / 10000;
        uint256 owed = currentDebt(borrower);
        if (maxTotal <= owed) return 0;
        return maxTotal - owed;
    }

    function borrow(uint256 amount) external {
        require(amount > 0, "Invalid amount");
        _accrueInterest();
        require(amount <= maxBorrowable(msg.sender), "Exceeds your available borrowing capacity");
        uint256 availableLiquidity = usdc.balanceOf(address(this));
        require(availableLiquidity >= amount, "Not enough liquidity in the lending pool right now");

        uint256 scaledAmount = (amount * INDEX_PRECISION) / borrowIndex;
        positions[msg.sender].borrowScaled += scaledAmount;
        totalBorrowPrincipalScaled += scaledAmount;

        usdc.transfer(msg.sender, amount);
        emit Borrowed(msg.sender, amount);
    }

    function repay(uint256 amount) external {
        _accrueInterest();
        Position storage pos = positions[msg.sender];
        uint256 owed = currentDebt(msg.sender);
        require(amount > 0 && amount <= owed, "Invalid repay amount");

        usdc.transferFrom(msg.sender, address(this), amount);
        _reduceDebt(pos, amount);

        emit Repaid(msg.sender, amount);
    }

    function withdrawCollateral(uint256 amount) external {
        _accrueInterest();
        Position storage pos = positions[msg.sender];
        require(amount > 0 && amount <= pos.collateralAmount, "Invalid amount");

        uint256 remaining = pos.collateralAmount - amount;
        uint256 owed = currentDebt(msg.sender);
        if (owed > 0) {
            uint256 remainingValue = getCollateralValueUsdc(pos.collateralToken, remaining);
            uint256 maxAllowed = (remainingValue * LTV_BPS) / 10000;
            require(maxAllowed >= owed, "Would leave your borrow undercollateralized");
        }

        pos.collateralAmount = remaining;
        IERC20(pos.collateralToken).transfer(msg.sender, amount);
        emit CollateralWithdrawn(msg.sender, amount);
    }

    function _reduceDebt(Position storage pos, uint256 usdcAmount) internal {
        uint256 scaledRepaid = (usdcAmount * INDEX_PRECISION) / borrowIndex;
        pos.borrowScaled -= scaledRepaid > pos.borrowScaled ? pos.borrowScaled : scaledRepaid;
        totalBorrowPrincipalScaled -= scaledRepaid > totalBorrowPrincipalScaled ? totalBorrowPrincipalScaled : scaledRepaid;
    }

    // ── Liquidations ─────────────────────────────────────────────

    function isLiquidatable(address borrower) public view returns (bool) {
        Position storage pos = positions[borrower];
        if (pos.borrowScaled == 0) return false;
        uint256 collateralValue = getCollateralValueUsdc(pos.collateralToken, pos.collateralAmount);
        uint256 debt = currentDebt(borrower);
        uint256 threshold = (collateralValue * LIQUIDATION_THRESHOLD_BPS) / 10000;
        return debt > threshold;
    }

    // Anyone can call this on an unsafe position. The caller repays
    // some or all of the borrower's debt directly, and receives that
    // value back in the borrower's collateral token, PLUS the 8%
    // bonus — real, immediate profit for keeping the system solvent.
    function liquidate(address borrower, uint256 repayAmount) external {
        _accrueInterest();
        require(isLiquidatable(borrower), "Position is healthy, cannot liquidate");

        Position storage pos = positions[borrower];
        uint256 debt = currentDebt(borrower);
        require(repayAmount > 0 && repayAmount <= debt, "Invalid repay amount");

        usdc.transferFrom(msg.sender, address(this), repayAmount);
        _reduceDebt(pos, repayAmount);

        uint256 collateralValueToSeize = (repayAmount * (10000 + LIQUIDATION_BONUS_BPS)) / 10000;
        (uint256 reserveUsdc, uint256 reserveToken, ) = swapContract.getPool(pos.collateralToken);
        uint256 collateralToSeize = (collateralValueToSeize * reserveToken) / reserveUsdc;

        // Real, honest edge case: if the position is deep enough
        // underwater that even its full collateral doesn't cover the
        // bonus, cap the seizure at what's actually there — the
        // liquidator gets less than the full 8%, and the shortfall
        // becomes uncovered bad debt for lenders. No insurance fund
        // exists here to backstop that.
        if (collateralToSeize > pos.collateralAmount) {
            collateralToSeize = pos.collateralAmount;
        }

        pos.collateralAmount -= collateralToSeize;
        IERC20(pos.collateralToken).transfer(msg.sender, collateralToSeize);

        emit Liquidated(borrower, msg.sender, repayAmount, collateralToSeize);
    }

    // ── Views ────────────────────────────────────────────────────

    function getPosition(address borrower) external view returns (
        address collateralToken, uint256 collateralAmount, uint256 borrowedAmount, uint256 availableToBorrow, bool liquidatable
    ) {
        Position storage pos = positions[borrower];
        return (pos.collateralToken, pos.collateralAmount, currentDebt(borrower), maxBorrowable(borrower), isLiquidatable(borrower));
    }

    function withdrawReserve(uint256 amount, address to) external onlyOwner {
        require(to != address(0), "Invalid recipient");
        usdc.transfer(to, amount);
    }
}
