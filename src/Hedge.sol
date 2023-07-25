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
    /// @notice/ @notice needed to delete a "Trigger"
    uint triggerListPointer; 
    /// @notice trigger has exactly one "User"
    address user; 

    /// @notice/ @notice unwind the hedge when the price of ETH starts to recover
    bool unwind;
    /// @notice/ @notice fired, indicated if swap was initiated
    bool fired;
    /// @notice/ @notice the pool primary currency 
    Currency currency0;
    /// @notice/ @notice the pool second currency 
    Currency currency1;
    /// @notice/ @notice When the price decreases beyond a certain this threshold, we initiate the swap
    uint256 minPriceLimit;
    /// @notice/ @notice unwind price
    uint256 unwindPrice;
    /// @notice/ @notice unwind amount
    uint256 unwindAmount;
    /// @notice/ @notice max amount to swap
    uint256 maxAmountSwap;
}

struct CurrencyItem {
    /// @notice needed to delete a "Currency"
    uint currencyListPointer; 
    /// @notice Currency has many "Price"
    uint256[] prices; 
    mapping(uint256 => uint) pricePointers;  
}

struct PriceItem {
    /// @notice needed to delete a "Price"
    uint priceListPointer; 
    /// @notice price has exactly one "Currency"
    Currency currency; 
    /// @notice price has many "User"
    address[] users; 
    mapping(address => uint) userPointers;  
}

struct UserItem {
    /// @notice needed to delete a "User"
    uint userListPointer; 
    /// @notice user has exactly one "price"
    uint256 price; 
    /// @notice user has many "Trigger"
    bytes32[] triggers; 
    mapping(bytes32 => uint) triggerPointers;  
}

contract Hedge is BaseHook {
    using PoolId for IPoolManager.PoolKey;
    using SafeERC20 for IERC20;

    mapping(Currency => CurrencyItem) public currencyCollections;
    Currency[] public currencyList;
    mapping(uint256 => PriceItem) public priceCollections;
    uint256[] public priceList;
    mapping(address => UserItem) public userCollections;
    address[] public userList;
    mapping(bytes32 => Trigger) public triggerCollections;
    bytes32[] public triggerList;

    event NewCurrencyAdded(address sender, Currency currency);
    event NewPriceAdded(address sender, Currency currency, uint256 price);
    event NewUserAdded(address sender, Currency currency, uint256 price, address user);
    event NewTriggerAdded(address sender, Currency currency, uint256 price, address user, bytes32 trigger);

    function isCurrencyExists(Currency currencyAddress) public returns(bool isIndeed) {
        if(currencyList.length == 0) return false;
        return Currency.unwrap(currencyList[currencyCollections[currencyAddress].currencyListPointer]) == Currency.unwrap(currencyAddress);
    }
    
    function isPriceExists(uint256 price) public returns(bool isIndeed) {
        if(priceList.length == 0) return false;
        return priceList[priceCollections[price].priceListPointer] == price;
    }
    
    function isUserExists(address user) public returns(bool isIndeed) {
        if(userList.length == 0) return false;
        return userList[userCollections[user].userListPointer] == user;
    }
    
    function isTriggerExists(bytes32 trigger) public returns(bool isIndeed) {
        if(triggerList.length == 0) return false;
        return triggerList[triggerCollections[trigger].triggerListPointer] == trigger;
    }

    function setTrigger(Currency _tokenAddress, uint256 _priceLimit, uint256 _maxAmountSwap, bool _unwind) external {
        if(!isCurrencyExists(_tokenAddress)){
            currencyCollections[_tokenAddress].currencyListPointer = currencyList.push(_tokenAddress)-1;
            NewCurrencyAdded(msg.sender, _tokenAddress);
        }
        if(!isPriceExists(_priceLimit)){
            priceCollections[_priceLimit].priceListPointer = priceList.push(_priceLimit)-1;
            priceCollections[_priceLimit].currency = _tokenAddress;
            currencyCollections[_tokenAddress].pricePointers[_priceLimit] = currencyCollections[_tokenAddress].prices.push(_priceLimit)-1;
            NewPriceAdded(msg.sender, _tokenAddress, _priceLimit);
        }
        if(!isUserExists(msg.sender)){
            userCollections[msg.sender].userListPointer = userList.push(msg.sender)-1;
            userCollections[msg.sender].price = _priceLimit;
            currencyCollections[_tokenAddress].pricePointers[_priceLimit].userPointers[msg.sender] = currencyCollections[_tokenAddress].pricePointers[_priceLimit].users.push(msg.sender)-1;
            NewUserAdded(msg.sender, _tokenAddress, _priceLimit, msg.sender);
        }
        if(!isTriggerExists(keccak256(abi.encodePacked(_tokenAddress, _priceLimit, msg.sender)))){
            bytes32 triggerKey = keccak256(abi.encodePacked(_tokenAddress, _priceLimit, msg.sender));
            triggerCollections[triggerKey].triggerListPointer = triggerList.push(triggerKey)-1;
            triggerCollections[triggerKey].user = msg.sender;
            triggerCollections[triggerKey].unwind = _unwind;
            triggerCollections[triggerKey].minPriceLimit = _priceLimit;
            triggerCollections[triggerKey].maxAmountSwap = _maxAmountSwap;
            triggerCollections[triggerKey].currency0 = _tokenAddress;
            currencyCollections[_tokenAddress].pricePointers[_priceLimit].userPointers[msg.sender].triggerPointers[triggerKey] = currencyCollections[_tokenAddress].pricePointers[_priceLimit].userPointers[msg.sender].triggers.push(triggerKey)-1;
            NewTriggerAdded(msg.sender, _tokenAddress, _priceLimit, msg.sender, triggerKey);
        }
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
        // Trigger memory trigger = triggerByCurrency[msg.sender][key.currency0];
        // console.log(Currency.unwrap(trigger.currency0), ">>>>");
        // console.log(Currency.unwrap(key.currency0), "<<<<");
        // if(Currency.unwrap(trigger.currency0) != Currency.unwrap(key.currency0)) return Hedge.afterSwap.selector;

        // uint256 numerator1 = uint256(params.sqrtPriceLimitX96) * uint256(params.sqrtPriceLimitX96);
        // uint256 numerator2 = 10**18;
        // uint256 price = FullMath.mulDiv(numerator1, numerator2, 1 << 192); 

        // if(price <= trigger.minPriceLimit && !trigger.fired){
        //     uint256 amount1 = abi.decode(
        //         poolManager.lock(
        //             abi.encodeCall(this.lockAcquiredHedge, (key, params, trigger, msg.sender))
        //         ),
        //         (uint256)
        //     );
        //     trigger.fired = true; 
        //     trigger.currency1 = key.currency1;

        //     if(trigger.unwind){
        //         trigger.unwindPrice = price;
        //         trigger.unwindAmount = amount1;
        //     }
        // }
        // else {
        //     if(price > trigger.unwindPrice && trigger.unwind && trigger.fired){
        //         poolManager.lock(
        //             abi.encodeCall(this.lockAcquiredUnwind, (key, params, trigger, msg.sender))
        //         );
        //     }
        //     trigger.fired = false;
        //     trigger.currency1 = Currency.wrap(address(0));
        // } 

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
            /// @notice TODO use safeTransferFrom
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