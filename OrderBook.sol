// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// ====== 內建庫和接口 ======
import "./Libraries.sol";

// 對照真實合約: 0x09f77E8A13De9a35a7231028187e9fD5DB8a2ACB
contract OrderBook is ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using Address for address payable;

    // ====== 狀態變量 ======
    address public gov;
    address public router;
    address public vault;
    address public weth;
    
    mapping(address => mapping(uint256 => IncreaseOrder)) public increaseOrders;
    mapping(address => mapping(uint256 => DecreaseOrder)) public decreaseOrders;
    mapping(address => uint256) public increaseOrdersIndex;
    mapping(address => uint256) public decreaseOrdersIndex;
    
    uint256 public minExecutionFee = 0.001 ether;

    // ====== 訂單結構 ======
    struct IncreaseOrder {
        address account;
        address purchaseToken;
        uint256 purchaseTokenAmount;
        address collateralToken;
        address indexToken;
        uint256 sizeDelta;
        bool isLong;
        uint256 triggerPrice;
        bool triggerAboveThreshold;
        uint256 executionFee;
    }

    struct DecreaseOrder {
        address account;
        address collateralToken;
        uint256 collateralDelta;
        address indexToken;
        uint256 sizeDelta;
        bool isLong;
        uint256 triggerPrice;
        bool triggerAboveThreshold;
        uint256 executionFee;
    }

    // ====== 事件 ======
    event CreateDecreaseOrder(
        address indexed account,
        uint256 orderIndex,
        address collateralToken,
        uint256 collateralDelta,
        address indexToken,
        uint256 sizeDelta,
        bool isLong,
        uint256 triggerPrice,
        bool triggerAboveThreshold,
        uint256 executionFee
    );

    event ExecuteDecreaseOrder(
        address indexed account,
        uint256 orderIndex,
        address collateralToken,
        uint256 collateralDelta,
        address indexToken,
        uint256 sizeDelta,
        bool isLong,
        uint256 triggerPrice,
        bool triggerAboveThreshold,
        uint256 executionFee,
        uint256 amountOut
    );

    modifier onlyGov() {
        require(msg.sender == gov, "OrderBook: forbidden");
        _;
    }

    constructor(
        address _router,
        address _vault,
        address _weth
    ) {
        gov = msg.sender;
        router = _router;
        vault = _vault;
        weth = _weth;
    }

    // ====== 創建訂單 ======
    
    function createDecreaseOrder(
        address _indexToken,
        uint256 _sizeDelta,
        address _collateralToken,
        uint256 _collateralDelta,
        bool _isLong,
        uint256 _triggerPrice,
        bool _triggerAboveThreshold
    ) external payable nonReentrant {
        require(msg.value >= minExecutionFee, "OrderBook: insufficient execution fee");

        uint256 _orderIndex = decreaseOrdersIndex[msg.sender];
        DecreaseOrder memory order = DecreaseOrder(
            msg.sender,
            _collateralToken,
            _collateralDelta,
            _indexToken,
            _sizeDelta,
            _isLong,
            _triggerPrice,
            _triggerAboveThreshold,
            msg.value
        );

        decreaseOrdersIndex[msg.sender] = _orderIndex.add(1);
        decreaseOrders[msg.sender][_orderIndex] = order;

        emit CreateDecreaseOrder(
            msg.sender,
            _orderIndex,
            _collateralToken,
            _collateralDelta,
            _indexToken,
            _sizeDelta,
            _isLong,
            _triggerPrice,
            _triggerAboveThreshold,
            msg.value
        );
    }

    // 🚨 關鍵漏洞函數 - executeDecreaseOrder
    // 對照: 真實OrderBook合約第874行
    function executeDecreaseOrder(
        address _address, 
        uint256 _orderIndex, 
        address payable _feeReceiver
    ) external nonReentrant {  // ❌ 只保護當前合約，無法防止跨合約重入
        DecreaseOrder memory order = decreaseOrders[_address][_orderIndex];
        require(order.account != address(0), "OrderBook: non-existent order");

        // 刪除訂單
        delete decreaseOrders[_address][_orderIndex];

        // 調用Router來執行減倉
        uint256 amountOut = IRouter(router).pluginDecreasePosition(
            order.account,
            order.collateralToken,
            order.indexToken,
            order.collateralDelta,
            order.sizeDelta,
            order.isLong,
            address(this)  // 資金先回到OrderBook
        );

        // 🚨 漏洞核心：將釋放的抵押品轉給用戶
        // 如果order.account是惡意合約，這裡會觸發重入攻擊
        if (order.collateralToken == weth) {
            _transferOutETH(amountOut, payable(order.account));  // 🚨 重入觸發點
        } else {
            // 🔧 FIX: 使用 call 代替 transfer，传递足够的 Gas
            // 在真实情况下这里会转 ERC20 代币，但为了测试攻击，我们发送 ETH
            if (amountOut > 0 && address(this).balance >= amountOut) {
                // 🚨 使用 call 来传递足够的 Gas 给重入攻击
                (bool success, ) = payable(order.account).call{value: amountOut, gas: 5000000}("");
                require(success, "Transfer failed");
            }
        }

        // 支付執行費用給keeper
        _transferOutETH(order.executionFee, _feeReceiver);

        emit ExecuteDecreaseOrder(
            order.account,
            _orderIndex,
            order.collateralToken,
            order.collateralDelta,
            order.indexToken,
            order.sizeDelta,
            order.isLong,
            order.triggerPrice,
            order.triggerAboveThreshold,
            order.executionFee,
            amountOut
        );
    }

    // 🚨 危险的ETH转賬函數
    // 這個函數會觸發接收者合約的fallback/receive函數
    function _transferOutETH(uint256 _amountOut, address payable _receiver) private {
        // 🔧 FIX: 简化转账逻辑，直接发送 ETH
        if (_amountOut > 0 && address(this).balance >= _amountOut) {
            // 🚨 这行代码触发重入攻击
            // 如果_receiver是恶意合约，会执行攻击者的代码
            _receiver.sendValue(_amountOut);
        }
    }

    function _transferInETH() private {
        if (msg.value != 0) {
            IWETH(weth).deposit{value: msg.value}();
        }
    }

    // ====== 取消訂單 ======
    
    function cancelDecreaseOrder(uint256 _orderIndex) external nonReentrant {
        DecreaseOrder memory order = decreaseOrders[msg.sender][_orderIndex];
        require(order.account != address(0), "OrderBook: non-existent order");
        require(order.account == msg.sender, "OrderBook: forbidden");

        delete decreaseOrders[msg.sender][_orderIndex];
        _transferOutETH(order.executionFee, payable(msg.sender));
    }

    // ====== 查詢函數 ======
    
    function getDecreaseOrder(address _account, uint256 _orderIndex)
        public
        view
        returns (
            address collateralToken,
            uint256 collateralDelta,
            address indexToken,
            uint256 sizeDelta,
            bool isLong,
            uint256 triggerPrice,
            bool triggerAboveThreshold,
            uint256 executionFee
        )
    {
        DecreaseOrder memory order = decreaseOrders[_account][_orderIndex];
        return (
            order.collateralToken,
            order.collateralDelta,
            order.indexToken,
            order.sizeDelta,
            order.isLong,
            order.triggerPrice,
            order.triggerAboveThreshold,
            order.executionFee
        );
    }

    // ====== 管理函數 ======
    
    function setMinExecutionFee(uint256 _minExecutionFee) external onlyGov {
        minExecutionFee = _minExecutionFee;
    }

    function setRouter(address _router) external onlyGov {
        router = _router;
    }

    function setVault(address _vault) external onlyGov {
        vault = _vault;
    }

    // 緊急提取函數
    function withdrawFees(address _token, address _receiver) external onlyGov {
        if (_token == address(0)) {
            payable(_receiver).sendValue(address(this).balance);
        } else {
            IERC20(_token).safeTransfer(_receiver, IERC20(_token).balanceOf(address(this)));
        }
    }

    // 接收ETH
    receive() external payable {
        require(msg.sender == weth, "OrderBook: invalid sender");
    }
}