/// @notice SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import {console} from "forge-std/Test.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/contracts/libraries/PoolId.sol";
import {BaseHook} from "v4-periphery/BaseHook.sol";
import {Currency} from "@uniswap/v4-core/contracts/libraries/CurrencyLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BalanceDelta} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";
import {FullMath} from "@uniswap/v4-core/contracts/libraries/FullMath.sol";

struct Trigger {
    /// @notice unwind the hedge when the price of ETH starts to recover
    bool unwind;
    /// @notice fired, indicated if swap was initiated
    bool fired;
    /// @notice the pool primary currency 
    Currency currency0;
    /// @notice the pool second currency 
    Currency currency1;
    /// @notice When the price decreases beyond a certain this threshold, we initiate the swap
    uint256 minPriceLimit;
    /// @notice unwind price
    uint256 unwindPrice;
    /// @notice unwind amount
    uint256 unwindAmount;
    /// @notice max amount to swap
    uint256 maxAmountSwap;
    /// @notice owner
    address owner;
}

contract Hedge is BaseHook {
    using PoolId for IPoolManager.PoolKey;
    using SafeERC20 for IERC20;

    mapping(Currency => uint256[]) public orderedPriceByCurrency;   
    mapping(Currency => mapping(uint256 => Trigger[])) public triggersByCurrency;

    event NewCurrencyAdded(address sender, Currency currency);
    event NewPriceAdded(address sender, Currency currency, uint256 price);
    event NewUserAdded(address sender, Currency currency, uint256 price, address user);
    event NewTriggerAdded(address sender, Currency currency, uint256 price, address user, bytes32 trigger);

    /// @notice binarysearch method to find the index where I have to insert my new trigger
    function _findIndex(uint256[] memory prices, uint256 targetPrice) internal pure returns (uint256) {
        uint256 length = prices.length;
        // Handle the case when the array is empty or the target price is smaller than the first element
        if (length == 0 || targetPrice <= prices[0]) {
            return 0;
        }

        // Handle the case when the target price is greater than or equal to the last element
        if (targetPrice >= prices[length - 1]) {
            return length;
        }

        uint256 left = 0;
        uint256 right = length - 1;

        while (left <= right) {
            uint256 mid = (left + right) / 2;
            uint256 midPrice = prices[mid];

            if (midPrice == targetPrice) {
                return mid;
            } else if (midPrice < targetPrice) {
                left = mid + 1;
            } else {
                right = mid - 1;
            }
        }

        return left;
    }

    function _performHedge(
        IPoolManager.PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        Trigger[] memory triggers,
        uint256 currency0Price) internal {
        for (uint256 j = 0; j < triggers.length; j++) {
            Trigger memory trigger = triggers[j];
            if(trigger.fired){
                continue;
            }
            uint256 amount1 = abi.decode(
                poolManager.lock(
                    abi.encodeCall(this.lockAcquiredHedge, (key, params, trigger))
                ),
                (uint256)
            );
            trigger.fired = true; 
            trigger.currency1 = key.currency1;

            if(trigger.unwind){
                trigger.unwindPrice = currency0Price;
                trigger.unwindAmount = amount1;
            }
        }
    }

    function _performUnwind(
        IPoolManager.PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        Trigger[] memory triggers,
        uint256 currency0Price) internal {
        for (uint256 j = 0; j < triggers.length; j++) {
            Trigger memory trigger = triggers[j];
            if(!trigger.fired){
                continue;
            }
            if(currency0Price > trigger.unwindPrice && trigger.unwind){
                poolManager.lock(
                    abi.encodeCall(this.lockAcquiredUnwind, (key, params, trigger))
                );
            }
            trigger.fired = false;
            trigger.currency1 = Currency.wrap(address(0));
        }
    }

    function setTrigger(Currency _tokenAddress, uint256 _priceLimit, uint256 _maxAmountSwap, bool _unwind) external {
        Trigger memory trigger;
        trigger.unwind = _unwind;
        trigger.currency0 = _tokenAddress;
        trigger.minPriceLimit = _priceLimit;
        trigger.maxAmountSwap = _maxAmountSwap;
        trigger.owner = msg.sender;

        uint256[] storage prices = orderedPriceByCurrency[_tokenAddress];
        // Update the trigger arrays
        uint256 insertIndex = _findIndex(prices, _priceLimit);
        prices.push(0);

        // Shift prices to make space for the new price at the correct position
        for (uint256 i = prices.length - 1; i > insertIndex; i--) {
            prices[i] = prices[i - 1];
        }

        // Insert the new price at the correct position
        prices[insertIndex] = _priceLimit;

        triggersByCurrency[_tokenAddress][_priceLimit].push(trigger);
    }

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHooksCalls() public pure override returns (Hooks.Calls memory) {
        return Hooks.Calls({
            beforeInitialize: false,
            afterInitialize: false,
            beforeModifyPosition: false,
            afterModifyPosition: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false
        });
    }

    function afterSwap(
        address,
        IPoolManager.PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta
    ) external override poolManagerOnly returns (bytes4) {
        uint256[] memory prices = orderedPriceByCurrency[key.currency0];
        if(prices.length == 0) return Hedge.afterSwap.selector;

        uint256 numerator1 = uint256(params.sqrtPriceLimitX96) * uint256(params.sqrtPriceLimitX96);
        uint256 numerator2 = 10**18;
        uint256 currency0Price = FullMath.mulDiv(numerator1, numerator2, 1 << 192); 

        uint256 startIndex = _findIndex(prices, currency0Price);

        // Collect the triggers with prices greater than or equal to the target price
        for (uint256 i = 0; i < prices.length; i++) {
            Trigger[] memory triggers = triggersByCurrency[key.currency0][prices[i]];
            if(triggers.length != 0){
                // all prices greater or equal to currency0Price
                if(i >= startIndex){
                    _performHedge(key, params, triggers, currency0Price);
                }
                else {
                    _performUnwind(key, params, triggers, currency0Price);
                }
            }                
        }

        return Hedge.afterSwap.selector;
    }

    function lockAcquiredUnwind(IPoolManager.PoolKey calldata key, 
        IPoolManager.SwapParams calldata params, 
        Trigger memory trigger)
        external
        selfOnly
    {
        IERC20 token = IERC20(Currency.unwrap(trigger.currency1));
        uint256 balance = token.balanceOf(trigger.owner);
        if(balance >= trigger.unwindAmount){
            token.transferFrom(
                trigger.owner, address(poolManager), trigger.unwindAmount
            );
            poolManager.settle(trigger.currency1);
            BalanceDelta delta = poolManager.swap(key, params);
            
            uint256 token0Amount = uint256(uint128(delta.amount0()));
            poolManager.safeTransferFrom(
                address(this), address(poolManager), uint256(uint160(Currency.unwrap(trigger.currency0))), token0Amount, ""
            );
            poolManager.take(trigger.currency0, trigger.owner, token0Amount);
        }
    }

    function lockAcquiredHedge(IPoolManager.PoolKey calldata key, 
        IPoolManager.SwapParams calldata params,
        Trigger memory trigger)
        external
        selfOnly
        returns (uint256 token1Amount)
    {
        IERC20 token = IERC20(Currency.unwrap(trigger.currency0));
        uint256 balance = token.balanceOf(trigger.owner);
        if(balance >= trigger.maxAmountSwap){
            /// @notice TODO use safeTransferFrom
            token.transferFrom(
                trigger.owner, address(poolManager), trigger.maxAmountSwap
            );
            poolManager.settle(trigger.currency0);
            BalanceDelta delta = poolManager.swap(key, params);
            
            token1Amount = uint256(uint128(delta.amount1()));
            poolManager.safeTransferFrom(
                address(this), address(poolManager), uint256(uint160(Currency.unwrap(trigger.currency1))), token1Amount, ""
            );
            poolManager.take(trigger.currency1, trigger.owner, token1Amount);
        }
    }
}