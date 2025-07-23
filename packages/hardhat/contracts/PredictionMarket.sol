//SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import { PredictionMarketToken } from "./PredictionMarketToken.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

contract PredictionMarket is Ownable {
    /////////////////
    /// Errors //////
    /////////////////

    error PredictionMarket__MustProvideETHForInitialLiquidity();
    error PredictionMarket__InvalidProbability();
    error PredictionMarket__PredictionAlreadyReported();
    error PredictionMarket__OnlyOracleCanReport();
    error PredictionMarket__OwnerCannotCall();
    error PredictionMarket__PredictionNotReported();
    error PredictionMarket__InsufficientWinningTokens();
    error PredictionMarket__AmountMustBeGreaterThanZero();
    error PredictionMarket__MustSendExactETHAmount();
    error PredictionMarket__InsufficientTokenReserve(Outcome _outcome, uint256 _amountToken);
    error PredictionMarket__TokenTransferFailed();
    error PredictionMarket__ETHTransferFailed();
    error PredictionMarket__InsufficientBalance(uint256 _tradingAmount, uint256 _userBalance);
    error PredictionMarket__InsufficientAllowance(uint256 _tradingAmount, uint256 _allowance);
    error PredictionMarket__InsufficientLiquidity();
    error PredictionMarket__InvalidPercentageToLock();
    

    //////////////////////////
    /// State Variables //////
    //////////////////////////

    enum Outcome {
        YES,
        NO
    }

    uint256 private constant PRECISION = 1e18;

    /// Checkpoint 2 ///
    address public immutable i_liquidityProvider;
    address public immutable i_oracle;
    uint256 public immutable i_initialTokenValue;
    uint8 public immutable i_initialYesProbability;
    uint8 public immutable i_percentageLocked;

    string public s_question;
    uint256 public s_ethCollateral;
    uint256 public s_lpTradingRevenue;

    /// Checkpoint 3 ///
    PredictionMarketToken public immutable i_yesToken;
    PredictionMarketToken public immutable i_noToken;

    /// Checkpoint 5 ///
    PredictionMarketToken public s_winningToken;
    bool public s_isReported;

    /////////////////////////
    /// Events //////
    /////////////////////////

    event TokensPurchased(address indexed buyer, Outcome outcome, uint256 amount, uint256 ethAmount);
    event TokensSold(address indexed seller, Outcome outcome, uint256 amount, uint256 ethAmount);
    event WinningTokensRedeemed(address indexed redeemer, uint256 amount, uint256 ethAmount);
    event MarketReported(address indexed oracle, Outcome winningOutcome, address winningToken);
    event MarketResolved(address indexed resolver, uint256 totalEthToSend);
    event LiquidityAdded(address indexed provider, uint256 ethAmount, uint256 tokensAmount);
    event LiquidityRemoved(address indexed provider, uint256 ethAmount, uint256 tokensAmount);

    /////////////////
    /// Modifiers ///
    /////////////////

    /// Checkpoint 5 ///
    modifier predictionNotReported() {
        if (s_isReported) {
            revert PredictionMarket__PredictionAlreadyReported();
        }
        _;
    }

    /// Checkpoint 6 ///
    modifier onlyOracle() {
        if (msg.sender != i_oracle) {
            revert PredictionMarket__OnlyOracleCanReport();
        }
        _;
    }

    /// Checkpoint 8 ///
    modifier amountGreaterThanZero(uint256 _amount) {
        if (_amount == 0) {
            revert PredictionMarket__AmountMustBeGreaterThanZero();
        }
        _;
    }

    //////////////////
    ////Constructor///
    //////////////////

    constructor(
        address _liquidityProvider,
        address _oracle,
        string memory _question,
        uint256 _initialTokenValue,
        uint8 _initialYesProbability,
        uint8 _percentageToLock
    ) payable Ownable(_liquidityProvider) {
        /// Checkpoint 2 ////
        if (msg.value == 0) {
            revert PredictionMarket__MustProvideETHForInitialLiquidity();
        }
        if (_initialYesProbability <= 0 || _initialYesProbability >= 100) {
            revert PredictionMarket__InvalidProbability();
        }
        if (_percentageToLock <= 0 || _percentageToLock >= 100) {
            revert PredictionMarket__InvalidPercentageToLock();
        }
        i_liquidityProvider = _liquidityProvider; // not really necessary just used for Ownable but whatever
        i_oracle = _oracle;
        s_question = _question;
        i_initialTokenValue = _initialTokenValue;
        i_initialYesProbability = _initialYesProbability;
        i_percentageLocked = _percentageToLock;
        s_ethCollateral = msg.value;
        s_lpTradingRevenue = 0; // also not really neccessary but whatever

        /// Checkpoint 3 ////
        uint256 initialSupply = s_ethCollateral * PRECISION / i_initialTokenValue;

        i_yesToken = new PredictionMarketToken("Yes", "Y", owner(), initialSupply);
        i_noToken = new PredictionMarketToken("No", "N", owner(), initialSupply);

        i_yesToken.transfer(owner(), initialSupply * i_initialYesProbability * i_percentageLocked * 2 / 10000);
        i_noToken.transfer(owner(), initialSupply * (100 - i_initialYesProbability) * i_percentageLocked * 2 / 10000);
    }

    /////////////////
    /// Functions ///
    /////////////////

    /**
     * @notice Add liquidity to the prediction market and mint tokens
     * @dev Only the owner can add liquidity and only if the prediction is not reported
     */
    function addLiquidity() external payable onlyOwner predictionNotReported {
        //// Checkpoint 4 ////
        uint256 ETHadded = msg.value;
        if (ETHadded == 0) {
            revert PredictionMarket__MustProvideETHForInitialLiquidity();
        }
        uint256 newSupply = ETHadded * PRECISION / i_initialTokenValue;

        i_yesToken.mint(address(this), newSupply);
        i_noToken.mint(address(this), newSupply);

        s_ethCollateral += ETHadded;

        emit LiquidityAdded(owner(), ETHadded, newSupply);
    }

    /**
     * @notice Remove liquidity from the prediction market and burn respective tokens, if you remove liquidity before prediction ends you got no share of lpReserve
     * @dev Only the owner can remove liquidity and only if the prediction is not reported
     * @param _ethToWithdraw Amount of ETH to withdraw from liquidity pool
     */
    function removeLiquidity(uint256 _ethToWithdraw) external onlyOwner predictionNotReported {
        //// Checkpoint 4 ////
        if (_ethToWithdraw == 0) {
            revert PredictionMarket__AmountMustBeGreaterThanZero();
        }
        // if (_ethToWithdraw > s_ethCollateral) { // pretty sure this is technically correct but test uses to token amounts
        //     revert PredictionMarket__InsufficientTokenReserve(Outcome.YES, uint256 _amountToken)();
        // }
        uint256 _amounttoBurn = _ethToWithdraw * PRECISION / i_initialTokenValue;
        if (i_yesToken.balanceOf(address(this)) < _amounttoBurn) {
            revert PredictionMarket__InsufficientTokenReserve(Outcome.YES, _amounttoBurn);
        }
        if (i_noToken.balanceOf(address(this)) < _amounttoBurn) {
            revert PredictionMarket__InsufficientTokenReserve(Outcome.NO, _amounttoBurn);
        }

        i_yesToken.burn(address(this), _amounttoBurn);
        i_noToken.burn(address(this), _amounttoBurn);
        s_ethCollateral -= _ethToWithdraw;

        (bool success, ) = owner().call{ value: _ethToWithdraw }("");
        if (!success) {
            revert PredictionMarket__ETHTransferFailed();
        }
        emit LiquidityRemoved(owner(), _ethToWithdraw, _amounttoBurn);
    }

    /**
     * @notice Report the winning outcome for the prediction
     * @dev Only the oracle can report the winning outcome and only if the prediction is not reported
     * @param _winningOutcome The winning outcome (YES or NO)
     */
    function report(Outcome _winningOutcome) external onlyOracle predictionNotReported {
        //// Checkpoint 5 ////
        if (_winningOutcome == Outcome.YES) {
            s_winningToken = i_yesToken;
        } else if (_winningOutcome == Outcome.NO) {
            s_winningToken = i_noToken;
        } else {
            revert PredictionMarket__InvalidProbability();

        }
        s_isReported = true;
        emit MarketReported(msg.sender, _winningOutcome, address(s_winningToken));
    }

    /**
     * @notice Owner of contract can redeem winning tokens held by the contract after prediction is resolved and get ETH from the contract including LP revenue and collateral back
     * @dev Only callable by the owner and only if the prediction is resolved
     * @return ethRedeemed The amount of ETH redeemed
     */
    function resolveMarketAndWithdraw() external onlyOwner returns (uint256 ethRedeemed) {
        /// Checkpoint 6 ////
        if (!s_isReported) {
            revert PredictionMarket__PredictionNotReported();
        }
        uint256 winningTokens = s_winningToken.balanceOf(address(this));
        uint256 winningTokenValue = 0;

        if (winningTokens > 0){
            winningTokenValue = winningTokens * i_initialTokenValue / PRECISION;
        }
        if (winningTokenValue > s_ethCollateral) {
            winningTokenValue = s_ethCollateral;
        }
        
        uint256 totalEthToSend = s_lpTradingRevenue + winningTokenValue;

        if (totalEthToSend == 0) {
            revert PredictionMarket__InsufficientLiquidity();   
        }
        (bool success, ) = owner().call{ value: totalEthToSend }("");
        if (!success) {
            revert PredictionMarket__ETHTransferFailed();
        }

        s_winningToken.burn(address(this), s_winningToken.balanceOf(address(this)));
        s_lpTradingRevenue = 0;
        s_ethCollateral-= totalEthToSend;

        emit MarketResolved(msg.sender, totalEthToSend);
        emit WinningTokensRedeemed(msg.sender, s_winningToken.balanceOf(address(this)), totalEthToSend);
        
        return totalEthToSend;
    }
    /**
     * @notice Buy prediction outcome tokens with ETH, need to call priceInETH function first to get right amount of tokens to buy
     * @param _outcome The possible outcome (YES or NO) to buy tokens for
     * @param _amountTokenToBuy Amount of tokens to purchase
     */
    function buyTokensWithETH(Outcome _outcome, uint256 _amountTokenToBuy) external payable amountGreaterThanZero(_amountTokenToBuy) predictionNotReported {
        /// Checkpoint 8 ////
        uint256 priceInEth = getBuyPriceInEth(_outcome, _amountTokenToBuy);
        if (msg.value != priceInEth) {
            revert PredictionMarket__MustSendExactETHAmount();
        }
        if (msg.sender == owner()) {
            revert PredictionMarket__OwnerCannotCall();
        }
        if (_amountTokenToBuy <= 0) {
            revert PredictionMarket__AmountMustBeGreaterThanZero();
        }

        PredictionMarketToken wantedToken;

        if (_outcome == Outcome.YES) {
            wantedToken = i_yesToken;
        } else {
            wantedToken = i_noToken;
        }
        if (wantedToken.balanceOf(address(this)) < _amountTokenToBuy) {
            revert PredictionMarket__InsufficientTokenReserve(_outcome, _amountTokenToBuy);
        }

        bool success = wantedToken.transfer(msg.sender, _amountTokenToBuy);

        if (!success) {
            revert PredictionMarket__TokenTransferFailed();
        }
        s_lpTradingRevenue += msg.value;
        emit TokensPurchased(msg.sender, _outcome, _amountTokenToBuy, priceInEth);

    }

    /**
     * @notice Sell prediction outcome tokens for ETH, need to call priceInETH function first to get right amount of tokens to buy
     * @param _outcome The possible outcome (YES or NO) to sell tokens for
     * @param _tradingAmount The amount of tokens to sell
     */
    function sellTokensForEth(Outcome _outcome, uint256 _tradingAmount) external predictionNotReported {
        /// Checkpoint 8 ////
        uint256 priceInEth = getSellPriceInEth(_outcome, _tradingAmount);
        PredictionMarketToken wantedToken;
        if (_tradingAmount <= 0) {
            revert PredictionMarket__AmountMustBeGreaterThanZero();
        }
         if( msg.sender == owner()) {
            revert PredictionMarket__OwnerCannotCall();
        }

        if (_outcome == Outcome.YES) {
            wantedToken = i_yesToken;
        } else {
            wantedToken = i_noToken;
        }
        if (wantedToken.balanceOf(msg.sender) < _tradingAmount) {
            revert PredictionMarket__InsufficientBalance(_tradingAmount, wantedToken.balanceOf(msg.sender));
        }
        if (wantedToken.allowance(msg.sender, address(this)) < _tradingAmount) {
            revert PredictionMarket__InsufficientAllowance(_tradingAmount, wantedToken.allowance(msg.sender, address(this)));
        }
        if (address(this).balance < priceInEth) {
            revert PredictionMarket__InsufficientLiquidity();
        }

        bool success = wantedToken.transferFrom(msg.sender, address(this), _tradingAmount);

        if (!success) {
            revert PredictionMarket__TokenTransferFailed();
        }
        (success, ) = msg.sender.call{ value: priceInEth }("");
        if (!success) {
            revert PredictionMarket__ETHTransferFailed();
        }
        s_lpTradingRevenue -= priceInEth; //idk why SRE solution does this before the function call.. Thought you want to update states after external calls

        emit TokensSold(msg.sender, _outcome, _tradingAmount, priceInEth);
    }

    /**
     * @notice Redeem winning tokens for ETH after prediction is resolved, winning tokens are burned and user receives ETH
     * @dev Only if the prediction is resolved
     * @param _amount The amount of winning tokens to redeem
     */
    function redeemWinningTokens(uint256 _amount) external {
        /// Checkpoint 9 ////
        if (msg.sender == owner()) {
            revert PredictionMarket__OwnerCannotCall();
        }
        if (!s_isReported) {
            revert PredictionMarket__PredictionNotReported();
        }
        if (s_winningToken.balanceOf(msg.sender) < _amount) {
            revert PredictionMarket__InsufficientWinningTokens();
        }
        uint256 payout = _amount * i_initialTokenValue / PRECISION;
        if (payout == 0) {
            revert PredictionMarket__AmountMustBeGreaterThanZero();
        }
        s_winningToken.burn(msg.sender, _amount);
        (bool success, ) = msg.sender.call{ value: payout }("");
        if (!success) {
            revert PredictionMarket__ETHTransferFailed();
        }   
        s_ethCollateral -= payout; // is still don't understand why SRE solution does this before the function call
        emit WinningTokensRedeemed(msg.sender, _amount, payout);

    }

    /**
     * @notice Calculate the total ETH price for buying tokens
     * @param _outcome The possible outcome (YES or NO) to buy tokens for
     * @param _tradingAmount The amount of tokens to buy
     * @return The total ETH price
     */
    function getBuyPriceInEth(Outcome _outcome, uint256 _tradingAmount) public view returns (uint256) {
        /// Checkpoint 7 ////
        uint256 probBefore = _calculatePriceInEth(_outcome, 0, false);
        uint256 probAfter = _calculatePriceInEth(_outcome, _tradingAmount, false);
        uint256 probAvg = (probBefore + probAfter) / 2;
        uint256 price = i_initialTokenValue * probAvg * _tradingAmount / PRECISION / PRECISION;
        return price;
    }

    /**
     * @notice Calculate the total ETH price for selling tokens
     * @param _outcome The possible outcome (YES or NO) to sell tokens for
     * @param _tradingAmount The amount of tokens to sell
     * @return The total ETH price
     */
    function getSellPriceInEth(Outcome _outcome, uint256 _tradingAmount) public view returns (uint256) {
        /// Checkpoint 7 ////
        uint256 probBefore = _calculatePriceInEth(_outcome, 0, true);
        uint256 probAfter = _calculatePriceInEth(_outcome, _tradingAmount, true);
        uint256 probAvg = (probBefore + probAfter) / 2;
        uint256 price = i_initialTokenValue * probAvg * _tradingAmount / PRECISION / PRECISION;
        return price;
    }

    /////////////////////////
    /// Helper Functions ///
    ////////////////////////

    /**
     * @dev Internal helper to calculate ETH price for both buying and selling
     * @param _outcome The possible outcome (YES or NO)
     * @param _tradingAmount The amount of tokens
     * @param _isSelling Whether this is a sell calculation
     */
    function _calculatePriceInEth(
        Outcome _outcome,
        uint256 _tradingAmount,
        bool _isSelling
    ) private view returns (uint256) {
        /// Checkpoint 7 ////
        if (_outcome != Outcome.YES && _outcome != Outcome.NO) {
            revert PredictionMarket__InvalidProbability();
        }
        (uint256 wantedTokenReserve, uint256 otherTokenReserve) = _getCurrentReserves(_outcome);

        if (!_isSelling && wantedTokenReserve < _tradingAmount) {
            revert PredictionMarket__InsufficientLiquidity();
        }
        
        // am i missing something here? did SRE miss this>
        // oh you know what im only getting price (obviously) this would be more for the actual selling function. Keep for later but I guess the transaction would revert anyway
        // if ( _outcome == Outcome.YES && _isSelling && _tradingAmount > i_yesToken.balanceOf(msg.sender)) {
        //     revert PredictionMarket__InsufficientBalance(_tradingAmount, i_yesToken.balanceOf(msg.sender));
        // }
        // if (_outcome == Outcome.NO && _isSelling && _tradingAmount > i_noToken.balanceOf(msg.sender)) {
        //     revert PredictionMarket__InsufficientBalance(_tradingAmount, i_noToken.balanceOf(msg.sender));
        // }

        uint256 totalSupply = i_yesToken.totalSupply(); //Im dumb they are the same
        // uint256 tokenLockedYes = i_yesToken.balanceOf(owner()); //im so dumb
        // uint256 tokenLockedNo = i_noToken.balanceOf(owner());

        uint256 wantedTokenSold;
        uint256 otherTokenSold;

        if (!_isSelling) {
            wantedTokenSold = totalSupply - wantedTokenReserve + _tradingAmount; //I WAS SO CONFUSED :"tokens sold" INCLUDES locked tokens I guess. Makes sense now that I think abt it cuz their whole point is to set an initial probability by kind of forcing or simulating a trade
            otherTokenSold = totalSupply - otherTokenReserve;
        } else {
            wantedTokenSold = totalSupply - wantedTokenReserve - _tradingAmount;
            otherTokenSold = totalSupply - otherTokenReserve;
        }

        uint256 prob = _calculateProbability(wantedTokenSold, totalSupply);
        uint256 otherProb = _calculateProbability(otherTokenSold, totalSupply);
        return (prob * PRECISION) / (otherProb + prob);
        
    }

    /**
     * @dev Internal helper to get the current reserves of the tokens
     * @param _outcome The possible outcome (YES or NO)
     * @return The current reserves of the tokens
     */
    function _getCurrentReserves(Outcome _outcome) private view returns (uint256, uint256) {
        /// Checkpoint 7 ////
        if (_outcome == Outcome.YES){
            return (i_yesToken.balanceOf(address(this)), i_noToken.balanceOf(address(this)));
        } else{ 
            return (i_noToken.balanceOf(address(this)), i_yesToken.balanceOf(address(this)));
        }
    }

    /**
     * @dev Internal helper to calculate the probability of the tokens
     * @param tokensSold The number of tokens sold
     * @param totalSold The total number of tokens sold
     * @return The probability of the tokens
     */
    function _calculateProbability(uint256 tokensSold, uint256 totalSold) private pure returns (uint256) {
        /// Checkpoint 7 ////

        if (totalSold == 0) {
            revert PredictionMarket__InvalidProbability();
        }        

        return (tokensSold * PRECISION) / totalSold;
    }

    /////////////////////////
    /// Getter Functions ///
    ////////////////////////

    /**
     * @notice Get the prediction details
     */
    function getPrediction()
        external
        view
        returns (
            string memory question,
            string memory outcome1,
            string memory outcome2,
            address oracle,
            uint256 initialTokenValue,
            uint256 yesTokenReserve,
            uint256 noTokenReserve,
            bool isReported,
            address yesToken,
            address noToken,
            address winningToken,
            uint256 ethCollateral,
            uint256 lpTradingRevenue,
            address predictionMarketOwner,
            uint256 initialProbability,
            uint256 percentageLocked
        )
    {
        /// Checkpoint 3 ////
        oracle = i_oracle;
        initialTokenValue = i_initialTokenValue;
        percentageLocked = i_percentageLocked;
        initialProbability = i_initialYesProbability;
        question = s_question;
        ethCollateral = s_ethCollateral;
        lpTradingRevenue = s_lpTradingRevenue;
        predictionMarketOwner = owner();
        yesToken = address(i_yesToken);
        noToken = address(i_noToken);
        outcome1 = i_yesToken.name();
        outcome2 = i_noToken.name();
        yesTokenReserve = i_yesToken.balanceOf(address(this));
        noTokenReserve = i_noToken.balanceOf(address(this));
        /// Checkpoint 5 ////
        isReported = s_isReported;
        winningToken = address(s_winningToken);
    }
}
