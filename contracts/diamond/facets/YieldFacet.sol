// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Modifiers } from '../libs/LibAppStorage.sol';
import { LibToken } from '../libs/LibToken.sol';
import { LibSwap } from '../libs/LibSwap.sol';
import { LibReward } from '../libs/LibReward.sol';
import { LibVault } from '../libs/LibVault.sol';
import { IERC4626 } from '../interfaces/IERC4626.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

/**

    █▀▀ █▀█ █▀▀ █
    █▄▄ █▄█ █▀░ █

    @author Sam Goodenough, The Stoa Corporation Ltd.
    @title  Yield Facet
    @notice Provides logic for distributing and managing yield.
 */

contract YieldFacet is Modifiers {

    /*//////////////////////////////////////////////////////////////
                            Yield Distribution
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Syncs cofi token supply to reflect vault earnings.
     * @param _cofi The cofi token to distribute yield earnings for.
     */
    function rebase(
        address _cofi
    )   external
        returns (uint256 assets, uint256 yield, uint256 shareYield)
    {
        if (s.rebasePublic[_cofi] == 0)
            require(
                s.isUpkeep[msg.sender] == 1 || s.isAdmin[msg.sender] == 1,
                'YieldFacet: Caller not Upkeep or Admin'
            );
        return LibToken._poke(_cofi);
    }

    /*//////////////////////////////////////////////////////////////
                            Asset Migration
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Migrates assets to '_newVault'.
     * @dev Ensure that a buffer of the relevant underlying token resides at this contract
     *      before executing to account for slippage.
     * @param _cofi     The cofi token to migrate underlying tokens for.
     * @param _newVault The new ERC4626 vault.
     */
    function migrate(
        address _cofi,
        address _newVault
    )   external
        returns (bool)
    {
        // Pull funds from old vault.
        uint256 assets = IERC4626(s.vault[_cofi]).redeem(
            IERC20(s.vault[_cofi]).balanceOf(address(this)),
            address(this),
            address(this)
        );

        /**
         * @notice Logic to switch underlying token if new vault accepts another asset.
         * @dev Need to ensure that (A) swap params have been set and;
         * @dev (B) _to asset's decimals have been set and;
         * @dev (C) 'buffer' is set for new underlying and resides at this address and;
         * @dev (D) 'harvestable' bool is indicated for new vault if required.
         */
        if (IERC4626(s.vault[_cofi]).asset() != IERC4626(_newVault).asset()) {
            assets = LibSwap._swapERC20ForERC20(
                assets,
                IERC4626(s.vault[_cofi]).asset(),
                IERC4626(_newVault).asset(),
                address(this)
            );
            // Update underlying for cofi token.
            s.underlying[_cofi] = IERC4626(_newVault).asset();
        }

        // Approve '_newVault' spend for this contract.
        SafeERC20.safeApprove(
            IERC20(IERC4626(_newVault).asset()),
            _newVault,
            assets + s.buffer[s.underlying[_cofi]]
        );

        // Deploy funds to new vault.
        LibVault._wrap(
            assets + s.buffer[s.underlying[_cofi]],
            _newVault
        );

        require(
            /// @dev No need to convert decimals as both values denominated in same asset.
            assets <= LibVault._totalValue(_newVault),
            'YieldFacet: Vault migration slippage exceeded'
        );
        emit LibVault.VaultMigration(
            _cofi,
            s.vault[_cofi],
            _newVault,
            assets,
            LibVault._totalValue(_newVault)
        );

        s.vault[_cofi] = _newVault; // Update vault for cofi token.

        LibToken._poke(_cofi); // Sync cofi token supply to assets in vault.

        return true;
    }

    /*//////////////////////////////////////////////////////////////
                            Admin - Setters
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev The buffer is an amount of underlying that resides at this contract for the purpose
     *      of ensuring a successful migration. This is because a rebase must execute to "sync"
     *      balances, which can only occur if the new supply is greater than the previous supply.
     *      Because withdrawals may incur slippage, therefore, need to overcome this.
     */
    function setBuffer(
        address _underlying,
        uint256 _buffer
    )   external
        onlyAdmin
        returns (bool)
    {
        s.buffer[_underlying] = _buffer;
        return true;
    }

    function setDecimals(
        address _underlying,
        uint8   _decimals
    )   external
        returns (bool)
    {
        s.decimals[_underlying] = _decimals;
        return true;
    }

    /// @dev Only for setting up a new cofi token. 'migrateVault()' must be used otherwise.
    function setVault(
        address _cofi,
        address _vault
    )   external
        onlyAdmin
        returns (bool)
    {
        require(
            s.vault[_cofi] == address(0),
            'YieldFacet: COFI token must not already link with a vault'
        );
        s.vault[_cofi] = _vault;
        return true;
    }

    function setRebasePublic(
        address _cofi,
        uint8   _enabled
    )   external
        onlyAdmin
        returns (bool)
    {
        s.rebasePublic[_cofi] = _enabled;
        return true;
    }

    function setHarvestable(
        address _vault,
        uint8   _enabled
    )   external
        onlyAdmin
        returns (bool)
    {
        s.harvestable[_vault] = _enabled;
        return true;
    }

    /// @notice Ops this contract into receiving yield on holding of cofi tokens.
    function rebaseOptIn(
        address _cofi
    )   external
        onlyAdmin
        returns (bool)
    {
        LibToken._rebaseOptIn(_cofi);
        return true;
    }

    function rebaseOptOut(
        address _cofi
    )   external
        onlyAdmin
        returns (bool)
    {
        LibToken._rebaseOptOut(_cofi);
        return true;
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN - GETTERS
    //////////////////////////////////////////////////////////////*/

    function getBuffer(
        address _cofi
    )   external
        view
        returns (uint256)
    {
        return s.buffer[_cofi];
    }

    function getRebasePublic(
        address _co
    )   external
        view
        returns (uint8)
    {
        return s.rebasePublic[_co];
    }

    function getHarvestable(
        address _vault
    )   external
        view
        returns (uint8)
    {
        return s.harvestable[_vault];
    }

    function getDecimals(
        address _underlying
    )   external view
        returns (uint8)
    {
        return s.decimals[_underlying];
    }
}