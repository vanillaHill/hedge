// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import "forge-std/Test.sol";

import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {HookTest} from "./utils/HookTest.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/contracts/interfaces/IHooks.sol";
import {PoolManager} from "@uniswap/v4-core/contracts/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/contracts/libraries/PoolId.sol";
import {Deployers} from "@uniswap/v4-core/test/foundry-tests/utils/Deployers.sol";
import {Hedge, Trigger} from "../src/Hedge.sol";
import {HedgeImplementation} from "./implementation/HedgeImplementation.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/contracts/libraries/CurrencyLibrary.sol";
import {TestERC20} from "@uniswap/v4-core/contracts/test/TestERC20.sol";
import {PoolSwapTest} from "@uniswap/v4-core/contracts/test/PoolSwapTest.sol";

contract HedgeTest is HookTest, Deployers, GasSnapshot {
    Hedge hedge = Hedge(address(uint160(Hooks.AFTER_SWAP_FLAG)));

    uint160 constant SQRT_RATIO_10_1 = 250541448375047931186413801569;
    
    IPoolManager.PoolKey key;
    bytes32 id;

    uint256 internal mintAmount = 12e18;
    address internal alice = address(0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266);
    address internal thomas = address(0x14dC79964da2C08b23698B3D3cc7Ca32193d9955);

    function setUp() public {   
        // creates the pool manager, test tokens, and other utility routers
        HookTest.initHookTestEnv();
        vm.record();

        HedgeImplementation impl = new HedgeImplementation(manager, hedge);
        (, bytes32[] memory writes) = vm.accesses(address(impl));
        vm.etch(address(hedge), address(impl).code);
        // for each storage key that was written during the hook implementation, copy the value over
        unchecked {
            for (uint256 i = 0; i < writes.length; i++) {
                bytes32 slot = writes[i];
                vm.store(address(hedge), slot, vm.load(address(impl), slot));
            }
        }

        key = IPoolManager.PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), 3000, 60, hedge);
        id = PoolId.toId(key);
        manager.initialize(key, SQRT_RATIO_1_1);

        swapRouter = new PoolSwapTest(manager);

        token0.approve(address(hedge), type(uint256).max);
        token1.approve(address(hedge), type(uint256).max);
    }

    function test_setTrigger() public {
        vm.prank(alice);
        uint128 priceLimit = 513 * 10**16;
        uint128 maxAmount = 100 * 10**18;
        hedge.setTrigger(Currency.wrap(address(token0)), priceLimit, maxAmount, true);
        (,,Currency currency0,,uint256 minPriceLimit,,,uint256 maxAmountSwap,address owner) = hedge.triggersByCurrency(Currency.wrap(address(token0)), priceLimit, 0);
        assertEq(Currency.unwrap(currency0), address(token0));
        assertEq(owner, alice);
        assertEq(minPriceLimit, priceLimit);
        assertEq(maxAmountSwap, maxAmount);

        vm.prank(thomas);
        uint128 priceLimitThomas = 413 * 10**16;
        uint128 maxAmountThomas = 90 * 10**18;
        hedge.setTrigger(Currency.wrap(address(token1)), priceLimitThomas, maxAmountThomas, true);
        (,,currency0,,minPriceLimit,,,maxAmountSwap,owner) = hedge.triggersByCurrency(Currency.wrap(address(token0)), priceLimit, 0);
        assertEq(Currency.unwrap(currency0), address(token0));
        assertEq(owner, alice);
        assertEq(minPriceLimit, priceLimit);
        assertEq(maxAmountSwap, maxAmount);

        //
        (,,currency0,,minPriceLimit,,,maxAmountSwap,owner) = hedge.triggersByCurrency(Currency.wrap(address(token1)), priceLimitThomas, 0);
        assertEq(Currency.unwrap(currency0), address(token1));
        assertEq(owner, thomas);
        assertEq(minPriceLimit, priceLimitThomas);
        assertEq(maxAmountSwap, maxAmountThomas);
    }

    // function test_currency1IsSet() public {
    //     vm.prank(alice);
    //     uint128 priceLimit = 79466191966197645195421774833;
    //     uint128 maxAmount = 100 * 10^18;
    //     hedge.setTrigger(Currency.wrap(address(token0)), priceLimit, maxAmount, true);

    //     swapRouter.swap(
    //         key,
    //         IPoolManager.SwapParams(false, 1e18, TickMath.getSqrtRatioAtTick(60)),
    //         PoolSwapTest.TestSettings(true, true)
    //     );

    //     (, , Currency currency0, Currency currency1, , , , ) = hedge.triggerByUser(alice,Currency.wrap(address(token0)));
    //     assertEq(Currency.unwrap(currency0), address(token0));
    //     assertEq(Currency.unwrap(currency1), address(token1));
    // }
}