// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

/**
 * BlockBet v4
 *
 * Changes from the previous version:
 * 1. Single bets are now FIXED-ODDS, locked at placement (matching how
 *    accumulators already worked) — no more pool-splitting, no more
 *    "just getting your stake back" when you're the only bettor.
 * 2. Cash out early via a signed price quote from a trusted server
 *    wallet ("oracle"). The contract can never know a live match's
 *    real state on its own — it only trusts a specific wallet's
 *    signature, exactly the same pattern used by resolveMatch's
 *    owner-only access, just extended to a second trusted signer.
 */
contract BlockBet {
    enum Result { NONE, HOME, DRAW, AWAY }

    struct Match {
        string homeTeam;
        string awayTeam;
        uint256 totalHome;
        uint256 totalDraw;
        uint256 totalAway;
        Result result;
        bool resolved;
        bool exists;
    }

    struct Bet {
        uint256 amount;
        Result prediction;
        uint256 oddsBps;
        bool claimed;
        bool cashedOut;
    }

    struct Accumulator {
        address bettor;
        uint256 stake;
        uint256 combinedOddsBps;
        bool claimed;
    }

    IERC20 public usdc;
    address public owner;
    address public oracleSigner;

    uint256 public matchCount;
    mapping(uint256 => Match) public matches;
    mapping(uint256 => mapping(address => Bet)) public bets;

    uint256 public accumulatorCount;
    mapping(uint256 => Accumulator) public accumulators;
    mapping(uint256 => uint256[]) internal accumulatorMatchIds;
    mapping(uint256 => Result[]) internal accumulatorPredictions;

    mapping(bytes32 => bool) public usedCashoutNonces;

    event MatchCreated(uint256 matchId, string homeTeam, string awayTeam);
    event BetPlaced(uint256 matchId, address bettor, Result prediction, uint256 amount, uint256 oddsBps);
    event MatchResolved(uint256 matchId, Result result);
    event WinningsClaimed(uint256 matchId, address bettor, uint256 amount);
    event BetCashedOut(uint256 matchId, address bettor, uint256 amount);
    event AccumulatorPlaced(uint256 accId, address bettor, uint256 legCount, uint256 stake, uint256 combinedOddsBps);
    event AccumulatorClaimed(uint256 accId, address bettor, uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor(address usdcAddress, address oracleSignerAddress) {
        usdc = IERC20(usdcAddress);
        owner = msg.sender;
        oracleSigner = oracleSignerAddress;
    }

    function setOracleSigner(address newSigner) external onlyOwner {
        oracleSigner = newSigner;
    }

    function withdrawReserve(uint256 amount, address to) external onlyOwner {
        require(to != address(0), "Invalid recipient");
        usdc.transfer(to, amount);
    }

    function createMatch(string calldata homeTeam, string calldata awayTeam) external onlyOwner {
        matchCount++;
        matches[matchCount] = Match(homeTeam, awayTeam, 0, 0, 0, Result.NONE, false, true);
        emit MatchCreated(matchCount, homeTeam, awayTeam);
    }

    function placeBet(uint256 matchId, Result prediction, uint256 amount, uint256 oddsBps) external {
        require(matches[matchId].exists, "Match doesn't exist");
        require(!matches[matchId].resolved, "Match already resolved");
        require(bets[matchId][msg.sender].amount == 0, "Already bet on this match");
        require(prediction != Result.NONE, "Invalid prediction");
        require(oddsBps > 0, "Invalid odds");

        usdc.transferFrom(msg.sender, address(this), amount);
        bets[matchId][msg.sender] = Bet(amount, prediction, oddsBps, false, false);

        if (prediction == Result.HOME) matches[matchId].totalHome += amount;
        else if (prediction == Result.DRAW) matches[matchId].totalDraw += amount;
        else matches[matchId].totalAway += amount;

        emit BetPlaced(matchId, msg.sender, prediction, amount, oddsBps);
    }

    function resolveMatch(uint256 matchId, Result result) external onlyOwner {
        require(matches[matchId].exists, "Match doesn't exist");
        require(!matches[matchId].resolved, "Already resolved");
        matches[matchId].result = result;
        matches[matchId].resolved = true;
        emit MatchResolved(matchId, result);
    }

    function claimWinnings(uint256 matchId) external {
        Match storage m = matches[matchId];
        require(m.resolved, "Match not resolved");
        Bet storage bet = bets[matchId][msg.sender];
        require(bet.amount > 0, "No bet found");
        require(!bet.claimed, "Already claimed");
        require(!bet.cashedOut, "Bet was cashed out");
        require(bet.prediction == m.result, "Bet did not win");

        bet.claimed = true;
        uint256 payout = (bet.amount * bet.oddsBps) / 10000;
        usdc.transfer(msg.sender, payout);

        emit WinningsClaimed(matchId, msg.sender, payout);
    }

    function cashOutBet(
        uint256 matchId,
        uint256 offeredAmount,
        uint256 deadline,
        bytes32 nonce,
        bytes calldata signature
    ) external {
        Match storage m = matches[matchId];
        require(!m.resolved, "Match already resolved");
        require(block.timestamp <= deadline, "Quote expired");
        require(!usedCashoutNonces[nonce], "Quote already used");

        Bet storage bet = bets[matchId][msg.sender];
        require(bet.amount > 0, "No bet found");
        require(!bet.claimed, "Already claimed");
        require(!bet.cashedOut, "Already cashed out");

        bytes32 messageHash = keccak256(
            abi.encodePacked(matchId, msg.sender, offeredAmount, deadline, nonce, address(this))
        );
        bytes32 ethSignedHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash)
        );

        require(signature.length == 65, "Invalid signature length");
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
        address recovered = ecrecover(ethSignedHash, v, r, s);
        require(recovered == oracleSigner, "Invalid oracle signature");

        usedCashoutNonces[nonce] = true;
        bet.cashedOut = true;
        usdc.transfer(msg.sender, offeredAmount);

        emit BetCashedOut(matchId, msg.sender, offeredAmount);
    }

    function placeAccumulator(
        uint256[] calldata matchIds,
        Result[] calldata predictions,
        uint256 combinedOddsBps,
        uint256 stake
    ) external {
        require(matchIds.length == predictions.length, "Length mismatch");
        require(matchIds.length >= 2, "Need at least 2 legs");
        for (uint i = 0; i < matchIds.length; i++) {
            require(matches[matchIds[i]].exists, "Match doesn't exist");
            require(!matches[matchIds[i]].resolved, "Match already resolved");
        }
        usdc.transferFrom(msg.sender, address(this), stake);
        accumulatorCount++;
        accumulators[accumulatorCount] = Accumulator(msg.sender, stake, combinedOddsBps, false);
        accumulatorMatchIds[accumulatorCount] = matchIds;
        accumulatorPredictions[accumulatorCount] = predictions;
        emit AccumulatorPlaced(accumulatorCount, msg.sender, matchIds.length, stake, combinedOddsBps);
    }

    function checkAccumulatorOutcome(uint256 accId) public view returns (uint8) {
        uint256[] storage ids = accumulatorMatchIds[accId];
        Result[] storage preds = accumulatorPredictions[accId];
        for (uint i = 0; i < ids.length; i++) {
            Match storage m = matches[ids[i]];
            if (!m.resolved) return 0;
            if (m.result != preds[i]) return 2;
        }
        return 1;
    }

    function claimAccumulator(uint256 accId) external {
        Accumulator storage acc = accumulators[accId];
        require(acc.bettor == msg.sender, "Not your bet");
        require(!acc.claimed, "Already claimed");
        require(checkAccumulatorOutcome(accId) == 1, "Not a winning accumulator");
        acc.claimed = true;
        uint256 payout = (acc.stake * acc.combinedOddsBps) / 10000;
        usdc.transfer(msg.sender, payout);
        emit AccumulatorClaimed(accId, msg.sender, payout);
    }

    function getAccumulatorLegCount(uint256 accId) external view returns (uint256) {
        return accumulatorMatchIds[accId].length;
    }

    function getAccumulatorLeg(uint256 accId, uint256 legIndex) external view returns (uint256, Result) {
        return (accumulatorMatchIds[accId][legIndex], accumulatorPredictions[accId][legIndex]);
    }

    function getMatch(uint256 matchId) external view returns (
        string memory, string memory, uint256, uint256, uint256, bool, Result
    ) {
        Match storage m = matches[matchId];
        return (m.homeTeam, m.awayTeam, m.totalHome, m.totalDraw, m.totalAway, m.resolved, m.result);
    }

    struct RouletteBet {
        address bettor;
        uint256 amount;
        uint256[] numbers;
        bool settled;
    }

    uint256 public rouletteBetCount;
    mapping(uint256 => RouletteBet) public rouletteBets;

    event RouletteBetPlaced(uint256 betId, address bettor, uint256 amount, uint256 numberCount);
    event RouletteSettled(uint256 betId, address bettor, uint256 winningNumber, uint256 payout);

    function placeRouletteBet(uint256 amount, uint256[] calldata numbers) external {
        require(amount > 0, "Invalid stake");
        uint256 n = numbers.length;
        require(
            n == 1 || n == 2 || n == 3 || n == 4 || n == 6 || n == 12 || n == 18,
            "Invalid bet shape"
        );
        for (uint256 i = 0; i < n; i++) {
            require(numbers[i] <= 36, "Invalid roulette number");
        }

        usdc.transferFrom(msg.sender, address(this), amount);
        rouletteBetCount++;
        rouletteBets[rouletteBetCount] = RouletteBet(msg.sender, amount, numbers, false);

        emit RouletteBetPlaced(rouletteBetCount, msg.sender, amount, n);
    }

    function settleRouletteBet(
        uint256 betId,
        uint256 winningNumber,
        uint256 deadline,
        bytes32 nonce,
        bytes calldata signature
    ) external {
        RouletteBet storage bet = rouletteBets[betId];
        require(bet.amount > 0, "Bet doesn't exist");
        require(!bet.settled, "Already settled");
        require(block.timestamp <= deadline, "Quote expired");
        require(!usedCashoutNonces[nonce], "Quote already used");
        require(winningNumber <= 36, "Invalid number");

        bytes32 messageHash = keccak256(
            abi.encodePacked(betId, winningNumber, deadline, nonce, address(this))
        );
        bytes32 ethSignedHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash)
        );

        require(signature.length == 65, "Invalid signature length");
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
        address recovered = ecrecover(ethSignedHash, v, r, s);
        require(recovered == oracleSigner, "Invalid oracle signature");

        usedCashoutNonces[nonce] = true;
        bet.settled = true;

        bool won = false;
        for (uint256 i = 0; i < bet.numbers.length; i++) {
            if (bet.numbers[i] == winningNumber) { won = true; break; }
        }

        uint256 payout = 0;
        if (won) {
            payout = (bet.amount * 36) / bet.numbers.length;
            usdc.transfer(bet.bettor, payout);
        }

        emit RouletteSettled(betId, bet.bettor, winningNumber, payout);
    }

    function getRouletteBetNumbers(uint256 betId) external view returns (uint256[] memory) {
        return rouletteBets[betId].numbers;
    }

    // ── Aviator ──────────────────────────────────────────────────
    // A continuously-climbing multiplier you race to cash out before
    // it crashes — different again from roulette, since the payout
    // isn't from a small fixed set of ratios. The server computes and
    // signs the EXACT payout amount directly (stake x whatever
    // multiplier you locked in the moment you cashed out, or 0 if the
    // plane had already crashed by then) — same trusted-signature
    // verification as everywhere else, just carrying a plain amount
    // instead of a formula to apply.

    struct AviatorBet {
        address bettor;
        uint256 amount;
        bool settled;
    }

    uint256 public aviatorBetCount;
    mapping(uint256 => AviatorBet) public aviatorBets;

    event AviatorBetPlaced(uint256 betId, address bettor, uint256 amount);
    event AviatorSettled(uint256 betId, address bettor, uint256 payout);

    function placeAviatorBet(uint256 amount) external {
        require(amount > 0, "Invalid stake");
        usdc.transferFrom(msg.sender, address(this), amount);
        aviatorBetCount++;
        aviatorBets[aviatorBetCount] = AviatorBet(msg.sender, amount, false);
        emit AviatorBetPlaced(aviatorBetCount, msg.sender, amount);
    }

    function settleAviatorBet(
        uint256 betId,
        uint256 payoutAmount,
        uint256 deadline,
        bytes32 nonce,
        bytes calldata signature
    ) external {
        AviatorBet storage bet = aviatorBets[betId];
        require(bet.amount > 0, "Bet doesn't exist");
        require(!bet.settled, "Already settled");
        require(block.timestamp <= deadline, "Quote expired");
        require(!usedCashoutNonces[nonce], "Quote already used");

        bytes32 messageHash = keccak256(
            abi.encodePacked(betId, payoutAmount, deadline, nonce, address(this))
        );
        bytes32 ethSignedHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash)
        );

        require(signature.length == 65, "Invalid signature length");
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
        address recovered = ecrecover(ethSignedHash, v, r, s);
        require(recovered == oracleSigner, "Invalid oracle signature");

        usedCashoutNonces[nonce] = true;
        bet.settled = true;

        if (payoutAmount > 0) {
            usdc.transfer(bet.bettor, payoutAmount);
        }

        emit AviatorSettled(betId, bet.bettor, payoutAmount);
    }
}
