// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {ISiloConfig, ISilo} from "src/interfaces/silo/ISilo.sol";

/// @title MockSiloConfig
/// @notice Mock implementation of ISiloConfig for testing purposes
/// @dev Simplified version that stores configuration data similar to the real SiloConfig
///      The real contract uses immutable variables, but for testing we use storage for flexibility
contract MockSiloConfig is ISiloConfig {
    uint256 public SILO_ID;

    // Shared config
    uint256 internal _daoFee;
    uint256 internal _deployerFee;
    address internal _hookReceiver;

    // Token 0 config
    address internal _silo0;
    address internal _token0;
    address internal _protectedShareToken0;
    address internal _collateralShareToken0;
    address internal _debtShareToken0;
    address internal _solvencyOracle0;
    address internal _maxLtvOracle0;
    address internal _interestRateModel0;
    uint256 internal _maxLtv0;
    uint256 internal _lt0;
    uint256 internal _liquidationTargetLtv0;
    uint256 internal _liquidationFee0;
    uint256 internal _flashloanFee0;
    bool internal _callBeforeQuote0;

    // Token 1 config
    address internal _silo1;
    address internal _token1;
    address internal _protectedShareToken1;
    address internal _collateralShareToken1;
    address internal _debtShareToken1;
    address internal _solvencyOracle1;
    address internal _maxLtvOracle1;
    address internal _interestRateModel1;
    uint256 internal _maxLtv1;
    uint256 internal _lt1;
    uint256 internal _liquidationTargetLtv1;
    uint256 internal _liquidationFee1;
    uint256 internal _flashloanFee1;
    bool internal _callBeforeQuote1;

    /// @inheritdoc ISiloConfig
    mapping(address borrower => address collateralSilo) public borrowerCollateralSilo;

    bool internal _reentrancyGuardEntered;

    constructor(uint256 _siloId, ConfigData memory _configData0, ConfigData memory _configData1) {
        SILO_ID = _siloId;

        // Shared config
        _daoFee = _configData0.daoFee;
        _deployerFee = _configData0.deployerFee;
        _hookReceiver = _configData0.hookReceiver;

        // Token 0 config
        _silo0 = _configData0.silo;
        _token0 = _configData0.token;
        _protectedShareToken0 = _configData0.protectedShareToken;
        _collateralShareToken0 = _configData0.silo; // In real Silo, collateral share token is the Silo itself
        _debtShareToken0 = _configData0.debtShareToken;
        _solvencyOracle0 = _configData0.solvencyOracle;
        _maxLtvOracle0 = _configData0.maxLtvOracle;
        _interestRateModel0 = _configData0.interestRateModel;
        _maxLtv0 = _configData0.maxLtv;
        _lt0 = _configData0.lt;
        _liquidationTargetLtv0 = _configData0.liquidationTargetLtv;
        _liquidationFee0 = _configData0.liquidationFee;
        _flashloanFee0 = _configData0.flashloanFee;
        _callBeforeQuote0 = _configData0.callBeforeQuote;

        // Token 1 config
        _silo1 = _configData1.silo;
        _token1 = _configData1.token;
        _protectedShareToken1 = _configData1.protectedShareToken;
        _collateralShareToken1 = _configData1.silo; // In real Silo, collateral share token is the Silo itself
        _debtShareToken1 = _configData1.debtShareToken;
        _solvencyOracle1 = _configData1.solvencyOracle;
        _maxLtvOracle1 = _configData1.maxLtvOracle;
        _interestRateModel1 = _configData1.interestRateModel;
        _maxLtv1 = _configData1.maxLtv;
        _lt1 = _configData1.lt;
        _liquidationTargetLtv1 = _configData1.liquidationTargetLtv;
        _liquidationFee1 = _configData1.liquidationFee;
        _flashloanFee1 = _configData1.flashloanFee;
        _callBeforeQuote1 = _configData1.callBeforeQuote;
    }

    /// @inheritdoc ISiloConfig
    function setThisSiloAsCollateralSilo(
        address _borrower
    ) external virtual override returns (bool collateralSiloChanged) {
        return _setSiloAsCollateralSilo(msg.sender, _borrower);
    }

    /// @inheritdoc ISiloConfig
    function setOtherSiloAsCollateralSilo(
        address _borrower
    ) external virtual override returns (bool collateralSiloChanged) {
        address otherSilo = msg.sender == _silo0 ? _silo1 : _silo0;
        return _setSiloAsCollateralSilo(otherSilo, _borrower);
    }

    /// @inheritdoc ISiloConfig
    function onDebtTransfer(address _sender, address _recipient) external virtual override {
        require(msg.sender == _debtShareToken0 || msg.sender == _debtShareToken1, "OnlyDebtShareToken");

        address thisSilo = msg.sender == _debtShareToken0 ? _silo0 : _silo1;

        require(!hasDebtInOtherSilo(thisSilo, _recipient), "DebtExistInOtherSilo");

        if (borrowerCollateralSilo[_recipient] == address(0)) {
            borrowerCollateralSilo[_recipient] = borrowerCollateralSilo[_sender];
        }
    }

    /// @inheritdoc ISiloConfig
    function accrueInterestForSilo(address _silo) external virtual override {
        address irm;

        if (_silo == _silo0) {
            irm = _interestRateModel0;
        } else if (_silo == _silo1) {
            irm = _interestRateModel1;
        } else {
            revert("WrongSilo");
        }

        ISilo(_silo).accrueInterestForConfig(irm, _daoFee, _deployerFee);
    }

    /// @inheritdoc ISiloConfig
    function accrueInterestForBothSilos() external virtual override {
        ISilo(_silo0).accrueInterestForConfig(_interestRateModel0, _daoFee, _deployerFee);
        ISilo(_silo1).accrueInterestForConfig(_interestRateModel1, _daoFee, _deployerFee);
    }

    /// @inheritdoc ISiloConfig
    function getConfigsForSolvency(
        address _borrower
    ) public view virtual override returns (ConfigData memory collateralConfig, ConfigData memory debtConfig) {
        address debtSilo = getDebtSilo(_borrower);

        if (debtSilo == address(0)) return (collateralConfig, debtConfig);

        address collateralSilo = borrowerCollateralSilo[_borrower];

        collateralConfig = getConfig(collateralSilo);
        debtConfig = getConfig(debtSilo);
    }

    /// @inheritdoc ISiloConfig
    function getConfigsForWithdraw(
        address _silo,
        address _depositOwner
    )
        external
        view
        virtual
        override
        returns (DepositConfig memory depositConfig, ConfigData memory collateralConfig, ConfigData memory debtConfig)
    {
        depositConfig = _getDepositConfig(_silo);
        (collateralConfig, debtConfig) = getConfigsForSolvency(_depositOwner);
    }

    /// @inheritdoc ISiloConfig
    function getConfigsForBorrow(
        address _debtSilo
    ) external view virtual override returns (ConfigData memory collateralConfig, ConfigData memory debtConfig) {
        address collateralSilo;

        if (_debtSilo == _silo0) {
            collateralSilo = _silo1;
        } else if (_debtSilo == _silo1) {
            collateralSilo = _silo0;
        } else {
            revert("WrongSilo");
        }

        collateralConfig = getConfig(collateralSilo);
        debtConfig = getConfig(_debtSilo);
    }

    /// @inheritdoc ISiloConfig
    function getSilos() external view virtual override returns (address silo0, address silo1) {
        return (_silo0, _silo1);
    }

    /// @inheritdoc ISiloConfig
    function getShareTokens(
        address _silo
    )
        external
        view
        virtual
        override
        returns (address protectedShareToken, address collateralShareToken, address debtShareToken)
    {
        if (_silo == _silo0) {
            return (_protectedShareToken0, _collateralShareToken0, _debtShareToken0);
        } else if (_silo == _silo1) {
            return (_protectedShareToken1, _collateralShareToken1, _debtShareToken1);
        } else {
            revert("WrongSilo");
        }
    }

    /// @inheritdoc ISiloConfig
    function getAssetForSilo(address _silo) external view virtual override returns (address asset) {
        if (_silo == _silo0) {
            return _token0;
        } else if (_silo == _silo1) {
            return _token1;
        } else {
            revert("WrongSilo");
        }
    }

    /// @inheritdoc ISiloConfig
    function getFeesWithAsset(
        address _silo
    )
        external
        view
        virtual
        override
        returns (uint256 daoFee, uint256 deployerFee, uint256 flashloanFee, address asset)
    {
        daoFee = _daoFee;
        deployerFee = _deployerFee;

        if (_silo == _silo0) {
            asset = _token0;
            flashloanFee = _flashloanFee0;
        } else if (_silo == _silo1) {
            asset = _token1;
            flashloanFee = _flashloanFee1;
        } else {
            revert("WrongSilo");
        }
    }

    /// @inheritdoc ISiloConfig
    function getCollateralShareTokenAndAsset(
        address _silo,
        ISilo.CollateralType _collateralType
    ) external view virtual override returns (address shareToken, address asset) {
        if (_silo == _silo0) {
            return
                _collateralType == ISilo.CollateralType.Collateral
                    ? (_collateralShareToken0, _token0)
                    : (_protectedShareToken0, _token0);
        } else if (_silo == _silo1) {
            return
                _collateralType == ISilo.CollateralType.Collateral
                    ? (_collateralShareToken1, _token1)
                    : (_protectedShareToken1, _token1);
        } else {
            revert("WrongSilo");
        }
    }

    /// @inheritdoc ISiloConfig
    function getDebtShareTokenAndAsset(
        address _silo
    ) external view virtual override returns (address shareToken, address asset) {
        if (_silo == _silo0) {
            return (_debtShareToken0, _token0);
        } else if (_silo == _silo1) {
            return (_debtShareToken1, _token1);
        } else {
            revert("WrongSilo");
        }
    }

    /// @inheritdoc ISiloConfig
    function getConfig(address _silo) public view virtual override returns (ConfigData memory config) {
        if (_silo == _silo0) {
            config = _silo0ConfigData();
        } else if (_silo == _silo1) {
            config = _silo1ConfigData();
        } else {
            revert("WrongSilo");
        }
    }

    /// @inheritdoc ISiloConfig
    function hasDebtInOtherSilo(
        address _thisSilo,
        address _borrower
    ) public view virtual override returns (bool hasDebt) {
        if (_thisSilo == _silo0) {
            hasDebt = _balanceOf(_debtShareToken1, _borrower) != 0;
        } else if (_thisSilo == _silo1) {
            hasDebt = _balanceOf(_debtShareToken0, _borrower) != 0;
        } else {
            revert("WrongSilo");
        }
    }

    /// @inheritdoc ISiloConfig
    function getDebtSilo(address _borrower) public view virtual override returns (address debtSilo) {
        uint256 debtBal0 = _balanceOf(_debtShareToken0, _borrower);
        uint256 debtBal1 = _balanceOf(_debtShareToken1, _borrower);

        require(debtBal0 == 0 || debtBal1 == 0, "DebtExistInOtherSilo");
        if (debtBal0 == 0 && debtBal1 == 0) return address(0);

        debtSilo = debtBal0 != 0 ? _silo0 : _silo1;
    }

    function turnOnReentrancyProtection() external virtual override {
        _reentrancyGuardEntered = true;
    }

    function turnOffReentrancyProtection() external virtual override {
        _reentrancyGuardEntered = false;
    }

    function reentrancyGuardEntered() external view virtual override returns (bool) {
        return _reentrancyGuardEntered;
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                   INTERNAL FUNCTIONS                                      //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    function _silo0ConfigData() internal view virtual returns (ConfigData memory config) {
        config = ConfigData({
            daoFee: _daoFee,
            deployerFee: _deployerFee,
            silo: _silo0,
            token: _token0,
            protectedShareToken: _protectedShareToken0,
            collateralShareToken: _collateralShareToken0,
            debtShareToken: _debtShareToken0,
            solvencyOracle: _solvencyOracle0,
            maxLtvOracle: _maxLtvOracle0,
            interestRateModel: _interestRateModel0,
            maxLtv: _maxLtv0,
            lt: _lt0,
            liquidationTargetLtv: _liquidationTargetLtv0,
            liquidationFee: _liquidationFee0,
            flashloanFee: _flashloanFee0,
            hookReceiver: _hookReceiver,
            callBeforeQuote: _callBeforeQuote0
        });
    }

    function _silo1ConfigData() internal view virtual returns (ConfigData memory config) {
        config = ConfigData({
            daoFee: _daoFee,
            deployerFee: _deployerFee,
            silo: _silo1,
            token: _token1,
            protectedShareToken: _protectedShareToken1,
            collateralShareToken: _collateralShareToken1,
            debtShareToken: _debtShareToken1,
            solvencyOracle: _solvencyOracle1,
            maxLtvOracle: _maxLtvOracle1,
            interestRateModel: _interestRateModel1,
            maxLtv: _maxLtv1,
            lt: _lt1,
            liquidationTargetLtv: _liquidationTargetLtv1,
            liquidationFee: _liquidationFee1,
            flashloanFee: _flashloanFee1,
            hookReceiver: _hookReceiver,
            callBeforeQuote: _callBeforeQuote1
        });
    }

    function _getDepositConfig(address _silo) internal view virtual returns (DepositConfig memory config) {
        if (_silo == _silo0) {
            config = DepositConfig({
                silo: _silo0,
                token: _token0,
                collateralShareToken: _collateralShareToken0,
                protectedShareToken: _protectedShareToken0,
                daoFee: _daoFee,
                deployerFee: _deployerFee,
                interestRateModel: _interestRateModel0
            });
        } else if (_silo == _silo1) {
            config = DepositConfig({
                silo: _silo1,
                token: _token1,
                collateralShareToken: _collateralShareToken1,
                protectedShareToken: _protectedShareToken1,
                daoFee: _daoFee,
                deployerFee: _deployerFee,
                interestRateModel: _interestRateModel1
            });
        } else {
            revert("WrongSilo");
        }
    }

    function _balanceOf(address _token, address _user) internal view virtual returns (uint256 balance) {
        // Handle zero address (debt share token might not be deployed in tests)
        if (_token == address(0)) return 0;
        balance = IERC20(_token).balanceOf(_user);
    }

    function _setSiloAsCollateralSilo(
        address _newCollateralSilo,
        address _borrower
    ) internal virtual returns (bool collateralSiloChanged) {
        // Check caller is a silo
        require(msg.sender == _silo0 || msg.sender == _silo1, "OnlySilo");

        if (borrowerCollateralSilo[_borrower] != _newCollateralSilo) {
            borrowerCollateralSilo[_borrower] = _newCollateralSilo;
            collateralSiloChanged = true;
        }
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////
    //                                   SETTER FUNCTIONS FOR TESTING                           //
    ///////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Update configuration for testing purposes
    function updateConfig(uint256 _siloIndex, ConfigData memory _configData) external {
        if (_siloIndex == 0) {
            _silo0 = _configData.silo;
            _token0 = _configData.token;
            _protectedShareToken0 = _configData.protectedShareToken;
            _collateralShareToken0 = _configData.silo;
            _debtShareToken0 = _configData.debtShareToken;
            _solvencyOracle0 = _configData.solvencyOracle;
            _maxLtvOracle0 = _configData.maxLtvOracle;
            _interestRateModel0 = _configData.interestRateModel;
            _maxLtv0 = _configData.maxLtv;
            _lt0 = _configData.lt;
            _liquidationTargetLtv0 = _configData.liquidationTargetLtv;
            _liquidationFee0 = _configData.liquidationFee;
            _flashloanFee0 = _configData.flashloanFee;
            _callBeforeQuote0 = _configData.callBeforeQuote;
        } else {
            _silo1 = _configData.silo;
            _token1 = _configData.token;
            _protectedShareToken1 = _configData.protectedShareToken;
            _collateralShareToken1 = _configData.silo;
            _debtShareToken1 = _configData.debtShareToken;
            _solvencyOracle1 = _configData.solvencyOracle;
            _maxLtvOracle1 = _configData.maxLtvOracle;
            _interestRateModel1 = _configData.interestRateModel;
            _maxLtv1 = _configData.maxLtv;
            _lt1 = _configData.lt;
            _liquidationTargetLtv1 = _configData.liquidationTargetLtv;
            _liquidationFee1 = _configData.liquidationFee;
            _flashloanFee1 = _configData.flashloanFee;
            _callBeforeQuote1 = _configData.callBeforeQuote;
        }
    }

    /// @notice Set borrower's collateral silo for testing
    function setBorrowerCollateralSilo(address _borrower, address _collateralSilo) external {
        borrowerCollateralSilo[_borrower] = _collateralSilo;
    }
}
