// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// ====== 所有GMX合約共享的庫和接口 ======

// 在 Solidity 0.8+ 中，SafeMath 不再必需，但保留以兼容原代碼邏輯
library SafeMath {
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        return a + b;
    }
    
    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        return a - b;
    }
    
    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        return a * b;
    }
    
    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        return a / b;
    }
}

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
}

library SafeERC20 {
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        (bool success, bytes memory data) = address(token).call(
            abi.encodeWithSelector(token.transfer.selector, to, value)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "SafeERC20: transfer failed");
    }
    
    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        (bool success, bytes memory data) = address(token).call(
            abi.encodeWithSelector(token.transferFrom.selector, from, to, value)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "SafeERC20: transferFrom failed");
    }
}

library Address {
    function sendValue(address payable recipient, uint256 amount) internal {
        require(address(this).balance >= amount, "Address: insufficient balance");
        (bool success, ) = recipient.call{value: amount}("");
        require(success, "Address: unable to send value");
    }
}

abstract contract ReentrancyGuard {
    uint256 private _status;
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    constructor() {
        _status = _NOT_ENTERED;
    }

    modifier nonReentrant() {
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }
}

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
    function transfer(address to, uint256 value) external returns (bool);
}

interface IVault {
    function setIsLeverageEnabled(bool _isLeverageEnabled) external;
    function increasePosition(address account, address collateralToken, address indexToken, uint256 sizeDelta, bool isLong) external;
    function decreasePosition(address account, address collateralToken, address indexToken, uint256 collateralDelta, uint256 sizeDelta, bool isLong, address receiver) external returns (uint256);
    function getMinPrice(address token) external view returns (uint256);
    function getMaxPrice(address token) external view returns (uint256);
    function swap(address tokenIn, address tokenOut, address receiver) external returns (uint256);
}

interface IRouter {
    function pluginDecreasePosition(
        address account,
        address collateralToken,
        address indexToken,
        uint256 collateralDelta,
        uint256 sizeDelta,
        bool isLong,
        address receiver
    ) external returns (uint256);
}

interface IOrderBook {
    function executeDecreaseOrder(address account, uint256 orderIndex, address payable feeReceiver) external;
    function getDecreaseOrder(address account, uint256 orderIndex) external view returns (
        address collateralToken,
        uint256 collateralDelta,
        address indexToken,
        uint256 sizeDelta,
        bool isLong,
        uint256 triggerPrice,
        bool triggerAboveThreshold,
        uint256 executionFee
    );
}

interface IShortsTracker {
    function updateGlobalShortData(
        address account,
        address collateralToken,
        address indexToken,
        bool isLong,
        uint256 sizeDelta,
        uint256 markPrice,
        bool isIncrease
    ) external;
}

interface ITimelock {
    function enableLeverage(address vault) external;
    function disableLeverage(address vault) external;
}