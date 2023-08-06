// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { AppStorage, LibAppStorage } from './LibAppStorage.sol';
import { LibVault } from './LibVault.sol';
import { PercentageMath } from './external/PercentageMath.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import { ICOFIToken } from '.././interfaces/ICOFIToken.sol';
import 'contracts/token/utils/StableMath.sol';

library LibToken {
    using PercentageMath for uint256;
    using StableMath for uint256;

    /// @notice Emitted when a transfer operation is executed.
    ///
    /// @param  asset           The asset transferred (underlying, share, or cofi token).
    /// @param  amount          The amount transferred.
    /// @param  transferFrom    The account the asset was transferred from.
    /// @param  recipient       The recipient of the transfer.
    event Transfer(address indexed asset, uint256 amount, address indexed transferFrom, address indexed recipient);

    /// @notice Emitted when a cofi token is minted.
    ///
    /// @param  cofi    The address of the minted cofi token.
    /// @param  amount  The amount of fis minted.
    /// @param  to      The recipient of the minted fis.
    event Mint(address indexed cofi, uint256 amount, address indexed to);

    /// @notice Emitted when a cofi token is burned.
    ///
    /// @param  cofi    The address of the burned fi.
    /// @param  amount  The amount of fis burned.
    /// @param  from    The account burned from.
    event Burn(address indexed cofi, uint256 amount, address indexed from);

    /// @notice Emitted when the total supply of a cofi token is updated.
    ///
    /// @param  cofi    The cofi token with updated supply.
    /// @param  assets  The new total supply.
    /// @param  yield   The amount of yield added.
    /// @param  rCPT    Rebasing credits per token of FiToken.sol contract (used to calc interest rate).
    /// @param  fee     The service fee captured - a share of the yield.
    event TotalSupplyUpdated(address indexed cofi, uint256 assets, uint256 yield, uint256 rCPT, uint256 fee);

    /// @notice Emitted when a deposit action is executed.
    ///
    /// @param  asset       The asset deposited (e.g., USDC).
    /// @param  amount      The amount deposited.
    /// @param  depositFrom The account assets were transferred from.
    /// @param  fee         The mint fee captured.
    event Deposit(address indexed asset, uint256 amount, address indexed depositFrom, uint256 fee);

    /// @notice Emitted when a withdrawal action is executed.
    ///
    /// @param  asset       The asset being withdrawn (e.g., USDC).
    /// @param  amount      The amount withdrawn.
    /// @param  depositFrom The account cofi tokens were transferred from.
    /// @param  fee         The redeem fee captured.
    event Withdraw(address indexed asset, uint256 amount, address indexed depositFrom, uint256 fee);

    /// @notice Executes a transferFrom operation in the context of COFI.
    ///
    /// @param  _asset      The asset to transfer.
    /// @param  _amount     The amount to transfer.
    /// @param  _sender     The account to transfer from, must have approved spender.
    /// @param  _recipient  The recipient of the transfer.
    function _transferFrom(
        address _asset,
        uint256 _amount,
        address _sender,
        address _recipient
    )   internal {

        SafeERC20.safeTransferFrom(
            IERC20(_asset),
            _sender,
            _recipient,
            _amount
        );
        emit Transfer(_asset, _amount, _sender, _recipient);
    }

    /// @notice Executes a transfer operation in the context of Stoa.
    ///
    /// @param  _asset      The asset to transfer.
    /// @param  _amount     The amount to transfer.
    /// @param  _recipient  The recipient of the transfer.
    function _transfer(
        address _asset,
        uint256 _amount,
        address _recipient
    ) internal {

        SafeERC20.safeTransfer(
            IERC20(_asset),
            _recipient,
            _amount
        );
        emit Transfer(_asset, _amount, address(this), _recipient);
    }

    /// @notice Executes a mint operation in the context of COFI.
    ///
    /// @param  _cofi   The cofi token to mint.
    /// @param  _to     The account to mint to.
    /// @param  _amount The amount of cofi tokens to mint.
    function _mint(
        address _cofi,
        address _to,
        uint256 _amount
    ) internal {

        ICOFIToken(_cofi).mint(_to, _amount);
        emit Mint(_cofi, _amount, _to);
    }


    /// @notice Executes a mint operation and opts the receiver into rebases.
    ///
    /// @param  _cofi   The cofi token to mint.
    /// @param  _to     The account to mint to.
    /// @param  _amount The amount of cofi tokens to mint.
    function _mintOptIn(
        address _cofi,
        address _to,
        uint256 _amount
    ) internal {

        ICOFIToken(_cofi).mintOptIn(_to, _amount);
        emit Mint(_cofi, _amount, _to);
    }

    /// @notice Executes a burn operation in the context of COFI.
    ///
    /// @param  _cofi   The cofi token to burn.
    /// @param  _from   The account to burn from.
    /// @param  _amount The amount of fis to burn.
    function _burn(
        address _cofi,
        address _from,
        uint256 _amount
    ) internal {

        ICOFIToken(_cofi).burn(_from, _amount);
        emit Burn(_cofi, _amount, _from);
    }

    /// @notice Calls redeem operation on FiToken contract.
    /// @dev    Skips approval check.
    function _redeem(
        address _cofi,
        address _from,
        address _to,
        uint256 _amount
    ) internal {

        ICOFIToken(_cofi).redeem(_from, _to, _amount);
    }

    /// @notice Ensures the amount of cofi tokens are non-transferable from the account.
    ///
    /// @param _cofi    The cofi token to lock.
    /// @param _from    The account to lock for.
    /// @param _amount  The amount of cofi tokens to lock.
    function _lock(
        address _cofi,
        address _from,
        uint256 _amount
    ) internal {

        ICOFIToken(_cofi).lock(_from, _amount);
    }

    function _unlock(
        address _cofi,
        address _from,
        uint256 _amount
    ) internal {

        ICOFIToken(_cofi).unlock(_from, _amount);
    }

    /// @notice Function for updating cofi token supply relative to vault earnings.
    ///
    /// @param  _cofi The cofi token to distribute yield earnings for.
    function _poke(
        address _cofi
    )   internal
        returns (uint256 assets, uint256 yield, uint256 shareYield)
    {
        AppStorage storage s = LibAppStorage.diamondStorage();

        uint256 currentSupply = IERC20(_cofi).totalSupply();
        if (currentSupply == 0) {
            emit TotalSupplyUpdated(_cofi, 0, 0, 1e18, 0);
            return (0, 0, 0); 
        }
        // Preemptively harvest if necessary for vault.
        if (s.harvestable[s.vault[_cofi]] == 1) LibVault._harvest(_cofi);

        assets = _toCofiDecimals(_cofi, LibVault._totalValue(s.vault[_cofi]));
        if (assets > currentSupply) {

            yield = assets - currentSupply;

            shareYield = yield.percentMul(1e4 - s.serviceFee[_cofi]);

            _changeSupply(
                _cofi,
                currentSupply + shareYield,
                yield,
                yield - shareYield
            );
            if (yield - shareYield > 0)
                _mint(_cofi, s.feeCollector, yield - shareYield);
        } else {
            emit TotalSupplyUpdated(
                _cofi,
                assets,
                0,
                _getRebasingCreditsPerToken(_cofi),
                0
            );
            return (assets, 0, 0);
        }
    }

    /// @notice Updates the total supply of the cofi token.
    ///
    /// @dev    Will revert if the new supply < old supply.
    ///
    /// @param _cofi    The cofi token to change supply for.
    /// @param _amount  The new supply.
    /// @param _yield   The amount of yield accrued.
    /// @param _fee     The service fee captured.
    function _changeSupply(
        address _cofi,
        uint256 _amount,
        uint256 _yield,
        uint256 _fee
    ) internal {
        
        ICOFIToken(_cofi).changeSupply(_amount);
        emit TotalSupplyUpdated(
            _cofi,
            _amount,
            _yield,
            ICOFIToken(_cofi).rebasingCreditsPerTokenHighres(),
            _fee
        );
    }

    /// @notice Returns the rCPT for a given cofi token.
    ///
    /// @param _cofi The cofi token to enquire for.
    function _getRebasingCreditsPerToken(
        address _cofi
    ) internal view returns (uint256) {

        return ICOFIToken(_cofi).rebasingCreditsPerTokenHighres();
    }

    /// @notice Returns the mint fee for a given cofi token.
    ///
    /// @param  _cofi   The cofi token to mint.
    /// @param  _amount The amount of cofi tokens to mint.
    function _getMintFee(
        address _cofi,
        uint256 _amount
    ) internal view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();

        return _amount.percentMul(s.mintFee[_cofi]);
    }

    /// @notice Returns the redeem fee for a given cofi token.
    ///
    /// @param  _cofi   The cofi token to redeem.
    /// @param  _amount The amount of cofi tokens to redeem
    function _getRedeemFee(
        address _cofi,
        uint256 _amount
    ) internal view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();

        return _amount.percentMul(s.redeemFee[_cofi]);
    }

    /// @notice Opts contract into receiving rebases.
    ///
    /// @param  _cofi The cofi token to opt-in to rebases for.
    function _rebaseOptIn(
        address _cofi
    ) internal {

        ICOFIToken(_cofi).rebaseOptIn();
    }

    /// @notice Opts contract out of receiving rebases.
    ///
    /// @param  _cofi The cofi token to opt-out of rebases for.
    function _rebaseOptOut(
        address _cofi
    ) internal {
        
        ICOFIToken(_cofi).rebaseOptOut();
    }

    /// @notice Retrieves yield earned of fi for account.
    ///
    /// @param  _account    The account to enquire for.
    /// @param  _cofi       The cofi token to check account's yield for.
    function _getYieldEarned(
        address _account,
        address _cofi
    ) internal view returns (uint256) {
        
        return ICOFIToken(_cofi).getYieldEarned(_account);
    }

    /// @notice Represents an underlying token decimals in fi decimals.
    ///
    /// @param _cofi    Retrieves the underlying decimals from mapping.
    /// @param _amount  The amount of underlying to translate.
    function _toCofiDecimals(
        address _cofi,
        uint256 _amount
    ) internal view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();

        return _amount.scaleBy(18, uint256(s.decimals[s.underlying[_cofi]]));
    }

    /// @notice Represents a cofi token in its underlying decimals.
    ///
    /// @param _cofi    Retrieves the underlying decimals from mapping.
    /// @param _amount  The amount of underlying to translate.
    function _toUnderlyingDecimals(
        address _cofi,
        uint256 _amount
    ) internal view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();

        return _amount.scaleBy(uint256(s.decimals[s.underlying[_cofi]]), 18);
    }
}