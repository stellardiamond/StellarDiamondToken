// SPDX-License-Identifier: MIT
// STELLAR DIAMOND [XLD]

pragma solidity 0.8.4;

import "./base/token/ERC20/extensions/IERC20Metadata.sol";
import "./base/access/Ownable.sol";
import "./base/utils/Context.sol";
import "./base/token/ERC20/PancakeSwap/IPancakeRouter02.sol";
import "./base/token/ERC20/PancakeSwap/IPancakeFactory.sol";
import "./base/access/ReentrancyGuard.sol";

contract StellarDiamond is Context, IERC20Metadata, Ownable, ReentrancyGuard {
	uint256 private constant MAX = ~uint256(0);
	
	// MAIN TOKEN PROPERTIES
	string private constant _name = "Stellar Diamond";
	string private constant _symbol = "XLD";
	uint8 private constant _decimals = 9;
	uint8 private _distributionFee; //% of each transaction that will be distributed to all holders
	uint8 private _liquidityFee; //% of each transaction that will be added as liquidity
	uint8 private _rewardFee; //% of each transaction that will be used for BNB reward pool
	uint8 private _poolFee; //The total fee to be taken and added to the pool, this includes both the liquidity fee and the reward fee

	uint256 private constant _totalTokens = 1000000000000000 * 10**_decimals;	//1 quadrillion total supply
	mapping (address => uint256) private _balances; //The balance of each address.  This is before applying distribution rate.  To get the actual balance, see balanceOf() method
	mapping (address => mapping (address => uint256)) private _allowances;

	// FEES & REWARDS
	bool private _isSwapEnabled; // True if the contract should swap for liquidity & reward pool, false otherwise
	bool private _isFeeEnabled; // True if fees should be applied on transactions, false otherwise
	address private constant _burnWallet = 0x000000000000000000000000000000000000dEaD; //The address that keeps track of all tokens burned
	uint256 private constant _tokenSwapThreshold = _totalTokens / 100000; //There should be at least 0.0001% of the total supply in the contract before triggering a swap
	uint256 private constant _rewardCyclePeriod = 1 days; // The duration of the reward cycle (e.g. can claim rewards once a day)
	uint256 private _rewardCycleExtensionThreshold; // If someone sends or receives more than a % of their balance in a transaction, their reward cycle date will increase accordingly
	uint256 private _totalFeesDistributed; // The total fees distributed (in number of tokens)
	uint256 private _totalFeesPooled; // The total fees pooled (in number of tokens)
	uint256 private _totalBNBLiquidityAddedFromFees; // The total number of BNB added to the pool through fees
	uint256 private _totalBNBClaimed; // The total number of BNB claimed by all addresses
	mapping (address => bool) private _addressesExcludedFromFees; // The list of addresses that do not pay a fee for transactions
	mapping(address => uint256) private _nextAvailableClaimDate; // The next available reward claim date for each address
	mapping(address => uint256) private _rewardsClaimed; // The amount of BNB claimed by each address
	uint256 private _totalDistributionAvailable = (MAX - (MAX % _totalTokens)); //Indicates the amount of distribution available. Min value is _totalTokens. This is divisible by _totalTokens without any remainder
	uint private _claimRewardGasFeeEstimation; // This is an estimated amount of gas fee for claiming a reward, so that the contract can refund the gas for small rewards. 
	uint256 private _claimRewardGasFeeRefundThreshold; // If someone has less tokens than this threshold, they will be refunded the gas fee when they claim a reward
	
	// CHARITY
	address payable private constant _charityAddress = payable(0x220fFf82900427d0ce6EE7fDE1BeB53cAD34E8E7); // A percentage of the BNB pool will go to the charity address
	uint256 private constant _charityThreshold = 1 ether; // The minimum number of BNB reward before triggering a charity call.  This means if reward is lower, it will not contribute to charity
	uint8 private constant _charityPercentage = 15; // In case charity is triggerred, this is the percentage to take out from the reward transaction

	// TRANSACTION LIMIT
	uint256 private _maxTransactionAmount = _totalTokens; // The amount of tokens that can be exchanged at once
	mapping (address => bool) private _addressesExcludedFromTransactionLimit; // The list of addresses that are not affected by the transaction limit

	// PANCAKESWAP INTERFACES (For swaps)
	address private _pancakeSwapRouterAddress;
	IPancakeRouter02 private _pancakeswapV2Router;
	address private _pancakeswapV2Pair;

	// EVENTS
	event Swapped(uint256 tokensSwapped, uint256 bnbReceived, uint256 tokensIntoLiqudity, uint256 bnbIntoLiquidity);
	event BNBClaimed(address recipient, uint256 bnbReceived, uint256 nextAvailableClaimDate);
	
	constructor (address routerAddress) {
		_balances[_msgSender()] = _totalDistributionAvailable;
		
		// Exclude addresses from fees
		_addressesExcludedFromFees[address(this)] = true;
		_addressesExcludedFromFees[owner()] = true;

		// Exclude addresses from transaction limits
		_addressesExcludedFromTransactionLimit[owner()] = true;
		_addressesExcludedFromTransactionLimit[address(this)] = true;
		_addressesExcludedFromTransactionLimit[_burnWallet] = true;
		
		// Initialize PancakeSwap V2 router and XLD <-> BNB pair.  Router address will be: 0x10ed43c718714eb63d5aa57b78b54704e256024e
		setPancakeSwapRouter(routerAddress);

		// 4% liquidity fee, 8% reward fee, 1% distribution fee
		setFees(4, 8, 1);

		// If someone sends or receives more than 20% of their balance in a transaction, their reward cycle date will increase accordingly
		setRewardCycleExtensionThreshold(20);

		// Gas fee options for claiming a reward: Balances with less than 0.01% of supply will have their gas fee refunded when claiming a reward
		setClaimRewardGasFeeOptions(_totalTokens / 10000, 1000000000000000);

		emit Transfer(address(0), _msgSender(), _totalTokens);

		// Allow pancakeSwap to spend the tokens of the address, no matter the amount
		doApprove(address(this), _pancakeSwapRouterAddress, MAX);
	}

	// This function is used to enable all functions of the contract, after the setup of the token sale (e.g. Liquidity) is completed
	function activate() public onlyOwner {
		_isSwapEnabled = true;
		_isFeeEnabled = true;
		setTransactionLimit(100); // only 1% of the total supply can be exchanged at once
	}


	function balanceOf(address account) public view override returns (uint256) {
		// Apply the distribution rate.  This rate decreases every time a distribution fee is applied, making the balance of every holder go up
		uint256 currentRate =  calculateDistributionRate();
		return _balances[account] / currentRate;
	}
	

	function transfer(address recipient, uint256 amount) public override returns (bool) {
		doTransfer(_msgSender(), recipient, amount);
		return true;
	}
	

	function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
		doTransfer(sender, recipient, amount);
		doApprove(sender, _msgSender(), _allowances[sender][_msgSender()] - amount); // Will fail when there is not enough allowance
		return true;
	}
	

	function approve(address spender, uint256 amount) public override returns (bool) {
		doApprove(_msgSender(), spender, amount);
		return true;
	}
	
	
	function doTransfer(address sender, address recipient, uint256 amount) private {
		require(sender != address(0), "Transfer from the zero address is not allowed");
		require(recipient != address(0), "Transfer to the zero address is not allowed");
		require(amount > 0, "Transfer amount must be greater than zero");
		
		
		// Ensure that amount is within the limit
		if (!_addressesExcludedFromTransactionLimit[sender] && !_addressesExcludedFromTransactionLimit[recipient]) {
			require(amount <= _maxTransactionAmount, "Transfer amount exceeds the maximum allowed");
		}

		// Perform a swap if needed.  A swap in the context of this contract is the process of swapping the contract's token balance with BNBs in order to provide liquidity and increase the reward pool
		executeSwapIfNeeded(sender, recipient);

		// Extend the reward cycle according to the amount transferred.  This is done so that users do not abuse the cycle (buy before it ends & sell after they claim the reward)
		_nextAvailableClaimDate[recipient] += calculateRewardCycleExtension(balanceOf(recipient), amount);
		_nextAvailableClaimDate[sender] += calculateRewardCycleExtension(balanceOf(sender), amount);
		
		// Calculate distribution & pool rates
		(uint256 distributionFeeRate, uint256 poolFeeRate) = calculateFeeRates(sender, recipient);
		
		uint256 distributionAmount = amount * distributionFeeRate / 100;
		uint256 poolAmount = amount * poolFeeRate / 100;
		uint256 transferAmount = amount - distributionAmount - poolAmount;

		// Update balances
		updateBalances(sender, recipient, amount, distributionAmount, poolAmount);

		// Update total fees, these are just counters provided for visibility
		_totalFeesDistributed += distributionAmount;
		_totalFeesPooled += poolAmount;

		emit Transfer(sender, recipient, transferAmount); 
	}


	function updateBalances(address sender, address recipient, uint256 amount, uint256 distributionAmount, uint256 poolAmount) private {
		// Calculate the current distribution rate.  Because the rate is inversely applied on the balances in the balanceOf method, we need to apply it when updating the balances
		uint256 currentRate = calculateDistributionRate();

		// Calculate amount to be sent by sender
		uint256 sentAmount = amount * currentRate;
		
		// Calculate amount to be received by recipient
		uint256 rDistributionAmount = distributionAmount * currentRate;
		uint256 rPoolAmount = poolAmount * currentRate;
		uint256 receivedAmount = sentAmount - rDistributionAmount - rPoolAmount;

		// Update balances
		_balances[sender] -= sentAmount;
		_balances[recipient] += receivedAmount;
		
		// Add pool to contract
		_balances[address(this)] += rPoolAmount;
		
		// Update the distribution available.  By doing so, we're reducing the rate therefore everyone's balance goes up accordingly
		_totalDistributionAvailable -= rDistributionAmount;

		// Note: Since we burned a big portion of the tokens during contract creation, the burn wallet will also receive a cut from the distribution
	}
	

	function doApprove(address owner, address spender, uint256 amount) private {
		require(owner != address(0), "Cannot approve from the zero address");
		require(spender != address(0), "Cannot approve to the zero address");

		_allowances[owner][spender] = amount;
		
		emit Approval(owner, spender, amount);
	}

	
	// Returns the current distribution rate, which is _totalDistributionAvailable/_totalTokens
	// This means that it starts high and goes down as time goes on (distribution available decreases).  Min value is 1
	function calculateDistributionRate() public view returns(uint256) {
		if (_totalDistributionAvailable < _totalTokens) {
			return 1;
		}
		
		return _totalDistributionAvailable / _totalTokens;
	}
	

	function calculateFeeRates(address sender, address recipient) private view returns(uint256, uint256) {
		bool applyFees = _isFeeEnabled && !_addressesExcludedFromFees[sender] && !_addressesExcludedFromFees[recipient];
		if (applyFees)
		{
			return (_distributionFee, _poolFee);
		}

		return (0, 0);
	}

	
	function executeSwapIfNeeded(address sender, address recipient) private {
		if (!_isSwapEnabled) {
			return;
		}

		// Check if it's time to swap for liquidity & reward pool
		uint256 tokensAvailableForSwap = balanceOf(address(this));
		if (tokensAvailableForSwap >= _tokenSwapThreshold) {

			// Limit to threshold & max transaction amount
			tokensAvailableForSwap = _tokenSwapThreshold;
			if (tokensAvailableForSwap > _maxTransactionAmount)
			{
				tokensAvailableForSwap = _maxTransactionAmount;
			}

			// Make sure that we are not stuck in a loop (Swap only once)
			bool isFromContractToPair = sender == address(this) && recipient == _pancakeswapV2Pair;
			if (!isFromContractToPair && sender != _pancakeswapV2Pair) {
				executeSwap(tokensAvailableForSwap);
			}
		}
	}
	

	function executeSwap(uint256 amount) private {
		// The amount parameter includes both the liquidity and the reward tokens, we need to find the correct portion for each one so that they are allocated accordingly
		uint256 tokensReservedForLiquidity = amount * _liquidityFee / _poolFee;
		uint256 tokensReservedForReward = amount - tokensReservedForLiquidity;

		// For the liquidity portion, half of it will be swapped for BNB and the other half will be used to add the BNB into the liquidity
		uint256 tokensToSwapForLiquidity = tokensReservedForLiquidity / 2;
		uint256 tokensToAddAsLiquidity = tokensToSwapForLiquidity;

		// Swap both reward tokens and liquidity tokens for BNB
		uint256 tokensToSwap = tokensReservedForReward + tokensToSwapForLiquidity;
		uint256 bnbSwapped = swapTokensForBNB(tokensToSwap);
		
		// Calculate what portion of the swapped BNB is for liquidity and supply it using the other half of the token liquidity portion.  The remaining BNBs in the contract represent the reward pool
		uint256 bnbToBeAddedToLiquidity = bnbSwapped * tokensToSwapForLiquidity / tokensToSwap;
		(,uint bnbAddedToLiquidity,) = _pancakeswapV2Router.addLiquidityETH{value: bnbToBeAddedToLiquidity}(address(this), tokensToAddAsLiquidity, 0, 0, owner(), block.timestamp + 360);

		// Keep track of how many BNB were added to liquidity this way
		_totalBNBLiquidityAddedFromFees += bnbAddedToLiquidity;
		
		emit Swapped(tokensToSwap, bnbSwapped, tokensToAddAsLiquidity, bnbToBeAddedToLiquidity);
	}
	
	
	// This function swaps a {tokenAmount} of XLD tokens for BNB and returns the total amount of BNB received
	function swapTokensForBNB(uint256 tokenAmount) private  returns(uint256) {
		uint256 initialBalance = address(this).balance;
		
		// Generate pair for XLD -> WBNB
		address[] memory path = new address[](2);
		path[0] = address(this);
		path[1] = _pancakeswapV2Router.WETH();

		// Swap
		_pancakeswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(tokenAmount, 0, path, address(this), block.timestamp + 360);
		
		// Return the amount received
		return address(this).balance - initialBalance;
	}


	function claimReward() isHuman nonReentrant public {
		require(_nextAvailableClaimDate[msg.sender] <= block.timestamp, "Claim date for this address has not passed yet");
		require(balanceOf(msg.sender) >= 0, "The address must own XLD before claiming a reward");

		uint256 reward = calculateBNBReward(msg.sender);

		// If reward is over the charity threshold
		if (reward >= _charityThreshold) {

			// Use a percentage of it to transfer it to charity wallet
			uint256 charityAmount = reward * _charityPercentage / 100;
			(bool success, ) = _charityAddress.call{ value: charityAmount }("");
			require(success, "Charity transaction failed");	
			
			reward -= charityAmount;
		}

		// Update the next claim date & the total amount claimed
		_nextAvailableClaimDate[msg.sender] = block.timestamp + rewardCyclePeriod();
		_rewardsClaimed[msg.sender] += reward;
		_totalBNBClaimed += reward;

		// Fire the event
		emit BNBClaimed(msg.sender, reward, _nextAvailableClaimDate[msg.sender]);

		// Send the reward to the caller
		(bool sent,) = msg.sender.call{value : reward}("");
		require(sent, "Reward transaction failed");
	}

	// This function calculates how much (and if) the reward cycle of an address should increase based on its current balance and the amount transferred in a transaction
	function calculateRewardCycleExtension(uint256 balance, uint256 amount) public view returns (uint256) {
		uint256 basePeriod = rewardCyclePeriod();

		if (balance == 0) {
			// Receiving $XLD on a zero balance address:
			// This means that either the address has never received tokens before (So its current reward date is 0) in which case we need to set its initial value
			// Or the address has transferred all of its tokens in the past and has now received some again, in which case we will set the reward date to a date very far in the future
			return block.timestamp + basePeriod;
		}

		uint256 rate = amount * 100 / balance;

		// Depending on the % of $XLD tokens transferred, relative to the balance, we might need to extend the period
		if (rate >= _rewardCycleExtensionThreshold) {

			// If new balance is X percent higher, then we will extend the reward date by X percent
			uint256 extension = basePeriod * rate / 100;

			// Cap to the base period
			if (extension >= basePeriod) {
				extension = basePeriod;
			}

			return extension;
		}

		return 0;
	}


	function calculateBNBReward(address ofAddress) public view returns (uint256) {
		uint256 holdersAmount = totalAmountOfTokensHeld();

		uint256 balance = balanceOf(ofAddress);
		uint256 bnbPool =  address(this).balance;

		// If an address is holding X percent of the supply, then it can claim up to X percent of the reward pool
		uint256 reward = bnbPool * balance / holdersAmount;

		// Low-balance addresses will have their fee refunded when claiming a reward
		if (balance < _claimRewardGasFeeRefundThreshold) 
		{
			uint256 estimatedGasFee = claimRewardGasFeeEstimation();
			if (bnbPool > reward + estimatedGasFee)
			{
				reward += estimatedGasFee;
			}
		}

		return reward;
	}


	function onOwnershipRenounced(address previousOwner) internal override {
		// This is to make sure that once ownership is renounced, the original owner is no longer excluded from fees and from the transaction limit
		_addressesExcludedFromFees[previousOwner] = false;
		_addressesExcludedFromTransactionLimit[previousOwner] = false;
	}


	// Returns how many more $XLD tokens are needed in the contract before triggering a swap
	function amountUntilSwap() public view returns (uint256) {
		uint256 balance = balanceOf(address(this));
		if (balance > _tokenSwapThreshold) {
			// Swap on next relevant transaction
			return 0;
		}

		return _tokenSwapThreshold - balance;
	}


	function increaseAllowance(address spender, uint256 addedValue) public virtual returns (bool) {
		doApprove(_msgSender(), spender, _allowances[_msgSender()][spender] + addedValue);
		return true;
	}


	function decreaseAllowance(address spender, uint256 subtractedValue) public virtual returns (bool) {
		doApprove(_msgSender(), spender, _allowances[_msgSender()][spender] - subtractedValue);
		return true;
	}

	function setPancakeSwapRouter(address routerAddress) public onlyOwner {
		_pancakeSwapRouterAddress = routerAddress; 
		_pancakeswapV2Router = IPancakeRouter02(_pancakeSwapRouterAddress);
		_pancakeswapV2Pair = IPancakeFactory(_pancakeswapV2Router.factory()).createPair(address(this), _pancakeswapV2Router.WETH());
	}

	// This function can also be used in case the fees of the contract need to be adjusted later on as the volume grows
	function setFees(uint8 liquidityFee, uint8 rewardFee, uint8 distributionFee) public onlyOwner 
	{
		require(liquidityFee >= 1 && liquidityFee <= 6, "Liquidity fee must be between 1% and 6%");
		require(rewardFee >= 1 && rewardFee <= 15, "Reward fee must be between 1% and 15%");
		require(distributionFee >= 0 && distributionFee <= 2, "Distribution fee must be between 0% and 2%");
		require(liquidityFee + rewardFee + distributionFee <= 15, "Total fees cannot exceed 15%");

		_distributionFee = distributionFee;
		_liquidityFee = liquidityFee;
		_rewardFee = rewardFee;
		
		// Enforce invariant
		_poolFee = _rewardFee + _liquidityFee; 
	}

	// This function will be used to reduce the limit later on, according to the price of the token
	function setTransactionLimit(uint256 limit) public onlyOwner {
		require(limit >= 100, "Limit must be less than or equal to 1%");
		_maxTransactionAmount = _totalTokens / limit;
	}

	// This can be used for integration with other contracts after partnerships (e.g. reward claiming from sub-tokens)
	function setNextAvailableClaimDate(address ofAddress, uint256 date) public onlyOwner {
		require(date > block.timestamp, "Cannot be a date in the past");
		require(date < block.timestamp + 31 days, "Cannot be more than 31 days in the future");

		_nextAvailableClaimDate[ofAddress] = date;
	}

	function setRewardCycleExtensionThreshold(uint256 threshold) public onlyOwner {
		_rewardCycleExtensionThreshold = threshold;
	}


	function claimRewardGasFeeEstimation() public view returns (uint256) {
		return _claimRewardGasFeeEstimation;
	}


	function claimRewardGasFeeRefundThreshold() public view returns (uint256) {
		return _claimRewardGasFeeRefundThreshold;
	}


	function setClaimRewardGasFeeOptions(uint256 threshold, uint256 gasFee) public onlyOwner 
	{
		_claimRewardGasFeeRefundThreshold = threshold;
		_claimRewardGasFeeEstimation = gasFee;
	}


	function nextAvailableClaimDate(address ofAddress) public view returns (uint256) {
		return _nextAvailableClaimDate[ofAddress];
	}


	function rewardsClaimed(address byAddress) public view returns (uint256) {
		return _rewardsClaimed[byAddress];
	}


	function name() public override pure returns (string memory) {
		return _name;
	}


	function symbol() public override pure returns (string memory) {
		return _symbol;
	}


	function totalSupply() public override pure returns (uint256) {
		return _totalTokens;
	}
	

	function decimals() public override pure returns (uint8) {
		return _decimals;
	}
	

	function totalFeesDistributed() public view returns (uint256) {
		return _totalFeesDistributed;
	}
	

	function allowance(address owner, address spender) public view override returns (uint256) {
		return _allowances[owner][spender];
	}

	
	function maxTransactionAmount() public view returns (uint256) {
		return _maxTransactionAmount;
	}


	function pancakeSwapRouterAddress() public view returns (address) {
		return _pancakeSwapRouterAddress;
	}


	function pancakeSwapPairAddress() public view returns (address) {
		return _pancakeswapV2Pair;
	}


	function totalFeesPooled() public view returns (uint256) {
		return _totalFeesPooled;
	}


	function totalAmountOfTokensHeld() public view returns (uint256) {
		return _totalTokens - balanceOf(address(0)) - balanceOf(_burnWallet) - balanceOf(_pancakeswapV2Pair);
	}


	function totalBNBClaimed() public view returns (uint256) {
		return _totalBNBClaimed;
	}

	function totalBNBLiquidityAddedFromFees() public view returns (uint256) {
		return _totalBNBLiquidityAddedFromFees;
	}


	function rewardCyclePeriod() public pure returns (uint256) {
		return _rewardCyclePeriod;
	}

	function isSwapEnabled() public view returns (bool) {
		return _isSwapEnabled;
	}

	function isFeeEnabled() public view returns (bool) {
		return _isFeeEnabled;
	}

	// Ensures that the contract is able to receive BNB
	receive() external payable {}
}