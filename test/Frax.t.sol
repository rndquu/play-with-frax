// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "frax-solidity/hardhat/contracts/ERC20/IERC20.sol";
import {FRAXShares} from "frax-solidity/hardhat/contracts/FXS/FXS.sol";
import {FRAXStablecoin} from "frax-solidity/hardhat/contracts/Frax/Frax.sol";
import {FraxPoolV3} from "frax-solidity/hardhat/contracts/Frax/pools/FraxPoolV3.sol";
import {AggregatorV3Interface} from "frax-solidity/hardhat/contracts/Oracle/AggregatorV3Interface.sol";

 /**
  * Contracts:
  * - FRAX token: https://etherscan.io/address/0x853d955aCEf822Db058eb8505911ED77F175b99e
  * - FXS token: https://etherscan.io/address/0x3432B6A60D23Ca0dFCa7761B7ab56459D9C964D0
  * - FraxPool USDC v2: https://etherscan.io/address/0x1864Ca3d47AaB98Ee78D11fc9DCC5E7bADdA1c0d
  * - FraxPool v3: https://etherscan.io/address/0x2fE065e6FFEf9ac95ab39E5042744d695F560729
  * - AMO minter: https://etherscan.io/address/0xcf37B62109b537fa0Cb9A90Af4CA72f6fb85E241 
  *
  * AMOs:
  * - Curve: https://etherscan.io/address/0x49ee75278820f409ecd67063D8D717B38d66bd71
  * - FraxLend: https://etherscan.io/address/0xf6E697e95D4008f81044337A749ECF4d15C30Ea6
  * - Fraxswap TWAMM: https://etherscan.io/address/0x629C473e0E698FD101496E5fbDA4bcB58DA78dC4
  *
  * Misc:
  * - LUSD: https://etherscan.io/address/0x5f98805A4E8be255a32880FDeC7F6728C6568bA0
  * - USDC: https://etherscan.io/token/0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48
  * - DAI: https://etherscan.io/token/0x6B175474E89094C44Da98b954EedeAC495271d0F
  */

contract FraxTest is Test {
    FraxPoolV3 fraxPoolV3;
    FRAXStablecoin fraxToken = FRAXStablecoin(0x853d955aCEf822Db058eb8505911ED77F175b99e);
    FRAXShares fxsToken = FRAXShares(0x3432B6A60D23Ca0dFCa7761B7ab56459D9C964D0);
    IERC20 lusdToken = IERC20(0x5f98805A4E8be255a32880FDeC7F6728C6568bA0);

    address user = address(1000);
    address fraxOwner = 0xB1748C79709f4Ba2Dd82834B8c82D4a505003f27;

    function setUp() public {
        // fork mainnet
        vm.createSelectFork('https://mainnet.gateway.tenderly.co');

        // add 1000 LUSD to user
        deal(address(lusdToken), user, 1000e18);

        // add 1000 FXS to user
        deal(address(fxsToken), user, 1000e18);

        // add 1000 FRAX to user
        deal(address(fraxToken), user, 1000e18);

        // deploy a new Frax pool with LUSD collateral
        address[] memory collateralAddresses = new address[](1);
        collateralAddresses[0] = address(lusdToken);

        uint[] memory poolCeilings = new uint[](1);
        poolCeilings[0] = 50000e18;

        uint[] memory initialFees = new uint[](4);
        initialFees[0] = 3000; // mint fee, 0.3%
        initialFees[1] = 4500; // redeem fee, 0.45%
        initialFees[2] = 3000; // buy back fee, 0.3%
        initialFees[3] = 0; // recollateralize fee, 0%

        fraxPoolV3 = new FraxPoolV3(
            user, // pool manager address (owner)
            user, // custodian address (responsible for pausing)
            user, // timelock address (multisig governance)
            collateralAddresses, // collateral tokens
            poolCeilings, // array of max values for each collateral to be accepted
            initialFees // initial fees
        );

        // enable LUSD collateral
        vm.prank(user);
        fraxPoolV3.toggleCollateral(0);

        // UNSAFE: disable flash loan protection (for testing purposes)
        vm.prank(user);
        fraxPoolV3.setPoolParameters(
            0, // bonus rate (no changes)
            0 // number of redemption delay blocks (updated to 0 from 2)
        );

        // add pool to FRAX token
        vm.prank(fraxOwner);
        fraxToken.addPool(address(fraxPoolV3));

        // disable votes tracking to FXS (need to mint/redeem FXS with no hassle)
        vm.prank(fraxOwner);
        fxsToken.toggleVotes();

        // user approves frax pool to spend collateral tokens
        vm.prank(user);
        lusdToken.approve(address(fraxPoolV3), type(uint256).max);

        // user approves frax pool to spend FXS tokens
        vm.prank(user);
        fxsToken.approve(address(fraxPoolV3), type(uint256).max);

        // user approves frax pool to spend FRAX tokens
        vm.prank(user);
        fraxToken.approve(address(fraxPoolV3), type(uint256).max);
    }

    /**
     * Operation: mint
     * Prerequisites: CR:1, FRAX/USD:1.01, LUSD/USD:1.00, FXS/USD:6.00
     * Input: LUSD:100, FXS:0
     * Output: FRAX:99.7(0.3 fee)
     */
    function testMintScenario1() public {
        vm.startPrank(user);

        // FRAX/USD
        vm.mockCall(
            address(fraxPoolV3.priceFeedFRAXUSD()),
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(
                uint80(1), // round id
                int256(101_000_000), // price
                uint256(1), // started at
                uint256(1), // updated at
                uint80(1)  // answeredInRound id
            )
        );

        // FXS/USD
        vm.mockCall(
            address(fraxPoolV3.priceFeedFXSUSD()),
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(
                uint80(1), // round id
                int256(600_000_000), // price
                uint256(1), // started at
                uint256(1), // updated at
                uint80(1)  // answeredInRound id
            )
        );

        // FRAX collateral ratio
        vm.mockCall(
            address(fraxToken),
            abi.encodeWithSelector(fraxToken.global_collateral_ratio.selector),
            abi.encode(uint256(1_000_000))
        );

        debug();

        fraxPoolV3.mintFrax(
            0, // LUSD index in collateral
            100e18, // amount of FRAX to mint
            90e18, // min amount of FRAX to mint (slippage protection)
            100e18, // max amount of incoming LUSD (slippage protection)
            0, // max amount of incoming FXS (slippage protection)
            true // is 1-to-1 swap
        );

        debug();

        vm.stopPrank();
    }

    /**
     * Operation: mint
     * Prerequisites: CR:1.1, FRAX/USD:1.01, LUSD/USD:1.00, FXS/USD:6.00
     * Input: LUSD:100, FXS:0
     * Output: FRAX:99.7(0.3 fee)
     */
    function testMintScenario2() public {
        vm.startPrank(user);

        // FRAX/USD
        vm.mockCall(
            address(fraxPoolV3.priceFeedFRAXUSD()),
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(
                uint80(1), // round id
                int256(101_000_000), // price
                uint256(1), // started at
                uint256(1), // updated at
                uint80(1)  // answeredInRound id
            )
        );

        // FXS/USD
        vm.mockCall(
            address(fraxPoolV3.priceFeedFXSUSD()),
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(
                uint80(1), // round id
                int256(600_000_000), // price
                uint256(1), // started at
                uint256(1), // updated at
                uint80(1)  // answeredInRound id
            )
        );

        // FRAX collateral ratio
        vm.mockCall(
            address(fraxToken),
            abi.encodeWithSelector(fraxToken.global_collateral_ratio.selector),
            abi.encode(uint256(1_100_000))
        );

        debug();

        fraxPoolV3.mintFrax(
            0, // LUSD index in collateral
            100e18, // amount of FRAX to mint
            90e18, // min amount of FRAX to mint (slippage protection)
            100e18, // max amount of incoming LUSD (slippage protection)
            0, // max amount of incoming FXS (slippage protection)
            true // is 1-to-1 swap
        );

        debug();

        vm.stopPrank();
    }

    /**
     * Operation: mint
     * Prerequisites: CR:0.9, FRAX/USD:1.01, LUSD/USD:1.00, FXS/USD:6.00
     * Input: LUSD:90, FXS: 1.66 (~10 USD)
     * Output: FRAX:99.7(0.3 fee)
     */
    function testMintScenario3() public {
        vm.startPrank(user);

        // FRAX/USD
        vm.mockCall(
            address(fraxPoolV3.priceFeedFRAXUSD()),
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(
                uint80(1), // round id
                int256(101_000_000), // price
                uint256(1), // started at
                uint256(1), // updated at
                uint80(1)  // answeredInRound id
            )
        );

        // FXS/USD
        vm.mockCall(
            address(fraxPoolV3.priceFeedFXSUSD()),
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(
                uint80(1), // round id
                int256(600_000_000), // price
                uint256(1), // started at
                uint256(1), // updated at
                uint80(1)  // answeredInRound id
            )
        );

        // FRAX collateral ratio
        vm.mockCall(
            address(fraxToken),
            abi.encodeWithSelector(fraxToken.global_collateral_ratio.selector),
            abi.encode(uint256(900_000))
        );

        debug();

        fraxPoolV3.mintFrax(
            0, // LUSD index in collateral
            100e18, // amount of FRAX to mint
            0, // min amount of FRAX to mint (slippage protection)
            100e18, // max amount of incoming LUSD (slippage protection)
            100e18, // max amount of incoming FXS (slippage protection)
            false // is 1-to-1 swap
        );

        debug();

        vm.stopPrank();
    }

    /**
     * Operation: mint
     * Prerequisites: CR:1, FRAX/USD:1.01, LUSD/USD:1.10, FXS/USD:6.00
     * Input: LUSD:90.9, FXS:0
     * Output: FRAX:99.7(0.3 fee)
     */
    function testMintScenario4() public {
        vm.startPrank(user);

        // FRAX/USD
        vm.mockCall(
            address(fraxPoolV3.priceFeedFRAXUSD()),
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(
                uint80(1), // round id
                int256(101_000_000), // price
                uint256(1), // started at
                uint256(1), // updated at
                uint80(1)  // answeredInRound id
            )
        );

        // FXS/USD
        vm.mockCall(
            address(fraxPoolV3.priceFeedFXSUSD()),
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(
                uint80(1), // round id
                int256(600_000_000), // price
                uint256(1), // started at
                uint256(1), // updated at
                uint80(1)  // answeredInRound id
            )
        );

        // LUSD/USD
        fraxPoolV3.setCollateralPrice(0, 1_100_000);

        // FRAX collateral ratio
        vm.mockCall(
            address(fraxToken),
            abi.encodeWithSelector(fraxToken.global_collateral_ratio.selector),
            abi.encode(uint256(1_000_000))
        );

        debug();

        fraxPoolV3.mintFrax(
            0, // LUSD index in collateral
            100e18, // amount of FRAX to mint
            90e18, // min amount of FRAX to mint (slippage protection)
            100e18, // max amount of incoming LUSD (slippage protection)
            0, // max amount of incoming FXS (slippage protection)
            true // is 1-to-1 swap
        );

        debug();

        vm.stopPrank();
    }

    /**
     * Operation: mint
     * Prerequisites: CR:0.9, FRAX/USD:1.01, LUSD/USD:1.10, FXS/USD:6.00
     * Input: LUSD: 81.8, FXS: 1.66
     * Output: FRAX:99.7(0.3 fee)
     */
    function testMintScenario5() public {
        vm.startPrank(user);

        // FRAX/USD
        vm.mockCall(
            address(fraxPoolV3.priceFeedFRAXUSD()),
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(
                uint80(1), // round id
                int256(101_000_000), // price
                uint256(1), // started at
                uint256(1), // updated at
                uint80(1)  // answeredInRound id
            )
        );

        // FXS/USD
        vm.mockCall(
            address(fraxPoolV3.priceFeedFXSUSD()),
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(
                uint80(1), // round id
                int256(600_000_000), // price
                uint256(1), // started at
                uint256(1), // updated at
                uint80(1)  // answeredInRound id
            )
        );

        // LUSD/USD
        fraxPoolV3.setCollateralPrice(0, 1_100_000);

        // FRAX collateral ratio
        vm.mockCall(
            address(fraxToken),
            abi.encodeWithSelector(fraxToken.global_collateral_ratio.selector),
            abi.encode(uint256(900_000))
        );

        debug();

        fraxPoolV3.mintFrax(
            0, // LUSD index in collateral
            100e18, // amount of FRAX to mint
            0, // min amount of FRAX to mint (slippage protection)
            100e18, // max amount of incoming LUSD (slippage protection)
            100e18, // max amount of incoming FXS (slippage protection)
            false // is 1-to-1 swap
        );

        debug();

        vm.stopPrank();
    }

    /**
     * Operation: mint
     * Prerequisites: CR:1, FRAX/USD:1.01, LUSD/USD:0.90, FXS/USD:6.00
     * Input: LUSD:111.11, FXS:0
     * Output: FRAX:99.7(0.3 fee)
     */
    function testMintScenario6() public {
        vm.startPrank(user);

        // FRAX/USD
        vm.mockCall(
            address(fraxPoolV3.priceFeedFRAXUSD()),
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(
                uint80(1), // round id
                int256(101_000_000), // price
                uint256(1), // started at
                uint256(1), // updated at
                uint80(1)  // answeredInRound id
            )
        );

        // FXS/USD
        vm.mockCall(
            address(fraxPoolV3.priceFeedFXSUSD()),
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(
                uint80(1), // round id
                int256(600_000_000), // price
                uint256(1), // started at
                uint256(1), // updated at
                uint80(1)  // answeredInRound id
            )
        );

        // LUSD/USD
        fraxPoolV3.setCollateralPrice(0, 900_000);

        // FRAX collateral ratio
        vm.mockCall(
            address(fraxToken),
            abi.encodeWithSelector(fraxToken.global_collateral_ratio.selector),
            abi.encode(uint256(1_000_000))
        );

        debug();

        fraxPoolV3.mintFrax(
            0, // LUSD index in collateral
            100e18, // amount of FRAX to mint
            90e18, // min amount of FRAX to mint (slippage protection)
            200e18, // max amount of incoming LUSD (slippage protection)
            0, // max amount of incoming FXS (slippage protection)
            true // is 1-to-1 swap
        );

        debug();

        vm.stopPrank();
    }

    /**
     * Operation: mint
     * Prerequisites: CR:0.9, FRAX/USD:1.01, LUSD/USD:0.90, FXS/USD:6.00
     * Input: LUSD:100, FXS:1.66
     * Output: FRAX:99.7(0.3 fee)
     */
    function testMintScenario7() public {
        vm.startPrank(user);

        // FRAX/USD
        vm.mockCall(
            address(fraxPoolV3.priceFeedFRAXUSD()),
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(
                uint80(1), // round id
                int256(101_000_000), // price
                uint256(1), // started at
                uint256(1), // updated at
                uint80(1)  // answeredInRound id
            )
        );

        // FXS/USD
        vm.mockCall(
            address(fraxPoolV3.priceFeedFXSUSD()),
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(
                uint80(1), // round id
                int256(600_000_000), // price
                uint256(1), // started at
                uint256(1), // updated at
                uint80(1)  // answeredInRound id
            )
        );

        // LUSD/USD
        fraxPoolV3.setCollateralPrice(0, 900_000);

        // FRAX collateral ratio
        vm.mockCall(
            address(fraxToken),
            abi.encodeWithSelector(fraxToken.global_collateral_ratio.selector),
            abi.encode(uint256(900_000))
        );

        debug();

        fraxPoolV3.mintFrax(
            0, // LUSD index in collateral
            100e18, // amount of FRAX to mint
            0, // min amount of FRAX to mint (slippage protection)
            100e18, // max amount of incoming LUSD (slippage protection)
            100e18, // max amount of incoming FXS (slippage protection)
            false // is 1-to-1 swap
        );

        debug();

        vm.stopPrank();
    }

    /**
     * Operation: redeem
     * Prerequisites: CR:1, FRAX/USD:0.99, LUSD/USD:1.00, FXS/USD:6.00
     * Input: FRAX:100
     * Output: LUSD:99.55(0.45 redemption fee), FXS:0
     */
    function testRedeemScenario1() public {
        vm.startPrank(user);

        // FRAX/USD
        vm.mockCall(
            address(fraxPoolV3.priceFeedFRAXUSD()),
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(
                uint80(1), // round id
                int256(990_000), // price
                uint256(1), // started at
                uint256(1), // updated at
                uint80(1)  // answeredInRound id
            )
        );

        // FXS/USD
        vm.mockCall(
            address(fraxPoolV3.priceFeedFXSUSD()),
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(
                uint80(1), // round id
                int256(600_000_000), // price
                uint256(1), // started at
                uint256(1), // updated at
                uint80(1)  // answeredInRound id
            )
        );

        // FRAX collateral ratio
        vm.mockCall(
            address(fraxToken),
            abi.encodeWithSelector(fraxToken.global_collateral_ratio.selector),
            abi.encode(uint256(1_000_000))
        );

        debug();

        // add 1000 LUSD to the pool
        deal(address(lusdToken), address(fraxPoolV3), 1000e18);

        fraxPoolV3.redeemFrax(
            0, // collateral index
            100e18, // FRAX amount to redeem
            0, // min FXS out (slippage protection)
            0 // min collateral our (slippage protection)
        );

        fraxPoolV3.collectRedemption(0);

        debug();

        vm.stopPrank();
    }

    /**
     * Operation: redeem
     * Prerequisites: CR:0.9, FRAX/USD:0.99, LUSD/USD:1.00, FXS/USD:6.00
     * Input: FRAX:100
     * Output: LUSD:89.59, FXS:~1.65
     */
    function testRedeemScenario2() public {
        vm.startPrank(user);

        // FRAX/USD
        vm.mockCall(
            address(fraxPoolV3.priceFeedFRAXUSD()),
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(
                uint80(1), // round id
                int256(990_000), // price
                uint256(1), // started at
                uint256(1), // updated at
                uint80(1)  // answeredInRound id
            )
        );

        // FXS/USD
        vm.mockCall(
            address(fraxPoolV3.priceFeedFXSUSD()),
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(
                uint80(1), // round id
                int256(600_000_000), // price
                uint256(1), // started at
                uint256(1), // updated at
                uint80(1)  // answeredInRound id
            )
        );

        // FRAX collateral ratio
        vm.mockCall(
            address(fraxToken),
            abi.encodeWithSelector(fraxToken.global_collateral_ratio.selector),
            abi.encode(uint256(900_000))
        );

        debug();

        // add 1000 LUSD to the pool
        deal(address(lusdToken), address(fraxPoolV3), 1000e18);

        fraxPoolV3.redeemFrax(
            0, // collateral index
            100e18, // FRAX amount to redeem
            0, // min FXS out (slippage protection)
            0 // min collateral our (slippage protection)
        );

        fraxPoolV3.collectRedemption(0);

        debug();

        vm.stopPrank();
    }

    /**
     * Scenario:
     * 1. LUSD/USD: 1.00
     * 2. User mints 100 FRAX (pool has 100 LUSD as collateral)
     * 3. LUSD/USD: 0.90
     * 4. User redeems 100 FRAX and tx reverts with "Insufficient pool collateral" because we need to 
     * transfer 109.5 LUSD collateral while the pool only has 100 LUSD 
     */
    function testRedeem_ShouldRevert_OnBadDebt() public {
        vm.startPrank(user);

        // FRAX/USD
        vm.mockCall(
            address(fraxPoolV3.priceFeedFRAXUSD()),
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(
                uint80(1), // round id
                int256(101_000_000), // price
                uint256(1), // started at
                uint256(1), // updated at
                uint80(1)  // answeredInRound id
            )
        );

        // FXS/USD
        vm.mockCall(
            address(fraxPoolV3.priceFeedFXSUSD()),
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(
                uint80(1), // round id
                int256(600_000_000), // price
                uint256(1), // started at
                uint256(1), // updated at
                uint80(1)  // answeredInRound id
            )
        );

        // FRAX collateral ratio
        vm.mockCall(
            address(fraxToken),
            abi.encodeWithSelector(fraxToken.global_collateral_ratio.selector),
            abi.encode(uint256(1_000_000))
        );

        debug();

        fraxPoolV3.mintFrax(
            0, // LUSD index in collateral
            100e18, // amount of FRAX to mint
            0, // min amount of FRAX to mint (slippage protection)
            100e18, // max amount of incoming LUSD (slippage protection)
            100e18, // max amount of incoming FXS (slippage protection)
            true // is 1-to-1 swap
        );

        debug();

        // FRAX price goes down from 1.01 to 0.99
        vm.mockCall(
            address(fraxPoolV3.priceFeedFRAXUSD()),
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(
                uint80(1), // round id
                int256(990_000), // price
                uint256(1), // started at
                uint256(1), // updated at
                uint80(1)  // answeredInRound id
            )
        );

        // LUSD/USD goes down from 1.00 to 0.90
        fraxPoolV3.setCollateralPrice(0, 900_000);

        // user redeems 99 FRAX
        vm.expectRevert('Insufficient pool collateral');
        fraxPoolV3.redeemFrax(
            0, // collateral index
            99e18, // FRAX amount to redeem
            0, // min FXS out (slippage protection)
            0 // min collateral our (slippage protection)
        );

        debug();

        vm.stopPrank();
    }

    function debug() public {
        console.log('===debug===');
        console.log('Balance (LUSD):', lusdToken.balanceOf(user));
        console.log('Balance (FRAX):', fraxToken.balanceOf(user));
        console.log('Balance (FXS):', fxsToken.balanceOf(user));
        console.log('FraxPoolV3.getFRAXPrice():', fraxPoolV3.getFRAXPrice());
        console.log('FraxPoolV3.getFXSPrice():', fraxPoolV3.getFXSPrice());
        console.log('FRAX.global_collateral_ratio():', fraxToken.global_collateral_ratio());
        console.log('LUSD price:', fraxPoolV3.collateral_prices(0));
    }
}
