// SPDX-License-Identifier: MIT
// STELLAR DIAMOND [XLD]

pragma solidity 0.8.5;

import "./StellarDiamondBase.sol";

contract StellarDiamond is StellarDiamondBase {

	// REWARD CYCLE
	uint256 private _rewardCyclePeriod = 1 days; // The duration of the reward cycle (e.g. can claim rewards once a day)
	uint256 private _rewardCycleExtensionThreshold; // If someone sends or receives more than a % of their balance in a transaction, their reward cycle date will increase accordingly
	mapping(address => uint256) private _nextAvailableClaimDate; // The next available reward claim date for each address

	uint256 private _totalBNBLiquidityAddedFromFees; // The total number of BNB added to the pool through fees
	uint256 private _totalBNBClaimed; // The total number of BNB claimed by all addresses
	uint256 private _totalBNBAsXLDClaimed; // The total number of BNB that was converted to XLD and claimed by all addresses
	mapping(address => uint256) private _bnbRewardClaimed; // The amount of BNB claimed by each address
	mapping(address => uint256) private _bnbAsXLDClaimed; // The amount of BNB converted to XLD and claimed by each address
	mapping(address => bool) private _addressesExcludedFromRewards; // The list of addresses excluded from rewards
	mapping(address => mapping(address => bool)) private _rewardClaimApprovals; //Used to allow an address to claim rewards on behalf of someone else
	mapping(address => uint256) private _claimRewardAsTokensPercentage; //Allows users to optionally use a % of the reward pool to buy XLD automatically
	uint256 private _minRewardBalance; //The minimum balance required to be eligible for rewards
	uint256 private _maxClaimAllowed = 100 ether; // Can only claim up to 100 bnb at a time.
	uint256 private _globalRewardDampeningPercentage = 3; // Rewards are reduced by 3% at the start to fill the main BNB pool faster and ensure consistency in rewards
	uint256 private _mainBnbPoolSize = 10000 ether; // Any excess BNB after the main pool will be used as reserves to ensure consistency in rewards
	bool private _rewardAsTokensEnabled; //If enabled, the contract will give out tokens instead of BNB according to the preference of each user
	uint256 private _gradualBurnMagnitude; // The contract can optionally burn tokens (By buying them from reward pool).  This is the magnitude of the burn (1 = 0.01%).
	uint256 private _gradualBurnTimespan = 7 days; //Burn every 7 days
	uint256 private _lastBurnDate; //The last burn date
	uint256 private _minBnbPoolSizeBeforeBurn = 100 ether; //The minimum amount of BNB that need to be in the pool before initiating gradual burns

	// AUTO-CLAIM
	bool private _autoClaimEnabled;
	uint256 private _maxGasForAutoClaim = 300000; // The maximum gas to consume for processing the auto-claim queue
	address[] _rewardClaimQueue;
	mapping(address => uint) _rewardClaimQueueIndices;
	uint256 private _rewardClaimQueueIndex;
	mapping(address => bool) _addressesInRewardClaimQueue; // Mapping between addresses and false/true depending on whether they are queued up for auto-claim or not

	event RewardClaimed(address recipient, uint256 amountBnb, uint256 amountTokens, uint256 nextAvailableClaimDate);
	event Burned(uint256 bnbAmount);

	constructor (address routerAddress) StellarDiamondBase(routerAddress) {
		// Exclude addresses from rewards
		_addressesExcludedFromRewards[BURN_WALLET] = true;
		_addressesExcludedFromRewards[owner()] = true;
		_addressesExcludedFromRewards[address(this)] = true;
		_addressesExcludedFromRewards[address(0)] = true;

		// If someone sends or receives more than 15% of their balance in a transaction, their reward cycle date will increase accordingly
		setRewardCycleExtensionThreshold(15);
	}


	// This function is used to enable all functions of the contract, after the setup of the token sale (e.g. Liquidity) is completed
	function onActivated() internal override {
		super.onActivated();

		setRewardAsTokensEnabled(true);
		setAutoClaimEnabled(true);
		setMinRewardBalance(totalSupply() / 100000);  //At least 0.001% is required to be eligible for rewards
		setGradualBurnMagnitude(1); //Buy tokens using 0.01% of reward pool every 7 days and burn them
		_lastBurnDate = block.timestamp;
	}


    function onTransfer(address sender, address recipient, uint256 amount) internal override {
        super.onTransfer(sender, recipient, amount);

		// Process gradual burns
		processGradualBurn();

        // Extend the reward cycle according to the amount transferred.  This is done so that users do not abuse the cycle (buy before it ends & sell after they claim the reward)
		_nextAvailableClaimDate[recipient] += calculateRewardCycleExtension(balanceOf(recipient), amount);
		_nextAvailableClaimDate[sender] += calculateRewardCycleExtension(balanceOf(sender), amount);
		
        // Update auto-claim queue
		updateAutoClaimQueue(sender);
		updateAutoClaimQueue(recipient);

        // Trigger auto-claim
		if (isAutoClaimEnabled() && !isSwapTransfer(sender, recipient)) {
	    	try this.processRewardClaimQueue(_maxGasForAutoClaim) { } catch { }
		}
    }


	function processGradualBurn() private {
		if (!shouldBurn()) {
			return;
		}

		uint256 burnAmount = address(this).balance * _gradualBurnMagnitude / 10000;
		doBuyAndBurn(burnAmount);
	}


	function updateAutoClaimQueue(address user) private {
		bool isQueued = _addressesInRewardClaimQueue[user];
		bool includedInRewards = balanceOf(user) >= _minRewardBalance && !_addressesExcludedFromRewards[user];

		if (includedInRewards) {
			if (isQueued) {
				// Need to dequeue
				uint index = _rewardClaimQueueIndices[user];
				address lastUser = _rewardClaimQueue[_rewardClaimQueue.length - 1];

				// Move the last one to this index, and pop it
				_rewardClaimQueueIndices[lastUser] = index;
				_rewardClaimQueue[index] = lastUser;
				_rewardClaimQueue.pop();

				// Clean-up
				delete _rewardClaimQueueIndices[user];
				delete _addressesInRewardClaimQueue[user];
			}
		} else {
			if (!isQueued) {
				// Need to enqueue
				_rewardClaimQueue.push(user);
				_rewardClaimQueueIndices[user] = _rewardClaimQueue.length - 1;
				_addressesInRewardClaimQueue[user] = true;
			}
		}
	}


    function claimReward() isHuman nonReentrant external {
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
		// Update the next claim date & the total amount claimed
		_nextAvailableClaimDate[user] = block.timestamp + rewardCyclePeriod();

		(uint256 claimBnb, uint256 claimBnbAsTokens) = calculateClaimRewards(user);

        // Claim BNB & tokens
		bool success = claimXLD(user, claimBnbAsTokens) && claimBNB(user, claimBnb);

		// Fire the event
		if (success) {
			emit RewardClaimed(user, claimBnb, claimBnbAsTokens, _nextAvailableClaimDate[user]);
		}
		
		return success;
	}


	function claimBNB(address user, uint256 bnbAmount) private returns (bool) {
		if (bnbAmount == 0) {
			return true;
		}

		// Send the reward to the caller
		(bool sent,) = user.call{value : bnbAmount}("");
		if (!sent) {
			return false;
		}
	
		_bnbRewardClaimed[user] += bnbAmount;
		_totalBNBClaimed += bnbAmount;
		return true;
	}


	function claimXLD(address user, uint256 bnbAmount) private returns (bool) {
		if (bnbAmount == 0) {
			return true;
		}

		bool success = swapBNBForTokens(bnbAmount, address(this), user);
		if (!success) {
			return false;
		}

		_bnbAsXLDClaimed[user] += bnbAmount;
		_totalBNBAsXLDClaimed += bnbAmount;
		return true;
	}


	function processRewardClaimQueue(uint256 gas) public {
		require(gas > 0, "Gas limit is required");

		uint256 numberOfHolders = _rewardClaimQueue.length;

		if (numberOfHolders == 0) {
			return;
		}

		uint256 gasUsed = 0;
		uint256 gasLeft = gasleft();
		uint256 iteration = 0;

		// Keep claiming rewards from the list until we either consume all available gas or we finish one cycle
		while (gasUsed < gas && iteration < numberOfHolders) {
			if (_rewardClaimQueueIndex >= numberOfHolders) {
				_rewardClaimQueueIndex = 0;
			}

			address user = _rewardClaimQueue[_rewardClaimQueueIndex];
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
			_rewardClaimQueueIndex++;
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


	function calculateClaimRewards(address ofAddress) public view returns (uint256, uint256) {
		uint256 reward = calculateBNBReward(ofAddress);

		uint256 claimBnbAsTokens = 0;
		if (_rewardAsTokensEnabled) {
			uint256 percentage = _claimRewardAsTokensPercentage[ofAddress];
			claimBnbAsTokens = reward * percentage / 100;
		} 

		uint256 claimBnb = reward - claimBnbAsTokens;

		return (claimBnb, claimBnbAsTokens);
	}


	function calculateBNBReward(address ofAddress) public view returns (uint256) {
		uint256 holdersAmount = totalAmountOfTokensHeld();

		uint256 balance = balanceOf(ofAddress);
		uint256 bnbPool =  address(this).balance * (100 - _globalRewardDampeningPercentage) / 100;
		if (bnbPool > _mainBnbPoolSize) {
			bnbPool = _mainBnbPoolSize;
		}

		// If an address is holding X percent of the supply, then it can claim up to X percent of the reward pool
		uint256 reward = bnbPool * balance / holdersAmount;

		if (reward > _maxClaimAllowed) {
			reward = _maxClaimAllowed;
		}

		return reward;
	}


	function onPancakeSwapRouterUpdated() internal override { 
		_addressesExcludedFromRewards[pancakeSwapRouterAddress()] = true;
		_addressesExcludedFromRewards[pancakeSwapPairAddress()] = true;
	}


	function shouldBurn() public view returns(bool) {
		return _gradualBurnMagnitude > 0 && address(this).balance >= _minBnbPoolSizeBeforeBurn && block.timestamp - _lastBurnDate > _gradualBurnTimespan;
	}


	function buyAndBurn(uint256 bnbAmount) external onlyOwner {
		require(bnbAmount <= address(this).balance / 10, "Burn is too high");
		require(bnbAmount > 0, "Amount must be greater than zero");

		doBuyAndBurn(bnbAmount);
	}


	function doBuyAndBurn(uint256 bnbAmount) private {
		if (bnbAmount == 0) {
			return;
		}

		require(bnbAmount < address(this).balance, "Not enough balance");

		swapBNBForTokens(bnbAmount, address(this), BURN_WALLET);
		_lastBurnDate = block.timestamp;
		emit Burned(bnbAmount);
	}


    function rewardsClaimed(address byAddress) public view returns (uint256) {
		return _bnbRewardClaimed[byAddress];
	}


    function totalBNBClaimed() public view returns (uint256) {
		return _totalBNBClaimed;
	}


    function rewardCyclePeriod() public view returns (uint256) {
		return _rewardCyclePeriod;
	}


	function setRewardCyclePeriod(uint256 period) public onlyOwner {
		require(period > 0 && period <= 7 days, "Value out of range");
		_rewardCyclePeriod = period;
	}


	function setRewardCycleExtensionThreshold(uint256 threshold) public onlyOwner {
		_rewardCycleExtensionThreshold = threshold;
	}


	function nextAvailableClaimDate(address ofAddress) public view returns (uint256) {
		return _nextAvailableClaimDate[ofAddress];
	}


	function maxClaimAllowed() public view returns (uint256) {
		return _maxClaimAllowed;
	}


	function setMaxClaimAllowed(uint256 value) public onlyOwner {
		require(value > 0, "Value must be greater than zero");
		_maxClaimAllowed = value;
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


	function isRewardAsTokensEnabled() public view returns(bool) {
		return _rewardAsTokensEnabled;
	}


	function setRewardAsTokensEnabled(bool isEnabled) public onlyOwner {
		_rewardAsTokensEnabled = isEnabled;
	}


	function gradualBurnMagnitude() public view returns (uint256) {
		return _gradualBurnMagnitude;
	}


	function setGradualBurnMagnitude(uint256 magnitude) public onlyOwner {
		require(magnitude <= 100, "Must be equal or less to 100");
		_gradualBurnMagnitude = magnitude;
	}


	function gradualBurnTimespan() public view returns (uint256) {
		return _gradualBurnTimespan;
	}


	function setGradualBurnTimespan(uint256 timespan) public onlyOwner {
		require(timespan >= 1 hours, "Cannot be less than an hour");
		_gradualBurnTimespan = timespan;
	}


	function minBnbPoolSizeBeforeBurn() public view returns(uint256) {
		return _minBnbPoolSizeBeforeBurn;
	}


	function setMinBnbPoolSizeBeforeBurn(uint256 amount) public onlyOwner {
		require(amount > 0, "Amount must be greater than zero");
		_minBnbPoolSizeBeforeBurn = amount;
	}


	function claimRewardAsTokensPercentage(address ofAddress) public view returns(uint256) {
		return _claimRewardAsTokensPercentage[ofAddress];
	}


	function setClaimRewardAsTokensPercentage(uint256 amount) public {
		require(amount <= 100, "Cannot exceed 100%");
		_claimRewardAsTokensPercentage[msg.sender] = amount;
	}


	function mainBnbPoolSize() public view returns (uint256) {
		return _mainBnbPoolSize;
	}


	function setMainBnbPoolSize(uint256 size) public onlyOwner {
		require(size >= 1 ether, "Size is too small");
		_mainBnbPoolSize = size;
	}
}