
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/**
 * @title AlpacaSource.sol
 * @author Ola Hamid
 * @notice THIS IS AN DEMO CONTRACT THAT ISN'T AUDITED..
 */

import {OwnableUpgradeable} from "../../lib/openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {DALibrary} from "../Library/DALibrary.sol";
import {DARWAFunctionSrc} from "../FunctionSources/DARWAFunctionSrc.sol";
import {DACreateAbleAsset1155} from "../core/DACreateAbleAsset1155.sol";
import {PausableUpgradeable} from "../../lib/openzeppelin-contracts-upgradeable/contracts/utils/PausableUpgradeable.sol";
import {ReentrancyGuard} from "../../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Initializable} from "../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC1155} from "../../lib/openzeppelin-contracts/contracts/token/ERC1155/IERC1155.sol";
import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IBubbleV1Router} from "../../bubble-v1-protocol/src/interfaces/IBubbleV1Router.sol";
import { BubbleV1Types } from "../../bubble-v1-protocol/src/library/BubbleV1Types.sol";
import {DARWARegistry} from "../core/GOVERNANCE/DARWARegistry.sol";

contract DAEngine is OwnableUpgradeable, PausableUpgradeable, UUPSUpgradeable {
//  NOTE: ADD Chainlink Keepers TO ALLow the contract to have a contract to call all position 
    DACreateAbleAsset1155 public s_DAAsset1155;
    DARWAFunctionSrc public s_DARWAFunctionSrc;
    IERC20[] public s_supportedToken;
    IBubbleV1Router public BubbleRouter;
    DARWARegistry public s_DARWARegistry;

    uint256 constant private precision = 1e18;
    uint256 constant private minSellOutInpercentile = 50;
    uint256 constant private maxSellOutInpercentile = 150;
    uint256 constant private percentile = 100;
    uint256 constant public protocolFee_precision = (precision * 5) / 100;
    //uint256 constant private sellOutCollateral = 1e18;
    uint256 public current1155Price;
    uint256 public totalAssetAmont;

    bytes32 private requestId;
    uint256  public assetId;
    string public assetName;
    address public pool;
    address public ERC1155Token;

    mapping (address => uint) public userAssets;
    mapping (uint256 => address ) public s_AssetPair;
    mapping (address => Position) public s_ReceiversPosition;


    enum healthStatus {
        good,
        bad
    }

    struct AssetDetails {
        uint256 _amountIn;
        uint256 _amountOutMin;
        address[] _path;
        address _receiver;
        uint256 _deadline;
        BubbleV1Types.Raffle _raffle;
    }

    struct Position {
        uint256 entryPrice;
        uint256 amount;
        uint256 buyThreshold;
        uint256 sellThreshold;
        address[] path;
        bool active;
    }
    
    modifier isSupportedToken(address _supportedTokenIn, address _supportedTokenOut) {
        for (uint256 i = 0; i < s_supportedToken.length; i++) {

            if (!((_supportedTokenIn == address(s_supportedToken[i]) && _supportedTokenOut == ERC1155Token) ||
            (_supportedTokenIn == ERC1155Token && _supportedTokenOut == address(s_supportedToken[i])))) {
            revert DALibrary.DARWA_InvalidSupportedToken(_supportedTokenIn, _supportedTokenOut);
        }
    }
        _;
    }
    constructor () {
        _disableInitializers();
    }

    function Initialize(
        address _DAAsset1155,
        address _FunctionSrc,
        uint256 _AssetId,
        address _supportedToken,
        bytes32 _requestId,
        string memory _assetName
    ) external onlyOwner {
        s_DAAsset1155 = DACreateAbleAsset1155(_DAAsset1155);
        s_DARWAFunctionSrc = DARWAFunctionSrc(_FunctionSrc);
        assetId = _AssetId;
        requestId = _requestId;
        assetName = _assetName;
        s_supportedToken.push(IERC20(_supportedToken));

        emit DALibrary.Initialized(_DAAsset1155, _FunctionSrc, _AssetId, _supportedToken, _requestId, _assetName);
    }

    function _checkNoZeroAddress(address _address) internal pure {
        if (_address == address(0)) revert DALibrary.DARWA_ZeroAddress();
    }

    function _checkZeroAmount(uint256 _amount) internal pure {
        if (_amount == 0) revert DALibrary.DARWA_ZEROAmount();
    }

    /* note: 4 main functions here 
    1. directBuy 
    2. directSell
    3. takePosition
    4. closePosition
    5. helthcheck
    */

    /*---------------------------------DirectBuy---------------------------------*/
   function directBuy(
        uint256 _amountIn,
        uint256 _amountOutMin,
        address[] memory _path,
        address _receiver,
        uint256 _deadline,
        BubbleV1Types.Raffle memory _raffle
   ) external returns (uint256[] memory _amount){ 
        if ( s_DARWARegistry.getAssetKilled(assetId)) {
            revert DALibrary.DARWA_AssetKilled();
        }
        _checkNoZeroAddress(_receiver);
        _checkZeroAmount(_amountIn);
        // check that the asset
        healthCheck(address(this));

        for (uint256 i=0; i< s_supportedToken.length; ++i) {
            if (_path[0] != address(s_supportedToken[i]) || _path[1] != address(ERC1155Token)) {
                revert DALibrary.DARWA_InvalidPathAddress(_path[0], _path[1]);
            }
        }
        
        // INTERACTIONS
        for (uint256 i = 0; i < s_supportedToken.length; ++i) {
        
            if (_path[0] != address(s_supportedToken[i]) || _path[1] != address(ERC1155Token)) {
            revert DALibrary.DARWA_InvalidPathAddress(_path[0], _path[1]);
            }
        }
        (_amount, ) = _swapBuyOrSell(_amountIn, _amountOutMin, _path, _receiver, _deadline, _raffle);
        
        s_DARWAFunctionSrc.requestBuyAsset(assetName, assetId, _receiver, _amountIn);
         // effect 
         uint256 previousAmout = userAssets[msg.sender];
        userAssets[msg.sender] = previousAmout + _amountIn;
        totalAssetAmont += _amountIn;

        emit DALibrary.DirectBuy(_receiver, _amountIn, _amount[_amount.length - 1], block.timestamp);
        
        return _amount;
   }
    /*---------------------------------DirectSell---------------------------------*/
    function directSell(
        uint256 _amountIn,
        uint256 _amountOutMin,
        address[] memory _path,
        address _receiver,
        uint256 _deadline,
        BubbleV1Types.Raffle memory _raffle
    ) public 
    returns(uint256[] memory _amount) {
        _checkNoZeroAddress(_receiver);
        _checkZeroAmount(_amountIn);
        uint256 sellerBalance = userAssets[msg.sender];
        if ( _amountIn > sellerBalance ) {
            revert DALibrary.DARWA_InsufficientBalance(sellerBalance);
        }
        for (uint256 i=0; i< s_supportedToken.length; ++i) {
            if (_path[0] != address(ERC1155Token) || _path[1] != address(s_supportedToken[i])) {
                revert DALibrary.DARWA_InvalidPathAddress(_path[0], _path[1]);
            }
        }
        healthCheck(pool);
        
            // EFFECT
        uint256 previousAmout = userAssets[msg.sender];
        userAssets[msg.sender] = previousAmout - _amountIn;
        totalAssetAmont -= _amountIn;
        
        (_amount, ) = _swapBuyOrSell(_amountIn, _amountOutMin, _path, _receiver, _deadline, _raffle);
        s_DARWAFunctionSrc.requestSellAsset(assetName, assetId, _receiver, _amountIn);

        emit DALibrary.DirectSell(_receiver, _amountIn, _amount[_amount.length - 1], block.timestamp);
return _amount;
    }
    /*---------------------------------TakePosition---------------------------------*/

    function takePosition(
        uint256 _buyOutCollateral,
        uint256 _sellOutCollateral,
        uint256 _amountIn,
        uint256 _amountOutMin,
        address[] memory _path,
        address _receiver,
        uint256 _deadline,
        BubbleV1Types.Raffle memory _raffle
    ) 
    public returns(uint256[] memory _amount) {
    if ( s_DARWARegistry.getAssetKilled(assetId)) {
        revert DALibrary.DARWA_AssetKilled();
    }
    _checkNoZeroAddress(_receiver);
    _checkZeroAmount(_amountIn);
    uint256 minSellPrecision = (precision * minSellOutInpercentile) / percentile;
    uint256 maxSellOutPrecision = (precision * maxSellOutInpercentile) / percentile;
    if ((_buyOutCollateral < minSellPrecision) || (_sellOutCollateral > maxSellOutPrecision)) {
        revert DALibrary.DARWA_InvalidPrecision();
        }

    bool validPath = false;
    for (uint256 i=0; i< s_supportedToken.length; ++i) {
        if ((_path[0] == address(s_supportedToken[i]) && _path[1] == ERC1155Token) || (_path[0] == ERC1155Token && _path[1] == address(s_supportedToken[i]))) {
            validPath = true;
            break;
        }
    }
    
    if (!validPath == false) {
        revert DALibrary.DARWA_InvalidPathAddress(_path[0], _path[1]);
    }


            
    (_amount, ) = _swapBuyOrSell(_amountIn, _amountOutMin, _path, _receiver, _deadline, _raffle);
    s_DARWAFunctionSrc.requestBuyAsset(assetName, assetId, _receiver, _amountIn);
    
    // effects
    uint256 previousAmount = userAssets[msg.sender];
    userAssets[msg.sender] = previousAmount + _amountIn;
    totalAssetAmont += _amountIn;
    // Create or update position
    Position storage position = s_ReceiversPosition[_receiver];
    position.entryPrice = getERC1155TokenPrice();
    position.amount = _amountIn;
    position.buyThreshold = _buyOutCollateral;
    position.sellThreshold = _sellOutCollateral;
    position.path = _path;
    position.active = true;

    // check psition thresholds
    checkPositionThresholds(_receiver);

    emit DALibrary.PositionTaken(_receiver, _amountIn, position.entryPrice, _buyOutCollateral, _sellOutCollateral);    
    return _amount;
    }

   function checkPositionThresholds(
    address _user
   ) internal {
    Position storage position = s_ReceiversPosition[_user];
    if (!position.active) return;

    uint256 currentPrice = getERC1155TokenPrice();
    uint256 entryPrice = position.entryPrice;

    uint256 priceRatio = (currentPrice * precision) / entryPrice;

    if (priceRatio < position.buyThreshold) {
        // Sell the asset
        closePosition(_user);
    } else if (priceRatio > position.sellThreshold) {
        // Buy the asset
        closePosition(_user);
        }

    
   }

   function closePosition(
        address _user
    ) internal {
        Position storage position = s_ReceiversPosition[_user];
        if (!position.active) {
            revert DALibrary.DARWA_PositionNotActive();
        }

        address[] memory reversePath = new address[](2);
        reversePath[0] = position.path[1];
        reversePath[1] = position.path[0];

        
        BubbleV1Types.Raffle memory raffle = BubbleV1Types.Raffle(false, BubbleV1Types.Fraction(0, 1), _user);
        (uint256[] memory amountsOut, ) = _swapBuyOrSell(position.amount, position.amount, reversePath, _user, block.timestamp, raffle);
        
        // sell the asset calling the function source
        s_DARWAFunctionSrc.requestSellAsset(assetName, assetId, _user, amountsOut[amountsOut.length - 1]);
        
        // update the userAsset mapping and also the totalAsset state variable
        uint256 previousAmout = userAssets[_user];
        userAssets[_user] = previousAmout - position.amount;
        totalAssetAmont -= position.amount;

        // set the position to false
        position.active = false;
    }

    function healthCheck(
        address _pool
    ) private {
        uint256 previousPrice = current1155Price;
        uint256 PriceDiff;
        
        (, uint256 oraclePrice , , ) = s_DARWAFunctionSrc.getPrice(requestId);
        _checkZeroAmount(oraclePrice);

        if ( oraclePrice < current1155Price) {
            // mint more token
            PriceDiff = current1155Price - oraclePrice;
            s_DAAsset1155.mint(_pool, assetId, PriceDiff, " ");
        } else if(oraclePrice > current1155Price) {
            // burn more token
            PriceDiff = oraclePrice - current1155Price;
            s_DAAsset1155.burn(_pool, assetId, PriceDiff);
        }
        oraclePrice = current1155Price;

        emit DALibrary.HealthCheck(_pool, oraclePrice, previousPrice, PriceDiff);
    }
    function _updateCurrentPrice(
        uint256[] memory amount
    ) private {
        if (amount.length == 0) {
            revert DALibrary.DARWA_ZEROAmount();
        }
        uint256 AssetAmount = amount[amount.length - 1];
        uint256 previousPrice = current1155Price;
        current1155Price = AssetAmount;

        emit DALibrary.PriceUpdated(previousPrice, current1155Price);
    }
    function setAssetPair(
        uint256 _assetPair,
        address _pair
    ) external
    onlyOwner {
        s_AssetPair[_assetPair] = _pair;

        emit DALibrary.AssetPairSet(_assetPair, _pair);
    }

    function addLiquid(
        // fixme add a check that only supported token and erc155 asset token can be added
        BubbleV1Types.AddLiquidity memory _addLiquidityParams
    ) public returns(uint256 amountA, uint256 amountB, uint256 liquidity) {
        (amountA, amountB, liquidity) = BubbleRouter.addLiquidity(_addLiquidityParams);
        
        emit DALibrary.LiquidityAdded(_addLiquidityParams.tokenA, _addLiquidityParams.tokenB, amountA, amountB, liquidity);
        return (amountA, amountB, liquidity);
    }

    function removeLiquid(
        address _tokenA,
        address _tokenB,
        uint256 _lpTokensToBurn,
        uint256 _amountAMin,
        uint256 _amountBMin,
        address _receiver,
        uint256 _deadline
    ) internal returns(uint256 amountA, uint256 amountB){
        (amountA, amountB) = BubbleRouter.removeLiquidity(_tokenA, _tokenB, _lpTokensToBurn, _amountAMin, _amountBMin, _receiver, _deadline);

        emit DALibrary.LiquidityRemoved(_tokenA, _tokenB, amountA, amountB, _lpTokensToBurn);
        return (amountA,amountB);
    }

    /*----------------------------------------------_swap--------------------------------------------*/
    function _swapBuyOrSell(
        uint256 _amountIn,
        uint256 _amountOutMin,
        address[] memory _path,
        address _receiver,
        uint256 _deadline,
        BubbleV1Types.Raffle memory _raffle
    ) internal returns (uint256[] memory _amountOut, uint256 _NFTId) {
        if (_path.length != 2) {
            revert DALibrary.DARWA_InvalidPathLength(_path.length);
        }
        (_amountOut, _NFTId) = BubbleRouter.swapExactTokensForTokens(_amountIn,_amountOutMin, _path, _receiver, _deadline, _raffle);
        _updateCurrentPrice(_amountOut);
    }


    function _authorizeUpgrade(
        address _newImplementation
    ) internal 
    override
    onlyOwner {}

    function setSuppotedToken(
        address _supportedToken
    ) external onlyOwner {
        s_supportedToken.push(IERC20(_supportedToken));
    }

    //*----------------------------------------Getter function-------------------------------------------*/
    function getAssetPair(
        uint256 _assetId
    ) public view returns(address) {
        return s_AssetPair[_assetId];
    }

    function getERC1155TokenPrice() public view returns(uint256 _price) {
        (, uint256 oraclePrice, , ) = s_DARWAFunctionSrc.getPrice(requestId);
        
        if (oraclePrice > 0) {
            return oraclePrice;
        }
        
        // Fallback to the current tracked price
        return current1155Price;
    }

    // Added getter functions
    function getRequestId() external view returns (bytes32) {
        return requestId;
    }

    function getSupportedTokens() external view returns (IERC20[] memory) {
        return s_supportedToken;
    }

    function getSupportedTokenCount() external view returns (uint256) {
        return s_supportedToken.length;
    }

    function getUserPosition(address _user) external view returns (
        uint256 entryPrice,
        uint256 amount,
        uint256 buyThreshold,
        uint256 sellThreshold,
        bool active
    ) {
        Position storage position = s_ReceiversPosition[_user];
        return (
            position.entryPrice,
            position.amount,
            position.buyThreshold,
            position.sellThreshold,
            position.active
        );
    }


    function getContractBalance(address _token) external view returns (uint256) {
        return IERC20(_token).balanceOf(address(this));
    }

    function isPaused() external view returns (bool) {
        return paused();
    }

    function isPositionActive(address _user) external view returns (bool) {
        return s_ReceiversPosition[_user].active;
    }

    function getProtocolFee() external pure returns (uint256) {
        return protocolFee_precision;
    }

    function validatePath(address[] memory _path) external view returns (bool) {
        if (_path.length != 2) {
            return false;
    }   
    
        bool validPath = false;
        for (uint256 i = 0; i < s_supportedToken.length; ++i) {
            if ((_path[0] == address(s_supportedToken[i]) && _path[1] == ERC1155Token) || 
                (_path[0] == ERC1155Token && _path[1] == address(s_supportedToken[i]))) {
                validPath = true;
                break;
            }
        }
    
        return validPath;
    }
}

