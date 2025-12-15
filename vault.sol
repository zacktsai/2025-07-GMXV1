// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// 只導入共享庫
import "./Libraries.sol";

// 對照真實合約: 0x489ee077994B6658eAfA855C308275EAd8097C4A
contract Vault is ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // ====== 核心狀態變量 ======
    mapping(address => uint256) public poolAmounts;
    mapping(address => uint256) public globalShortSizes;        // 🚨 攻擊目標狀態
    mapping(address => uint256) public globalShortAveragePrices; // 🚨 攻擊目標狀態
    
    mapping(bytes32 => Position) public positions;
    mapping(address => bool) public whitelistedTokens;
    mapping(address => bool) public isManager;
    
    address public gov;
    address public router;
    bool public isLeverageEnabled = false;  // 🚨 關鍵控制變量
    
    uint256 public constant PRICE_PRECISION = 10**30;
    uint256 public constant BASIS_POINTS_DIVISOR = 10000;
    
    struct Position {
        uint256 size;
        uint256 collateral;
        uint256 averagePrice;
        uint256 entryFundingRate;
        uint256 reserveAmount;
        int256 realisedPnl;
        uint256 lastIncreasedTime;
    }

    // ====== 事件定義 ======
    event IncreasePosition(
        bytes32 key,
        address account,
        address collateralToken,
        address indexToken,
        uint256 collateralDelta,
        uint256 sizeDelta,
        bool isLong,
        uint256 price,
        uint256 fee
    );

    event DecreasePosition(
        bytes32 key,
        address account,
        address collateralToken,
        address indexToken,
        uint256 collateralDelta,
        uint256 sizeDelta,
        bool isLong,
        uint256 price,
        uint256 fee
    );

    modifier onlyGov() {
        require(msg.sender == gov, "Vault: forbidden");
        _;
    }

    modifier onlyManager() {
        require(isManager[msg.sender], "Vault: forbidden");
        _;
    }

    constructor() {
        gov = msg.sender;
    }

    // ====== 管理函數 ======
    function setManager(address _manager, bool _isActive) external onlyGov {
        isManager[_manager] = _isActive;
    }

    function setRouter(address _router) external onlyGov {
        router = _router;
    }

    // 🚨 關鍵函數：槓桿控制（被PositionManager調用）
    function setIsLeverageEnabled(bool _isLeverageEnabled) external {
        // 🔧 FIX: Allow both gov and managers to control leverage
        require(msg.sender == gov || isManager[msg.sender], "Vault: forbidden");
        isLeverageEnabled = _isLeverageEnabled;
    }

    // ====== 核心業務邏輯 ======
    
    // 🚨 被重入攻擊的函數
    function increasePosition(
        address _account,
        address _collateralToken,
        address _indexToken,
        uint256 _sizeDelta,
        bool _isLong
    ) external nonReentrant {
        require(isLeverageEnabled, "Vault: leverage not enabled");
        require(isManager[msg.sender] || msg.sender == router, "Vault: forbidden");
        require(_sizeDelta > 0, "Vault: invalid sizeDelta");

        bytes32 key = getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        Position storage position = positions[key];

        uint256 price = getPrice(_indexToken);
        
        if (!_isLong) {
            // 🚨 關鍵漏洞點：只更新globalShortSizes，不更新globalShortAveragePrices
            globalShortSizes[_indexToken] = globalShortSizes[_indexToken].add(_sizeDelta);
        }

        // 更新倉位
        if (position.size == 0) {
            position.averagePrice = price;
        } else {
            position.averagePrice = getNextAveragePrice(
                _indexToken, 
                position.size, 
                position.averagePrice, 
                _isLong, 
                price, 
                _sizeDelta, 
                position.lastIncreasedTime
            );
        }

        position.size = position.size.add(_sizeDelta);
        position.lastIncreasedTime = block.timestamp;

        emit IncreasePosition(
            key,
            _account,
            _collateralToken,
            _indexToken,
            0,
            _sizeDelta,
            _isLong,
            price,
            0
        );
    }

    function decreasePosition(
        address _account,
        address _collateralToken,
        address _indexToken,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong,
        address /* _receiver */
    ) external nonReentrant returns (uint256) {
        require(isManager[msg.sender] || msg.sender == router, "Vault: forbidden");
        
        bytes32 key = getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        Position storage position = positions[key];
        require(position.size >= _sizeDelta, "Vault: position size exceeded");

        if (!_isLong) {
            globalShortSizes[_indexToken] = globalShortSizes[_indexToken].sub(_sizeDelta);
        }

        position.size = position.size.sub(_sizeDelta);
        
        uint256 price = getPrice(_indexToken);
        
        emit DecreasePosition(
            key,
            _account,
            _collateralToken,
            _indexToken,
            _collateralDelta,
            _sizeDelta,
            _isLong,
            price,
            0
        );

        return _collateralDelta;
    }

    // ====== AUM計算（被攻擊利用的函數）======
    
    // 🚨 關鍵函數：AUM計算（被價格操縱影響）
    function getAum() public view returns (uint256) {
        uint256 aum = 0;
        
        // 計算池子資產價值
        address[] memory tokens = getWhitelistedTokens();
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            uint256 poolAmount = poolAmounts[token];
            uint256 price = getPrice(token);
            aum = aum.add(poolAmount.mul(price).div(PRICE_PRECISION));
        }
        
        // 🚨 關鍵計算：加入空頭倉位的未實現損失
        uint256 shortProfits = getGlobalShortPnl();
        aum = aum.add(shortProfits);
        
        return aum;
    }

    // 🚨 被攻擊操縱的計算函數
    function getGlobalShortPnl() public view returns (uint256) {
        address wbtc = address(0x2);
        
        uint256 size = globalShortSizes[wbtc];
        if (size == 0) return 0;
        
        uint256 averagePrice = globalShortAveragePrices[wbtc];
        uint256 currentPrice = getPrice(wbtc);
        
        if (currentPrice > averagePrice && averagePrice > 0) {
            uint256 priceDelta = currentPrice.sub(averagePrice);
            return size.mul(priceDelta).div(averagePrice);
        }
        
        return 0;
    }

    // ====== 輔助函數 ======
    
    function getPositionKey(
        address _account,
        address _collateralToken,
        address _indexToken,
        bool _isLong
    ) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(_account, _collateralToken, _indexToken, _isLong));
    }

    function getPrice(address _token) public pure returns (uint256) {
        if (_token == address(0x1)) return 3000 * PRICE_PRECISION; // ETH
        if (_token == address(0x2)) return 60000 * PRICE_PRECISION; // BTC  
        if (_token == address(0x3)) return 1 * PRICE_PRECISION; // USDC
        return PRICE_PRECISION;
    }

    function getNextAveragePrice(
        address /* _indexToken */,
        uint256 _size,
        uint256 _averagePrice,
        bool /* _isLong */,
        uint256 _nextPrice,
        uint256 _sizeDelta,
        uint256 /* _lastIncreasedTime */
    ) public pure returns (uint256) {
        uint256 nextSize = _size.add(_sizeDelta);
        return (_averagePrice.mul(_size).add(_nextPrice.mul(_sizeDelta))).div(nextSize);
    }

    function getWhitelistedTokens() public pure returns (address[] memory) {
        address[] memory tokens = new address[](3);
        tokens[0] = address(0x1); // ETH
        tokens[1] = address(0x2); // BTC
        tokens[2] = address(0x3); // USDC
        return tokens;
    }

    // ====== 测试辅助函数 ======
    
    function setInitialPosition(
        address _account,
        address _collateralToken,
        address _indexToken,
        uint256 _size,
        bool _isLong,
        uint256 _averagePrice
    ) external onlyGov {
        bytes32 key = getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        Position storage position = positions[key];
        position.size = _size;
        position.averagePrice = _averagePrice;
        position.lastIncreasedTime = block.timestamp;
        
        // Also update global short data if it's a short position
        if (!_isLong) {
            globalShortSizes[_indexToken] = globalShortSizes[_indexToken] + _size;
        }
    }
    
    function setPoolAmount(address _token, uint256 _amount) external onlyGov {
        poolAmounts[_token] = _amount;
    }

    function setGlobalShortData(address _token, uint256 _size, uint256 _averagePrice) external onlyGov {
        globalShortSizes[_token] = _size;
        globalShortAveragePrices[_token] = _averagePrice;
    }

    function emergencyStop() external onlyGov {
        isLeverageEnabled = false;
    }

    function swap(
        address /* _tokenIn */, 
        address /* _tokenOut */, 
        address /* _receiver */
    ) external pure returns (uint256) {
        return 1000000;
    }

    function getMinPrice(address _token) external pure returns (uint256) {
        return getPrice(_token);
    }

    function getMaxPrice(address _token) external pure returns (uint256) {
        return getPrice(_token);
    }
}