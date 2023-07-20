// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Modifiers } from "../libs/LibAppStorage.sol";

/**

    █▀▀ █▀█ █▀▀ █
    █▄▄ █▄█ █▀░ █

    @author Sam Goodenough, The Stoa Corporation Ltd.
    @title  Access Facet
    @notice Admin functions for managing/viewing account roles.
 */

contract AccessFacet is Modifiers {

    /*//////////////////////////////////////////////////////////////
                            ADMIN - SETTERS
    //////////////////////////////////////////////////////////////*/

    function setWhitelist(
        address _account,
        uint8   _enabled
    )   external
        onlyWhitelister
        returns (bool)
    {

        s.isWhitelisted[_account] = _enabled;
        return true;
    }

    function setAdmin(
        address _account,
        uint8   _enabled
    )   external
        onlyAdmin
        returns (bool)
    {
        require(
            _account != s.owner || _account != s.backupOwner,
            "AccessFacet: Owners must retain admin status"
        );

        s.isAdmin[_account] = _enabled;
        return true;
    }

    function setUpkeep(
        address _account,
        uint8   _enabled
    )   external
        onlyAdmin
        returns (bool)
    {
        s.isUpkeep[_account] = _enabled;
        return true;
    }

    function setFeeCollector(
        address _account
    )   external
        onlyAdmin
        returns (bool)
    {
        s.feeCollector = _account;
        return true;
    }

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/

    function getWhitelistStatus(
        address _account
    )   external
        view
        returns (uint8)
    {
        return s.isWhitelisted[_account];
    }

    function getAdminStatus(
        address _account
    )   external
        view
        returns (uint8)
    {
        return s.isAdmin[_account];
    }

    function getWhitelisterStatus(
        address _account
    )   external
        view
        returns (uint8)
    {
        return s.isWhitelister[_account];
    }

    function getUpkeepStatus(
        address _account
    )   external
        view
        returns (uint8)
    {
        return s.isUpkeep[_account];
    }

    function getFeeCollector(
    )   external
        view
        returns (address)
    {
        return s.feeCollector;
    }
}