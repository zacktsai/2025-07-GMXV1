// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./Libraries.sol";

// 對照真實合約: 0x75e42e6f01baf1d6022bea862a28774a9f8a4a0c
contract PositionManager is ReentrancyGuard {
    using SafeMath for uint256;

    // ====== 狀態變量 ======
    address public gov;
    address public vault;
    address public router;
    address public shortsTracker;
    address public orderBook;
    address public timelock;
    address public weth;
    
    mapping(address => bool) public isOrderKeeper;
    mapping(address => bool) public isPartner;
    mapping(address => bool) public isLiquidator;
    
    bool public inLegacyMode = true;
    bool public shouldValidateIncreaseOrder = true;
    uint256 public depositFee = 30; // 0.3%

    // ====== 事件 ======
    event SetOrderKeeper(address indexed account, bool isActive);
    event SetPartner(address account, bool isActive);
    event ExecuteDecreaseOrder(
        address account,
        uint256 orderIndex,
        address collateralToken,
        uint256 collateralDelta,
        address indexToken,
        uint256 sizeDelta,
        bool isLong,
        address feeReceiver,
        uint256 amountOut
    );

    // ====== 修飾符 ======
    modifier onlyGov() {
        require(msg.sender == gov, "PositionManager: forbidden");
        _;
    }

    modifier onlyOrderKeeper() {
        require(isOrderKeeper[msg.sender], "PositionManager: forbidden");
        _;
    }

    modifier onlyLiquidator() {
        require(isLiquidator[msg.sender], "PositionManager: forbidden");
        _;
    }

    modifier onlyPartnersOrLegacyMode() {
        require(isPartner[msg.sender] || inLegacyMode, "PositionManager: forbidden");
        _;
    }

    constructor(
        address _vault,
        address _router,
        address _shortsTracker,
        address _weth,
        address _orderBook,
        address _timelock
    ) {
        gov = msg.sender;
        vault = _vault;
        router = _router;
        shortsTracker = _shortsTracker;
        weth = _weth;
        orderBook = _orderBook;
        timelock = _timelock;
    }

    // ====== 管理函數 ======
    
    function setOrderKeeper(address _account, bool _isActive) external onlyGov {
        isOrderKeeper[_account] = _isActive;
        emit SetOrderKeeper(_account, _isActive);
    }

    function setPartner(address _account, bool _isActive) external onlyGov {
        isPartner[_account] = _isActive;
        emit SetPartner(_account, _isActive);
    }

    function setLiquidator(address _account, bool _isActive) external onlyGov {
        isLiquidator[_account] = _isActive;
    }

    function setInLegacyMode(bool _inLegacyMode) external onlyGov {
        inLegacyMode = _inLegacyMode;
    }

    function setShortsTracker(address _shortsTracker) external onlyGov {
        shortsTracker = _shortsTracker;
    }

    // ====== 核心業務邏輯 ======

    // 🚨 關鍵攻擊函數 - executeDecreaseOrder (徹底簡化版)
    function executeDecreaseOrder(
        address _account, 
        uint256 _orderIndex, 
        address payable _feeReceiver
    ) external onlyOrderKeeper {
        // 步驟1：處理短倉更新 - 拆分到獨立函數
        _handleShortsUpdate(_account, _orderIndex);
        
        // 步驟2：執行訂單 - 拆分到獨立函數  
        _executeOrder(_account, _orderIndex, _feeReceiver);
        
        // 步驟3：發送事件 - 拆分到獨立函數
        _emitOrderEvent(_account, _orderIndex, _feeReceiver);
    }

    // 處理短倉更新 - 最小化局部變數
    function _handleShortsUpdate(address _account, uint256 _orderIndex) internal {
        // 只獲取必要的字段，使用局部作用域
        {
            (
                address collateralToken,
                , // 跳過 collateralDelta
                address indexToken,
                uint256 sizeDelta,
                bool isLong,
                , // 跳過 triggerPrice
                , // 跳過 triggerAboveThreshold
                  // 跳過 executionFee
            ) = IOrderBook(orderBook).getDecreaseOrder(_account, _orderIndex);

            uint256 markPrice = isLong ? 
                IVault(vault).getMinPrice(indexToken) : 
                IVault(vault).getMaxPrice(indexToken);

            IShortsTracker(shortsTracker).updateGlobalShortData(
                _account, 
                collateralToken, 
                indexToken, 
                isLong, 
                sizeDelta, 
                markPrice, 
                false
            );
        }
    }

    // 執行訂單 - 核心邏輯
    function _executeOrder(
        address _account, 
        uint256 _orderIndex, 
        address payable _feeReceiver
    ) internal {
        // 🚨 關鍵步驟1：啟用槓桿
        ITimelock(timelock).enableLeverage(vault);

        // 🚨 關鍵步驟2：執行減倉訂單（重入攻擊點）
        IOrderBook(orderBook).executeDecreaseOrder(_account, _orderIndex, _feeReceiver);

        // ❌ 關鍵問題：這行永遠執行不到！
        ITimelock(timelock).disableLeverage(vault);
    }

    // 發送事件 - 單獨處理
    function _emitOrderEvent(
        address _account, 
        uint256 _orderIndex, 
        address _feeReceiver
    ) internal {
        // 重新獲取事件所需數據，使用局部作用域減少變數
        {
            (
                address collateralToken,
                uint256 collateralDelta,
                address indexToken,
                uint256 sizeDelta,
                bool isLong,
                , // 跳過不需要的字段
                ,
                
            ) = IOrderBook(orderBook).getDecreaseOrder(_account, _orderIndex);

            emit ExecuteDecreaseOrder(
                _account,
                _orderIndex,
                collateralToken,
                collateralDelta,
                indexToken,
                sizeDelta,
                isLong,
                _feeReceiver,
                0 // amountOut - 簡化
            );
        }
    }

    // 正常的增倉函數（供對比）
    function executeIncreaseOrder(
        address _account, 
        uint256 _orderIndex, 
        address payable _feeReceiver
    ) external onlyOrderKeeper {
        ITimelock(timelock).enableLeverage(vault);
        ITimelock(timelock).disableLeverage(vault);
    }

    // ====== 直接倉位操作 ======
    
    function increasePosition(
        address[] memory _path,
        address _indexToken,
        uint256 _amountIn,
        uint256 _minOut,
        uint256 _sizeDelta,
        bool _isLong,
        uint256 _price
    ) external nonReentrant onlyPartnersOrLegacyMode {
        require(_path.length == 1 || _path.length == 2, "PositionManager: invalid _path.length");

        if (_amountIn > 0) {
            IERC20(_path[0]).transferFrom(msg.sender, vault, _amountIn);
        }

        _increasePosition(msg.sender, _path[_path.length - 1], _indexToken, _sizeDelta, _isLong, _price);
    }

    function decreasePosition(
        address _collateralToken,
        address _indexToken,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong,
        address _receiver,
        uint256 _price
    ) external nonReentrant onlyPartnersOrLegacyMode returns (uint256) {
        return _decreasePosition(
            _collateralToken,
            _indexToken,
            _collateralDelta,
            _sizeDelta,
            _isLong,
            _receiver,
            _price
        );
    }

    // ====== 內部函數 ======
    
    function _increasePosition(
        address _account,
        address _collateralToken,
        address _indexToken,
        uint256 _sizeDelta,
        bool _isLong,
        uint256 _price
    ) internal {
        uint256 referencePrice = _isLong ? 
            IVault(vault).getMaxPrice(_indexToken) : 
            IVault(vault).getMinPrice(_indexToken);
            
        if (_isLong) {
            require(referencePrice <= _price, "PositionManager: mark price higher than limit");
        } else {
            require(referencePrice >= _price, "PositionManager: mark price lower than limit");
        }

        IVault(vault).increasePosition(_account, _collateralToken, _indexToken, _sizeDelta, _isLong);
    }

    function _decreasePosition(
        address _collateralToken,
        address _indexToken,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong,
        address _receiver,
        uint256 _price
    ) internal returns (uint256) {
        uint256 referencePrice = _isLong ? 
            IVault(vault).getMinPrice(_indexToken) : 
            IVault(vault).getMaxPrice(_indexToken);
            
        if (_isLong) {
            require(referencePrice >= _price, "PositionManager: mark price lower than limit");
        } else {
            require(referencePrice <= _price, "PositionManager: mark price higher than limit");
        }

        return IVault(vault).decreasePosition(
            msg.sender,
            _collateralToken,
            _indexToken,
            _collateralDelta,
            _sizeDelta,
            _isLong,
            _receiver
        );
    }

    // ====== 輔助函數 ======
    
    function getRequestKey(address _account, uint256 _index) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(_account, _index));
    }

    // ====== 緊急函數 ======
    
    function emergencyStop() external onlyGov {
        if (timelock != address(0)) {
            ITimelock(timelock).disableLeverage(vault);
        }
    }

    // 設置合約地址
    function setAddresses(
        address _vault,
        address _router,
        address _shortsTracker,
        address _orderBook,
        address _timelock
    ) external onlyGov {
        vault = _vault;
        router = _router;
        shortsTracker = _shortsTracker;
        orderBook = _orderBook;
        timelock = _timelock;
    }
}