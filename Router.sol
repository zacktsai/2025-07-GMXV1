// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./Libraries.sol";

// 對照真實合約: Router合約地址
contract Router {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using Address for address payable;

    // ====== 狀態變量 ======
    address public gov;
    address public weth;
    address public vault;
    
    mapping(address => bool) public plugins;
    mapping(address => mapping(address => bool)) public approvedPlugins;

    // ====== 事件 ======
    event Swap(
        address account,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    event IncreasePosition(
        address account,
        address collateralToken,
        address indexToken,
        uint256 collateralDelta,
        uint256 sizeDelta,
        bool isLong,
        uint256 price
    );

    event DecreasePosition(
        address account,
        address collateralToken,
        address indexToken,
        uint256 collateralDelta,
        uint256 sizeDelta,
        bool isLong,
        uint256 price
    );

    modifier onlyGov() {
        require(msg.sender == gov, "Router: forbidden");
        _;
    }

    constructor(address _vault, address _weth) {
        gov = msg.sender;
        vault = _vault;
        weth = _weth;
    }

    // ====== 插件管理 ======
    
    function addPlugin(address _plugin) external onlyGov {
        plugins[_plugin] = true;
    }

    function removePlugin(address _plugin) external onlyGov {
        plugins[_plugin] = false;
    }

    function approvePlugin(address _plugin) external {
        approvedPlugins[msg.sender][_plugin] = true;
    }

    function denyPlugin(address _plugin) external {
        approvedPlugins[msg.sender][_plugin] = false;
    }

    // ====== 核心交易函數 ======

    function swap(
        address[] memory _path,
        uint256 _amountIn,
        uint256 _minOut,
        address _receiver
    ) external {
        IERC20(_path[0]).safeTransferFrom(msg.sender, vault, _amountIn);
        uint256 amountOut = _swap(_path, _minOut, _receiver);
        
        emit Swap(msg.sender, _path[0], _path[_path.length - 1], _amountIn, amountOut);
    }

    // ====== 倉位管理函數 ======

    function increasePosition(
        address[] memory _path,
        address _indexToken,
        uint256 _amountIn,
        uint256 _minOut,
        uint256 _sizeDelta,
        bool _isLong,
        uint256 _price
    ) external {
        if (_amountIn > 0) {
            IERC20(_path[0]).safeTransferFrom(msg.sender, vault, _amountIn);
        }
        if (_path.length > 1 && _amountIn > 0) {
            uint256 amountOut = _swap(_path, _minOut, address(this));
            IERC20(_path[_path.length - 1]).safeTransfer(vault, amountOut);
        }
        
        _increasePosition(_path[_path.length - 1], _indexToken, _sizeDelta, _isLong, _price);
    }

    function decreasePosition(
        address _collateralToken,
        address _indexToken,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong,
        address _receiver,
        uint256 _price
    ) external returns (uint256) {
        return _decreasePosition(_collateralToken, _indexToken, _collateralDelta, _sizeDelta, _isLong, _receiver, _price);
    }

    // 🚨 關鍵函數：插件減倉（被OrderBook調用）
    // 這個函數是攻擊流程中的重要環節
    function pluginDecreasePosition(
        address _account,
        address _collateralToken,
        address _indexToken,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong,
        address _receiver
    ) external returns (uint256) {
        require(plugins[msg.sender], "Router: invalid plugin");
        require(approvedPlugins[_account][msg.sender], "Router: plugin not approved");

        return IVault(vault).decreasePosition(
            _account,
            _collateralToken,
            _indexToken,
            _collateralDelta,
            _sizeDelta,
            _isLong,
            _receiver
        );
    }

    function pluginIncreasePosition(
        address _account,
        address _collateralToken,
        address _indexToken,
        uint256 _sizeDelta,
        bool _isLong
    ) external {
        require(plugins[msg.sender], "Router: invalid plugin");
        require(approvedPlugins[_account][msg.sender], "Router: plugin not approved");

        IVault(vault).increasePosition(_account, _collateralToken, _indexToken, _sizeDelta, _isLong);
    }

    // ====== ETH相關函數 ======

    function increasePositionETH(
        address[] memory _path,
        address _indexToken,
        uint256 _minOut,
        uint256 _sizeDelta,
        bool _isLong,
        uint256 _price
    ) external payable {
        require(_path[0] == weth, "Router: invalid _path");
        
        if (msg.value > 0) {
            _transferETHToVault();
        }
        if (_path.length > 1 && msg.value > 0) {
            uint256 amountOut = _swap(_path, _minOut, address(this));
            IERC20(_path[_path.length - 1]).safeTransfer(vault, amountOut);
        }
        
        _increasePosition(_path[_path.length - 1], _indexToken, _sizeDelta, _isLong, _price);
    }

    function decreasePositionETH(
        address _collateralToken,
        address _indexToken,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong,
        address payable _receiver,
        uint256 _price
    ) external returns (uint256) {
        uint256 amountOut = _decreasePosition(_collateralToken, _indexToken, _collateralDelta, _sizeDelta, _isLong, address(this), _price);
        _transferOutETH(amountOut, _receiver);
        return amountOut;
    }

    function decreasePositionAndSwap(
        address[] memory _path,
        address _indexToken,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong,
        address _receiver,
        uint256 _price,
        uint256 _minOut
    ) external {
        uint256 amount = _decreasePosition(_path[0], _indexToken, _collateralDelta, _sizeDelta, _isLong, address(this), _price);
        IERC20(_path[0]).safeTransfer(vault, amount);
        _swap(_path, _minOut, _receiver);
    }

    function decreasePositionAndSwapETH(
        address[] memory _path,
        address _indexToken,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong,
        address payable _receiver,
        uint256 _price,
        uint256 _minOut
    ) external {
        require(_path[_path.length - 1] == weth, "Router: invalid _path");
        
        uint256 amount = _decreasePosition(_path[0], _indexToken, _collateralDelta, _sizeDelta, _isLong, address(this), _price);
        IERC20(_path[0]).safeTransfer(vault, amount);
        uint256 amountOut = _swap(_path, _minOut, address(this));
        _transferOutETH(amountOut, _receiver);
    }

    // ====== 內部函數 ======

    function _increasePosition(
        address _collateralToken,
        address _indexToken,
        uint256 _sizeDelta,
        bool _isLong,
        uint256 _price
    ) internal {
        if (_isLong) {
            require(IVault(vault).getMaxPrice(_indexToken) <= _price, "Router: mark price higher than limit");
        } else {
            require(IVault(vault).getMinPrice(_indexToken) >= _price, "Router: mark price lower than limit");
        }

        IVault(vault).increasePosition(_sender(), _collateralToken, _indexToken, _sizeDelta, _isLong);
        
        emit IncreasePosition(_sender(), _collateralToken, _indexToken, 0, _sizeDelta, _isLong, _price);
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
        if (_isLong) {
            require(IVault(vault).getMinPrice(_indexToken) >= _price, "Router: mark price lower than limit");
        } else {
            require(IVault(vault).getMaxPrice(_indexToken) <= _price, "Router: mark price higher than limit");
        }

        uint256 amountOut = IVault(vault).decreasePosition(_sender(), _collateralToken, _indexToken, _collateralDelta, _sizeDelta, _isLong, _receiver);
        
        emit DecreasePosition(_sender(), _collateralToken, _indexToken, _collateralDelta, _sizeDelta, _isLong, _price);
        
        return amountOut;
    }

    function _swap(address[] memory _path, uint256 _minOut, address _receiver) internal returns (uint256) {
        if (_path.length == 2) {
            return _vaultSwap(_path[0], _path[1], _minOut, _receiver);
        }
        revert("Router: invalid _path.length");
    }

    function _vaultSwap(address _tokenIn, address _tokenOut, uint256 _minOut, address _receiver) internal returns (uint256) {
        uint256 amountOut = IVault(vault).swap(_tokenIn, _tokenOut, _receiver);
        require(amountOut >= _minOut, "Router: insufficient amountOut");
        return amountOut;
    }

    function _transferETHToVault() internal {
        IWETH(weth).deposit{value: msg.value}();
        IERC20(weth).safeTransfer(vault, msg.value);
    }

    function _transferOutETH(uint256 _amountOut, address payable _receiver) internal {
        IWETH(weth).withdraw(_amountOut);
        _receiver.sendValue(_amountOut);
    }

    function _sender() internal view returns (address) {
        return msg.sender;
    }

    // ====== 管理函數 ======

    function setGov(address _gov) external onlyGov {
        gov = _gov;
    }

    function setVault(address _vault) external onlyGov {
        vault = _vault;
    }

    // 緊急提取函數
    function withdrawToken(address _token, address _account, uint256 _amount) external onlyGov {
        IERC20(_token).safeTransfer(_account, _amount);
    }

    function withdrawETH(address payable _account, uint256 _amount) external onlyGov {
        _account.sendValue(_amount);
    }

    // 接收ETH
    receive() external payable {
        require(msg.sender == weth, "Router: invalid sender");
    }
}