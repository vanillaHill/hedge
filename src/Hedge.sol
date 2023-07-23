// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import {console} from "forge-std/console.sol";
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
}

contract Hedge is BaseHook {
    using PoolId for IPoolManager.PoolKey;
    using SafeERC20 for IERC20;

    mapping(address => mapping(Currency => Trigger)) public triggerByUser;

    function setTrigger(Currency _tokenAddress, uint256 _priceLimit, uint256 _maxAmountSwap, bool _unwind) external {
        Trigger memory trigger;
        trigger.unwind = _unwind;
        trigger.minPriceLimit = _priceLimit;
        trigger.maxAmountSwap = _maxAmountSwap;
        trigger.currency0 = _tokenAddress;
        triggerByUser[msg.sender][_tokenAddress] = trigger;
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
        Trigger memory trigger = triggerByUser[msg.sender][key.currency0];
        if(Currency.unwrap(trigger.currency0) != Currency.unwrap(key.currency0)) return Hedge.afterSwap.selector;

        uint256 numerator1 = uint256(params.sqrtPriceLimitX96) * uint256(params.sqrtPriceLimitX96);
        uint256 numerator2 = 10**18;
        uint256 price = FullMath.mulDiv(numerator1, numerator2, 1 << 192);    

        if(price <= trigger.minPriceLimit && !trigger.fired){
            uint256 amount1 = abi.decode(
                poolManager.lock(
                    abi.encodeCall(this.lockAcquiredHedge, (key, params, trigger, msg.sender))
                ),
                (uint256)
            );
            trigger.fired = true; 
            trigger.currency1 = key.currency1;

            if(trigger.unwind){
                trigger.unwindPrice = price;
                trigger.unwindAmount = amount1;
            }
        }
        else {
            if(price > trigger.unwindPrice && trigger.unwind && trigger.fired){
                poolManager.lock(
                    abi.encodeCall(this.lockAcquiredUnwind, (key, params, trigger, msg.sender))
                );
            }
            trigger.fired = false;
            trigger.currency1 = Currency.wrap(address(0));
        } 

        return Hedge.afterSwap.selector;
    }

    function lockAcquiredUnwind(IPoolManager.PoolKey calldata key, 
        IPoolManager.SwapParams calldata params, 
        Trigger memory trigger, 
        address owner)
        external
        selfOnly
    {
        IERC20 token = IERC20(Currency.unwrap(trigger.currency1));
        uint256 balance = token.balanceOf(msg.sender);
        if(balance >= trigger.unwindAmount){
            token.transferFrom(
                owner, address(poolManager), trigger.unwindAmount
            );
            poolManager.settle(trigger.currency1);
            BalanceDelta delta = poolManager.swap(key, params);
            
            uint256 token0Amount = uint256(uint128(delta.amount0()));
            poolManager.safeTransferFrom(
                address(this), address(poolManager), uint256(uint160(Currency.unwrap(trigger.currency0))), token0Amount, ""
            );
            poolManager.take(trigger.currency0, owner, token0Amount);
        }
    }

    function lockAcquiredHedge(IPoolManager.PoolKey calldata key, 
        IPoolManager.SwapParams calldata params,
        Trigger memory trigger, 
        address owner)
        external
        selfOnly
        returns (uint256 token1Amount)
    {
        IERC20 token = IERC20(Currency.unwrap(trigger.currency0));
        uint256 balance = token.balanceOf(msg.sender);
        if(balance >= trigger.maxAmountSwap){
            // TODO use safeTransferFrom
            token.transferFrom(
                owner, address(poolManager), trigger.maxAmountSwap
            );
            poolManager.settle(trigger.currency0);
            BalanceDelta delta = poolManager.swap(key, params);
            
            token1Amount = uint256(uint128(delta.amount1()));
            poolManager.safeTransferFrom(
                address(this), address(poolManager), uint256(uint160(Currency.unwrap(trigger.currency1))), token1Amount, ""
            );
            poolManager.take(trigger.currency1, owner, token1Amount);
        }
    }
}