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
	uint8 private _additionalSellFee; //Additional % fee to apply on sell transactions
	uint8 private _poolFee; //The total fee to be taken and added to the pool, this includes both the liquidity fee and the reward fee

	uint256 private constant _totalTokens = 1000000000000 * 10**_decimals;	//1 trillion total supply
	mapping (address => uint256) private _balances; //The balance of each address.  This is before applying distribution rate.  To get the actual balance, see balanceOf() method
	mapping (address => mapping (address => uint256)) private _allowances;

	// FEES & REWARDS
	bool private _isSwapEnabled; // True if the contract should swap for liquidity & reward pool, false otherwise
	bool private _isFeeEnabled; // True if fees should be applied on transactions, false otherwise
	address private constant _burnWallet = 0x000000000000000000000000000000000000dEaD; //The address that keeps track of all tokens burned
	uint256 private _tokenSwapThreshold = _totalTokens / 100000; //There should be at least 0.0001% of the total supply in the contract before triggering a swap
	uint256 private _rewardCyclePeriod = 1 days; // The duration of the reward cycle (e.g. can claim rewards once a day)
	uint256 private _rewardCycleExtensionThreshold; // If someone sends or receives more than a % of their balance in a transaction, their reward cycle date will increase accordingly
	uint256 private _totalFeesDistributed; // The total fees distributed (in number of tokens)
	uint256 private _totalFeesPooled; // The total fees pooled (in number of tokens)
	uint256 private _totalBNBLiquidityAddedFromFees; // The total number of BNB added to the pool through fees
	uint256 private _totalBNBClaimed; // The total number of BNB claimed by all addresses
	mapping (address => bool) private _addressesExcludedFromFees; // The list of addresses that do not pay a fee for transactions
	mapping(address => uint256) private _nextAvailableClaimDate; // The next available reward claim date for each address
	mapping(address => uint256) private _rewardsClaimed; // The amount of BNB claimed by each address
	mapping(address => bool) private _addressesExcludedFromRewards; // The list of addresses excluded from rewards
	uint256 private _totalDistributionAvailable = (MAX - (MAX % _totalTokens)); //Indicates the amount of distribution available. Min value is _totalTokens. This is divisible by _totalTokens without any remainder
	mapping(address => mapping(address => bool)) private _rewardClaimApprovals; //Used to allow an address to claim rewards on behalf of someone else
	mapping(address => address) private _claimAsTokensRequest; //Allows users to optional specify a token address to use as reward claiming (Instead of receiving BNB). address(0) indicates BNB preference.
	mapping(address => bool) private _allowedTokensForClaim; //Used to indicate which token addresses can be used for claiming
	uint256 private _minRewardBalance; //The minimum balance required to be eligible for rewards
	uint256 private _autoClaimIndex;
	uint256 private _maxGasForAutoClaim;
	uint256 private _maxClaimAllowed; // Maximum amount of BNB that can be claimed at once
	uint256 private _globalRewardDampeningPercentage;
	bool private _autoClaimEnabled;
	bool private _isActivated;

	// HOLDERS TRACKING
	address[] _autoClaimQueue;
	mapping(address => uint) _autoClaimQueueIndices;
	mapping(address => bool) _addressesInAutoClaimQueue; // Mapping between addresses and false/true depending on whether they are queued up for auto-claim or not

	// TRANSACTION LIMIT
	uint256 private _maxTransactionAmount = _totalTokens; // The amount of tokens that can be sold at once

	// PANCAKESWAP INTERFACES (For swaps)
	address private _pancakeSwapRouterAddress;
	IPancakeRouter02 private _pancakeswapV2Router;
	address private _pancakeswapV2Pair;
	address private _autoLiquidityWallet;

	// EVENTS
	event Swapped(uint256 tokensSwapped, uint256 bnbReceived, uint256 tokensIntoLiqudity, uint256 bnbIntoLiquidity);
	event RewardClaimed(address recipient, uint256 amountInBnb, address tokenAddress, uint256 nextAvailableClaimDate);
	
	constructor (address routerAddress) {
		_balances[_msgSender()] = _totalDistributionAvailable;
		
		// Exclude addresses from fees
		_addressesExcludedFromFees[address(this)] = true;
		_addressesExcludedFromFees[owner()] = true;

		// Exclude addresses from rewards
		_addressesExcludedFromRewards[_burnWallet] = true;
		_addressesExcludedFromRewards[owner()] = true;
		_addressesExcludedFromRewards[address(this)] = true;
		_addressesExcludedFromRewards[address(0)] = true;
		
		// Initialize PancakeSwap V2 router and XLD <-> BNB pair.  Router address will be: 0x10ed43c718714eb63d5aa57b78b54704e256024e or for testnet: 0xD99D1c33F9fC3444f8101754aBC46c52416550D1
		setPancakeSwapRouter(routerAddress);

		// 4% liquidity fee, 10% reward fee, 1% distribution fee, 4% additional sell fee
		setFees(4, 10, 1, 4);

		// If someone sends or receives more than 15% of their balance in a transaction, their reward cycle date will increase accordingly
		setRewardCycleExtensionThreshold(15);

		emit Transfer(address(0), _msgSender(), _totalTokens);
	}

	// This function is used to enable all functions of the contract, after the setup of the token sale (e.g. Liquidity) is completed
	function activate() public onlyOwner {
		_isSwapEnabled = true;
		_isFeeEnabled = true;
		_autoLiquidityWallet = owner();
		_minRewardBalance = _totalTokens / 100000; //At least 0.001% is required to be eligible for rewards
		_isActivated = true;
		setTransactionLimit(1000); // only 0.1% of the total supply can be sold at once
		setMaxGasForAutoClaim(300000);
		setAutoClaimEnabled(true);
		setGlobalRewardDampeningPercentage(5); // This is used to sustain the pool and make rewards more consistent
		setMaxClaimAllowed(100 ether); // Can only claim up to 100 bnb at a time
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
		
		
		// Ensure that amount is within the limit in case we are selling
		if (isTransferLimited(sender, recipient)) {
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

		// Trigger auto-claim
		if (_autoClaimEnabled && !isSwapTransfer(sender, recipient)) {
	    	try this.processRewardClaimQueue(_maxGasForAutoClaim) { } catch { }
		}
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

		// Update auto-claim queue
		updateAutoClaimQueue(sender);
		updateAutoClaimQueue(recipient);
	}


	function updateAutoClaimQueue(address user) private {
		bool isQueued = _addressesInAutoClaimQueue[user];
		bool includedInRewards = balanceOf(user) >= _minRewardBalance && !_addressesExcludedFromRewards[user];

		if (includedInRewards) {
			if (isQueued) {
				// Need to dequeue
				uint index = _autoClaimQueueIndices[user];
				address lastUser = _autoClaimQueue[_autoClaimQueue.length - 1];

				// Move the last one to this index, and pop it
				_autoClaimQueueIndices[lastUser] = index;
				_autoClaimQueue[index] = lastUser;
				_autoClaimQueue.pop();

				// Clean-up
				delete _autoClaimQueueIndices[user];
				delete _addressesInAutoClaimQueue[user];
			}
		} else {
			if (!isQueued) {
				// Need to enqueue
				_autoClaimQueue.push(user);
				_autoClaimQueueIndices[user] = _autoClaimQueue.length - 1;
				_addressesInAutoClaimQueue[user] = true;
			}
		}
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
		if (applyFees) {
			if (isPancakeSwapPair(recipient)) {
				return (_distributionFee, _poolFee + _additionalSellFee);
			}

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

			// Limit to threshold
			tokensAvailableForSwap = _tokenSwapThreshold;

			// Make sure that we are not stuck in a loop (Swap only once)
			if (!isSwapTransfer(sender, recipient)) {
				executeSwap(tokensAvailableForSwap);
			}
		}
	}


	function executeSwap(uint256 amount) private {
		// Allow pancakeSwap to spend the tokens of the address
		doApprove(address(this), _pancakeSwapRouterAddress, amount);

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
		(,uint bnbAddedToLiquidity,) = _pancakeswapV2Router.addLiquidityETH{value: bnbToBeAddedToLiquidity}(address(this), tokensToAddAsLiquidity, 0, 0, _autoLiquidityWallet, block.timestamp + 360);

		// Keep track of how many BNB were added to liquidity this way
		_totalBNBLiquidityAddedFromFees += bnbAddedToLiquidity;
		
		emit Swapped(tokensToSwap, bnbSwapped, tokensToAddAsLiquidity, bnbToBeAddedToLiquidity);
	}


	function isTransferLimited(address sender, address recipient) private view returns(bool) {
		bool isSelling = isPancakeSwapPair(recipient);
		return isSelling && !isSwapTransfer(sender, recipient);
	}


	function isSwapTransfer(address sender, address recipient) private view returns(bool) {
		bool isContractSelling = sender == address(this) && isPancakeSwapPair(recipient);
		bool isRouterRemovingLiq = sender == _pancakeSwapRouterAddress;
		return !isContractSelling && !isRouterRemovingLiq;
	}
	
	
	// This function swaps a {tokenAmount} of XLD tokens for BNB and returns the total amount of BNB received
	function swapTokensForBNB(uint256 tokenAmount) private returns(uint256) {
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


	function swapBNBForTokens(uint256 bnbAmount, address tokenAddress, address to) private returns(bool) {
		address[] memory path = new address[](2);
		path[0] = tokenAddress;
		path[1] = _pancakeswapV2Router.WETH();


		try _pancakeswapV2Router.swapExactETHForTokensSupportingFeeOnTransferTokens{ value: bnbAmount }(0, path, to, block.timestamp + 360) { 
			return true;
		} 
		catch { 
			return false;
		}
	}


	function claimReward() isHuman nonReentrant public {
		claimReward(msg.sender);
	}


	function claimReward(address user) public {
		require(msg.sender == user || isClaimApproved(user, msg.sender), "You are not allowed to claim rewards on behalf of this user");
		require(isRewardReady(user), "Claim date for this address has not passed yet");
		require(balanceOf(user) > _minRewardBalance, "The address must own XLD before claiming a reward");
		require(!_addressesExcludedFromRewards[user], "Address is excluded from rewards");

		bool success = doClaimReward(user);
		require(success, "Reward claim failed");
	}


	function doClaimReward(address user) private returns (bool) {
		uint256 reward = calculateBNBReward(user);

		// Update the next claim date & the total amount claimed
		_nextAvailableClaimDate[user] = block.timestamp + rewardCyclePeriod();
		_rewardsClaimed[user] += reward;
		_totalBNBClaimed += reward;


		address tokenAddress = _claimAsTokensRequest[user];
		if (!_allowedTokensForClaim[tokenAddress]) {
			tokenAddress = address(0);
		}

		bool success;
		if (tokenAddress == address(0)) {
			// Send the reward to the caller
			(bool sent,) = user.call{value : reward}("");
			success = sent;
		} else {
			// Send reward as tokens
			success = swapBNBForTokens(reward, tokenAddress, user);
		}
		
		// Fire the event
		if (success) {
			emit RewardClaimed(user, reward, tokenAddress, _nextAvailableClaimDate[user]);
		}
		
		return success;
	}

	function processRewardClaimQueue(uint256 gas) public {
		require(gas > 0, "Gas is required");
		uint256 numberOfHolders = _autoClaimQueue.length;

		if (numberOfHolders <= 1) {
			return;
		}

		uint256 gasUsed = 0;
		uint256 gasLeft = gasleft();
		uint256 iteration = 1;

		// Keep claiming rewards from the list until we either consume all available gas or we finish one cycle
		while (gasUsed < gas && iteration < numberOfHolders) {
			if (++_autoClaimIndex >= numberOfHolders) {
				_autoClaimIndex = 1;
			}

			address user = _autoClaimQueue[_autoClaimIndex];
			if (isRewardReady(user)) {
				doClaimReward(user);
			}

			uint256 newGasLeft = gasleft();
			
			if (gasLeft > newGasLeft) {
				uint256 consumedGas = gasLeft - newGasLeft;
				gasUsed += consumedGas;
				gasLeft = newGasLeft;
			}

			iteration++;
		}
	}


	function isRewardReady(address user) public view returns(bool) {
		return _nextAvailableClaimDate[user] <= block.timestamp;
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
		uint256 bnbPool =  address(this).balance * (100 - _globalRewardDampeningPercentage) / 100;

		// If an address is holding X percent of the supply, then it can claim up to X percent of the reward pool
		uint256 reward = bnbPool * balance / holdersAmount;

		if (reward > _maxClaimAllowed) {
			reward = _maxClaimAllowed;
		}

		return reward;
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

		_addressesExcludedFromRewards[_pancakeSwapRouterAddress] = true;
		_addressesExcludedFromRewards[_pancakeswapV2Pair] = true;
	}

	function isPancakeswapPair(address addr) public view returns(bool) {
		return _pancakeswapV2Pair == addr;
	}

	// This function can also be used in case the fees of the contract need to be adjusted later on as the volume grows
	function setFees(uint8 liquidityFee, uint8 rewardFee, uint8 distributionFee, uint8 additionalSellFee) public onlyOwner 
	{
		require(liquidityFee >= 1 && liquidityFee <= 6, "Liquidity fee must be between 1% and 6%");
		require(rewardFee >= 1 && rewardFee <= 15, "Reward fee must be between 1% and 15%");
		require(distributionFee >= 0 && distributionFee <= 2, "Distribution fee must be between 0% and 2%");
		require(liquidityFee + rewardFee + distributionFee <= 15, "Total fees cannot exceed 15%");
		require(additionalSellFee <= 5, "Additional sell fee cannot exceed 5%");

		_distributionFee = distributionFee;
		_liquidityFee = liquidityFee;
		_rewardFee = rewardFee;
		_additionalSellFee = additionalSellFee;
		
		// Enforce invariant
		_poolFee = _rewardFee + _liquidityFee; 
	}

	// This function will be used to reduce the limit later on, according to the price of the token
	function setTransactionLimit(uint256 limit) public onlyOwner {
		require(limit >= 1 && limit <= 10000, "Limit must be greater than 0.01%");
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


	function setTokenSwapThreshold(uint256 threshold) public onlyOwner {
		require(threshold > 0, "Threshold must be greater than 0");
		_tokenSwapThreshold = threshold;
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


	function autoLiquidityWallet() public view returns (address) {
		return _autoLiquidityWallet;
	}


	function setAutoLiquidityWallet(address liquidityWallet) public onlyOwner {
		_autoLiquidityWallet = liquidityWallet;
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


	function rewardCyclePeriod() public view returns (uint256) {
		return _rewardCyclePeriod;
	}


	function setRewardCyclePeriod(uint256 period) public onlyOwner {
		require(period > 0 && period <= 7 days, "Value out of range");
		_rewardCyclePeriod = period;
	}


	function isSwapEnabled() public view returns (bool) {
		return _isSwapEnabled;
	}


	function minRewardBalance() public view returns (uint256) {
		return _minRewardBalance;
	}


	function setMinRewardBalance(uint256 balance) public onlyOwner {
		_minRewardBalance = balance;
	}


	function maxGasForAutoClaim() public view returns (uint256) {
		return _maxGasForAutoClaim;
	}


	function setMaxGasForAutoClaim(uint256 gas) public onlyOwner {
		_maxGasForAutoClaim = gas;
	}


	function isAutoClaimEnabled() public view returns (bool) {
		return _autoClaimEnabled;
	}


	function setAutoClaimEnabled(bool isEnabled) public onlyOwner {
		_autoClaimEnabled = isEnabled;
	}


	function isFeeEnabled() public view returns (bool) {
		return _isFeeEnabled;
	}


	function maxClaimAllowed() public view returns (uint256) {
		return _maxClaimAllowed;
	}


	function setMaxClaimAllowed(uint256 value) public onlyOwner {
		_maxClaimAllowed = value;
	}


	function isExcludedFromRewards(address addr) public view returns (bool) {
		return _addressesExcludedFromRewards[addr];
	}


	// Will be used to exclude unicrypt fees/token vesting addresses from rewards
	function setExcludedFromRewards(address addr, bool isExcluded) public onlyOwner {
		_addressesExcludedFromRewards[addr] = isExcluded;
		updateAutoClaimQueue(addr);
	}

	function globalRewardDampeningPercentage() public view returns(uint256) {
		return _globalRewardDampeningPercentage;
	}


	function setGlobalRewardDampeningPercentage(uint256 value) public onlyOwner {
		require(value <= 90, "Cannot be greater than 90%");
		_globalRewardDampeningPercentage = value;
	}


	function approveClaim(address from, bool isApproved) public {
		_rewardClaimApprovals[msg.sender][from] = isApproved;
	}

	function isClaimApproved(address ofAddress, address from) public view returns(bool) {
		return _rewardClaimApprovals[ofAddress][from];
	}

	// Ensures that the contract is able to receive BNB
	receive() external payable {}
}