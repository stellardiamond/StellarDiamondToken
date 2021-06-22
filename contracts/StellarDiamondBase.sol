// SPDX-License-Identifier: MIT
// STELLAR DIAMOND [XLD]

pragma solidity 0.8.5;

import "./base/token/ERC20/extensions/IERC20Metadata.sol";
import "./base/access/Ownable.sol";
import "./base/utils/Context.sol";
import "./base/token/ERC20/PancakeSwap/IPancakeRouter02.sol";
import "./base/token/ERC20/PancakeSwap/IPancakeFactory.sol";
import "./base/access/ReentrancyGuard.sol";

// Base class that implements: BEP20 interface, fees & swaps
abstract contract StellarDiamondBase is Context, IERC20Metadata, Ownable, ReentrancyGuard {
	// MAIN TOKEN PROPERTIES
	string private constant NAME = "Stellar Diamond";
	string private constant SYMBOL = "XLD";
	uint8 private constant DECIMALS = 9;
	uint8 private _liquidityFee; //% of each transaction that will be added as liquidity
	uint8 private _rewardFee; //% of each transaction that will be used for BNB reward pool
	uint8 private _additionalSellFee; //Additional % fee to apply on sell transactions
	uint8 private _poolFee; //The total fee to be taken and added to the pool, this includes both the liquidity fee and the reward fee

	uint256 private constant _totalTokens = 1000000000000 * 10**DECIMALS;	//1 trillion total supply
	mapping (address => uint256) private _balances; //The balance of each address.  This is before applying distribution rate.  To get the actual balance, see balanceOf() method
	mapping (address => mapping (address => uint256)) private _allowances;

	// FEES & REWARDS
	bool private _isSwapEnabled; // True if the contract should swap for liquidity & reward pool, false otherwise
	bool private _isFeeEnabled; // True if fees should be applied on transactions, false otherwise
	address public constant BURN_WALLET = 0x000000000000000000000000000000000000dEaD; //The address that keeps track of all tokens burned
	uint256 private _tokenSwapThreshold = _totalTokens / 100000; //There should be at least 0.0001% of the total supply in the contract before triggering a swap
	uint256 private _totalFeesPooled; // The total fees pooled (in number of tokens)
	uint256 private _totalBNBLiquidityAddedFromFees; // The total number of BNB added to the pool through fees
	mapping (address => bool) private _addressesExcludedFromFees; // The list of addresses that do not pay a fee for transactions
	bool internal _isSwappingTokens;

	// TRANSACTION LIMIT
	uint256 private _maxTransactionAmount = _totalTokens; // The amount of tokens that can be sold at once

	// PANCAKESWAP INTERFACES (For swaps)
	address private _pancakeSwapRouterAddress;
	IPancakeRouter02 private _pancakeswapV2Router;
	address private _pancakeswapV2Pair;
	address private _autoLiquidityWallet;

	// EVENTS
	event Swapped(uint256 tokensSwapped, uint256 bnbReceived, uint256 tokensIntoLiqudity, uint256 bnbIntoLiquidity);


	constructor (address routerAddress) {
		_balances[_msgSender()] = totalSupply();
		
		// Exclude contract from fees
		_addressesExcludedFromFees[address(this)] = true;

		// Initialize PancakeSwap V2 router and XLD <-> BNB pair.  Router address will be: 0x10ed43c718714eb63d5aa57b78b54704e256024e or for testnet: 0xD99D1c33F9fC3444f8101754aBC46c52416550D1
		setPancakeSwapRouter(routerAddress);

		// 4% liquidity fee, 12% reward fee, 3% additional sell fee
		setFees(4, 12, 3);

		emit Transfer(address(0), _msgSender(), totalSupply());
	}


	// This function is used to enable all functions of the contract, after the setup of the token sale (e.g. Liquidity) is completed
	function activate() public onlyOwner {
		setSwapEnabled(true);
		setFeeEnabled(true);
		setAutoLiquidityWallet(owner());
		setTransactionLimit(1000); // only 0.1% of the total supply can be sold at once

		onActivated();
	}


	function onActivated() internal virtual { }


	function balanceOf(address account) public view override returns (uint256) {
		return _balances[account];
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
	
	
	function doTransfer(address sender, address recipient, uint256 amount) internal virtual {
		require(sender != address(0), "Transfer from the zero address is not allowed");
		require(recipient != address(0), "Transfer to the zero address is not allowed");
		require(amount > 0, "Transfer amount must be greater than zero");
		
		// Ensure that amount is within the limit in case we are selling
		if (isTransferLimited(sender, recipient)) {
			require(amount <= _maxTransactionAmount, "Transfer amount exceeds the maximum allowed");
		}

		// Perform a swap if needed.  A swap in the context of this contract is the process of swapping the contract's token balance with BNBs in order to provide liquidity and increase the reward pool
		executeSwapIfNeeded(sender, recipient);

		onBeforeTransfer(sender, recipient, amount);

		// Calculate fee rate
		uint256 feeRate = calculateFeeRate(sender, recipient);
		
		uint256 feeAmount = amount * feeRate / 100;
		uint256 transferAmount = amount - feeAmount;

		// Update balances
		updateBalances(sender, recipient, amount, feeAmount);

		// Update total fees, this is just a counter provided for visibility
		_totalFeesPooled += feeAmount;

		emit Transfer(sender, recipient, transferAmount); 

		onTransfer(sender, recipient, amount);
	}

	function onBeforeTransfer(address sender, address recipient, uint256 amount) internal virtual { }

	function onTransfer(address sender, address recipient, uint256 amount) internal virtual { }


	function updateBalances(address sender, address recipient, uint256 sentAmount, uint256 feeAmount) private {
		// Calculate amount to be received by recipient
		uint256 receivedAmount = sentAmount - feeAmount;

		// Update balances
		_balances[sender] -= sentAmount;
		_balances[recipient] += receivedAmount;
		
		// Add fees to contract
		_balances[address(this)] += feeAmount;
	}


	function doApprove(address owner, address spender, uint256 amount) private {
		require(owner != address(0), "Cannot approve from the zero address");
		require(spender != address(0), "Cannot approve to the zero address");

		_allowances[owner][spender] = amount;
		
		emit Approval(owner, spender, amount);
	}


	function calculateFeeRate(address sender, address recipient) private view returns(uint256) {
		bool applyFees = _isFeeEnabled && !_addressesExcludedFromFees[sender] && !_addressesExcludedFromFees[recipient];
		if (applyFees) {
			if (isPancakeSwapPair(recipient)) {
				return _poolFee + _additionalSellFee;
			}

			return _poolFee;
		}

		return 0;
	}

	
	function executeSwapIfNeeded(address sender, address recipient) private {
		if (!_isSwapEnabled || _isSwappingTokens) {
			return;
		}

		// Check if it's time to swap for liquidity & reward pool
		uint256 tokensAvailableForSwap = balanceOf(address(this));
		if (tokensAvailableForSwap >= _tokenSwapThreshold) {

			// Limit to threshold
			tokensAvailableForSwap = _tokenSwapThreshold;

			// Make sure that we are not stuck in a loop (Swap only once)
			bool isSelling = isPancakeSwapPair(recipient);
			if (!isSwapTransfer(sender, recipient) && isSelling) {
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
		return isSelling && !isSwapTransfer(sender, recipient) && !_isSwappingTokens;
	}


	function isSwapTransfer(address sender, address recipient) public view returns(bool) {
		bool isContractSelling = sender == address(this) && isPancakeSwapPair(recipient);
		return isContractSelling;
	}
	
	
	// This function swaps a {tokenAmount} of XLD tokens for BNB and returns the total amount of BNB received
	function swapTokensForBNB(uint256 tokenAmount) internal returns(uint256) {
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


	function swapBNBForTokens(uint256 bnbAmount, address to) internal returns(bool) { 
		// Generate pair for WBNB -> XLD
		address[] memory path = new address[](2);
		path[0] = _pancakeswapV2Router.WETH();
		path[1] = address(this);


		// Swap, set flag _isSwappingTokens to avoid dealing with swaps or other auto-claim processing etc
		_isSwappingTokens = true;
		try _pancakeswapV2Router.swapExactETHForTokensSupportingFeeOnTransferTokens{ value: bnbAmount }(0, path, to, block.timestamp + 360) { 
			_isSwappingTokens = false;
			return true;
		} 
		catch { 
			_isSwappingTokens = false;
			return false;
		}
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
		require(routerAddress != address(0), "Cannot use the zero address as router address");

		_pancakeSwapRouterAddress = routerAddress; 
		_pancakeswapV2Router = IPancakeRouter02(_pancakeSwapRouterAddress);
		_pancakeswapV2Pair = IPancakeFactory(_pancakeswapV2Router.factory()).createPair(address(this), _pancakeswapV2Router.WETH());

		onPancakeSwapRouterUpdated();
	}


	function onPancakeSwapRouterUpdated() internal virtual { }


	function isPancakeSwapPair(address addr) public view returns(bool) {
		return _pancakeswapV2Pair == addr;
	}


	// This function can also be used in case the fees of the contract need to be adjusted later on as the volume grows
	function setFees(uint8 liquidityFee, uint8 rewardFee, uint8 additionalSellFee) public onlyOwner {
		require(liquidityFee >= 1 && liquidityFee <= 8, "Liquidity fee must be between 1% and 8%");
		require(rewardFee >= 1 && rewardFee <= 15, "Reward fee must be between 1% and 15%");
		require(additionalSellFee <= 5, "Additional sell fee cannot exceed 5%");
		require(liquidityFee + rewardFee + additionalSellFee <= 25, "Total fees cannot exceed 25%");
		
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


	function setTokenSwapThreshold(uint256 threshold) public onlyOwner {
		require(threshold > 0, "Threshold must be greater than 0");
		_tokenSwapThreshold = threshold;
	}


	function name() public override pure returns (string memory) {
		return NAME;
	}


	function symbol() public override pure returns (string memory) {
		return SYMBOL;
	}


	function totalSupply() public override pure returns (uint256) {
		return _totalTokens;
	}
	

	function decimals() public override pure returns (uint8) {
		return DECIMALS;
	}
	

	function allowance(address user, address spender) public view override returns (uint256) {
		return _allowances[user][spender];
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
		return _totalTokens - balanceOf(address(0)) - balanceOf(BURN_WALLET) - balanceOf(_pancakeswapV2Pair);
	}


	
	function totalBNBLiquidityAddedFromFees() public view returns (uint256) {
		return _totalBNBLiquidityAddedFromFees;
	}


	function isSwapEnabled() public view returns (bool) {
		return _isSwapEnabled;
	}


	function setSwapEnabled(bool isEnabled) public onlyOwner {
		_isSwapEnabled = isEnabled;
	}


	function isFeeEnabled() public view returns (bool) {
		return _isFeeEnabled;
	}


	function setFeeEnabled(bool isEnabled) public onlyOwner {
		_isFeeEnabled = isEnabled;
	}


	function isExcludedFromFees(address addr) public view returns(bool) {
		return _addressesExcludedFromFees[addr];
	}


	function setExcludedFromFees(address addr, bool value) public onlyOwner {
		_addressesExcludedFromFees[addr] = value;
	}


	// Ensures that the contract is able to receive BNB
	receive() external payable {}
}