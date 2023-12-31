// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {CCIPReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {LinkTokenInterface} from "@chainlink/contracts/src/v0.8/interfaces/LinkTokenInterface.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {Withdraw} from "./utils/Withdraw.sol";
import {ERC20Token} from "../token/mock/ERC20Token.sol";
import "../diamond/interfaces/IERC4626.sol";
import "hardhat/console.sol";

/**
 * THIS IS AN EXAMPLE CONTRACT THAT USES HARDCODED VALUES FOR CLARITY.
 * THIS IS AN EXAMPLE CONTRACT THAT USES UN-AUDITED CODE.
 * DO NOT USE THIS CODE IN PRODUCTION.
 */
contract COFIBridgeEntry is Withdraw, CCIPReceiver {
    enum PayFeesIn {
        Native,
        LINK
    }

    address immutable i_link;

    event MessageSent(bytes32 messageId);
    event CallSuccessful();

    error InsufficientFee();
    error NotAuthorizedTransmitter();

    // Added bridge metadata
    bool public mandateFee;
    uint256 public gasLimit;

    // Testing
    address public testCofi;
    uint256 public pong;

    // COFI vars
    // E.g., coUSD => wcoUSD.
    mapping(address => IERC4626) public vault;
    // srcAsset => Chain Selector => destShare.
    mapping(address => mapping(uint64 => address)) public destShare;
    // destShare => srcAsset.
    mapping(address => address) public srcAsset;
    // Contract responsible for minting/burning shares on destination chain.
    mapping(uint64 => address) public receiver;

    // Access
    mapping(address => bool) public authorizedTransmitter;
    mapping(address => bool) public authorized;

    constructor(
        address _router,
        address _link,
        // Set initial destination params.
        address _cofi,
        address _vault,
        uint64 _destChainSelector,
        address _destShare,
        address _receiver
    ) CCIPReceiver(_router) {
        i_link = _link;
        LinkTokenInterface(i_link).approve(i_router, type(uint256).max);
        vault[_cofi] = IERC4626(_vault);
        destShare[_cofi][_destChainSelector] = _destShare;
        receiver[_destChainSelector] = _receiver;
        authorizedTransmitter[_receiver] = true;
        IERC20(_cofi).approve(_vault, type(uint256).max);
        testCofi = _cofi;
        mandateFee = true;
        gasLimit = 200_000;
        authorized[msg.sender] = true;
    }

    modifier onlyAuthorized() {
        require(authorized[msg.sender], "Caller not authorized");
        _;
    }

    receive() external payable {}

    /*//////////////////////////////////////////////////////////////
                            Admin Setters
    //////////////////////////////////////////////////////////////*/

    function setAuthorized(
        address _account,
        bool _authorized
    ) external onlyAuthorized {
        authorized[_account] = _authorized;
    }

    function setAuthorizedTransmitter(
        address _account,
        bool _authorized
    ) external onlyAuthorized {
        authorizedTransmitter[_account] = _authorized;
    }

    function setVault(
        address _cofi,
        address _vault
    ) external onlyAuthorized {
        vault[_cofi] = IERC4626(_vault);
        IERC20(_cofi).approve(_vault, type(uint256).max);
    }

    function setDestShare(
        address _cofi,
        uint64 _destChainSelector,
        address _destShare
    ) external onlyAuthorized {
        destShare[_cofi][_destChainSelector] = _destShare;
    }

    function setReceiver(
        uint64 _destChainSelector,
        address _receiver,
        bool _authorizedTransmitter
    ) external onlyAuthorized {
        receiver[_destChainSelector] = _receiver;
        authorizedTransmitter[_receiver] = _authorizedTransmitter;
    }

    function setMandateFee(
        bool _enabled
    ) external {
        mandateFee = _enabled;
    }

    function setGasLimit(
        uint256 _gasLimit
    ) external {
        gasLimit = _gasLimit;
    }

    /*//////////////////////////////////////////////////////////////
                            Transmitter
    //////////////////////////////////////////////////////////////*/

    function enter(
        address _cofi,
        uint64 _destChainSelector,
        uint256 _amount,
        address _destSharesReceiver
    ) external payable returns (uint256 shares) {
        if (mandateFee) {
            if (
                msg.value < getFeeETH(
                    _cofi,
                    _destChainSelector,
                    _amount,
                    _destSharesReceiver
                )
            ) revert InsufficientFee();
        }
        // Transfer COFI to this address.
        IERC20(_cofi).transferFrom(msg.sender, address(this), _amount);

        // Wrap COFI tokens.
        shares = vault[_cofi].deposit(_amount, address(this));

        // Mint corresponding shares on destination chain.
        _mint(
            _destChainSelector,
            destShare[_cofi][_destChainSelector],
            _destSharesReceiver,
            shares
        );
    }

    function _mint(
        uint64 _destChainSelector,
        address _share,
        address _recipient,
        uint256 _amount
    ) internal {
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(receiver[_destChainSelector]),
            data: abi.encodeWithSignature(
                "mint(address,address,uint256)",
                _share,
                _recipient,
                _amount
            ),
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: "",
            feeToken: address(0)
        });

        uint256 fee = IRouterClient(i_router).getFee(
            _destChainSelector,
            message
        );

        bytes32 messageId = IRouterClient(i_router).ccipSend{value: fee}(
            _destChainSelector,
            message
        );

        emit MessageSent(messageId);
    }

    function getFeeETH(
        address _cofi,
        uint64 _destChainSelector,
        uint256 _amount,
        address _destSharesReceiver
    ) public view returns (uint256 fee) {
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(receiver[_destChainSelector]),
            data: abi.encodeWithSignature(
                "mint(address,address,uint256)",
                destShare[_cofi][_destChainSelector],
                _destSharesReceiver,
                _amount
            ),
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV1({gasLimit: gasLimit, strict: false})),
            feeToken: address(0)
        });

        return IRouterClient(i_router).getFee(
            _destChainSelector,
            message
        );
    }

    /*//////////////////////////////////////////////////////////////
                                Receiver
    //////////////////////////////////////////////////////////////*/

    function redeem(
        address _cofi,
        uint256 _shares,
        address _assetsReceiver
    )   public
        // onlyAuthorized
        returns (uint256 assets) {
        assets = vault[_cofi].redeem(_shares, _assetsReceiver, address(this));
    }

    // To-do: Verify sender.
    function _ccipReceive(
        Client.Any2EVMMessage memory message
    ) internal override {
        address sender = abi.decode(message.sender, (address));
        if (!authorizedTransmitter[sender]) revert NotAuthorizedTransmitter();
        (bool success, ) = address(this).call(message.data);
        require(success);
        emit CallSuccessful();
    }

    /*//////////////////////////////////////////////////////////////
                    Testing - Transmitter & Receiver
    //////////////////////////////////////////////////////////////*/

    function doPing(
        uint256 _ping,
        address _receiver,
        uint64 _chainSelector
    ) external payable {
        if (mandateFee) {
            if (msg.value < getFeeETHPing(_ping, _receiver, _chainSelector)) {
                revert InsufficientFee();
            }
        }

        _doPing(_ping, _receiver, _chainSelector);
    }

    function _doPing(
        uint256 _ping,
        address _receiver,
        uint64 _chainSelector
    ) internal {
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(_receiver),
            data: abi.encodeWithSignature("doPing(uint256)", _ping),
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV1({gasLimit: gasLimit, strict: false})),
            feeToken: address(0)
        });

        uint256 fee = IRouterClient(i_router).getFee(
            _chainSelector,
            message
        );

        bytes32 messageId = IRouterClient(i_router).ccipSend{value: fee}(
            _chainSelector,
            message
        );

        emit MessageSent(messageId);
    }

    function getFeeETHPing(
        uint256 _pong,
        address _receiver,
        uint64 _chainSelector
    ) public view returns (uint256 fee) {
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(_receiver),
            data: abi.encodeWithSignature(
                "doPing(uint256)",
                _pong
            ),
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV1({gasLimit: gasLimit, strict: false})),
            feeToken: address(0)
        });

        return IRouterClient(i_router).getFee(
            _chainSelector,
            message
        );
    }

    function doPong(
        uint256 _pong
    ) public {
        pong = _pong;
    }

    /*//////////////////////////////////////////////////////////////
                            Testing - Local
    //////////////////////////////////////////////////////////////*/

    function getCofi(
        uint256 _amount
    ) external {
        ERC20Token(testCofi).mint(msg.sender, _amount);
    }

    function testWrap(
        uint256 _amount
    ) external returns (uint256 shares) {
        // Caller needs to provide spend approval before executing.
        IERC20(testCofi).transferFrom(msg.sender, address(this), _amount);

        // Shares rceived to this contract.
        return IERC4626(vault[testCofi]).deposit(_amount, address(this));
    }

    function testUnwrap(
        address _cofi,
        address _recipient,
        uint256 _amount
    ) external returns (uint256 assets) {
        // Shares reside at this contract.
        return IERC4626(vault[_cofi]).redeem(_amount, _recipient, address(this));
    }
}