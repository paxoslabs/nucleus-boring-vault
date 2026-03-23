// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { CrossChainTellerBase, BridgeData } from "./CrossChainTellerBase.sol";
import { Chain } from "src/interfaces/ICrossChainTypes.sol";

error MultiChainTellerBase_MessagesNotAllowedFrom(uint32 chainSelector);
error MultiChainTellerBase_MessagesNotAllowedFromSender(uint256 chainSelector, address sender);
error MultiChainTellerBase_MessagesNotAllowedTo(uint256 chainSelector);
error MultiChainTellerBase_TargetTellerIsZeroAddress();
error MultiChainTellerBase_DestinationChainReceiverIsZeroAddress();
error MultiChainTellerBase_ZeroMessageGasLimit();
error MultiChainTellerBase_GasLimitExceeded();
error MultiChainTellerBase_GasTooLow();

/**
 * @title MultiChainTellerBase
 * @notice Base contract for the MultiChainTellers,
 * We've noticed that many bridge options are L1 -> L2 only, which are quite simple IE Optimism Messenger
 * While others like LZ that can contact many bridges, contain lots of additional complexity to manage the configuration
 * for these chains
 * To keep this separated we are using this MultiChain syntax for the > 2 chain messaging while only CrossChain for 2
 * chain messengers like OP
 */
abstract contract MultiChainTellerBase is CrossChainTellerBase {

    event ChainAdded(
        uint256 chainSelector,
        bool allowMessagesFrom,
        bool allowMessagesTo,
        address targetTeller,
        uint64 messageGasLimit,
        uint64 messageGasMin
    );
    event ChainRemoved(uint256 chainSelector);
    event ChainAllowMessagesFrom(uint256 chainSelector, address targetTeller);
    event ChainAllowMessagesTo(uint256 chainSelector, address targetTeller);
    event ChainStopMessagesFrom(uint256 chainSelector);
    event ChainStopMessagesTo(uint256 chainSelector);
    event ChainSetGasLimit(uint256 chainSelector, uint64 messageGasLimit);

    mapping(uint32 => Chain) public selectorToChains;

    constructor(address _owner, address _vault, address _accountant)
        CrossChainTellerBase(_owner, _vault, _accountant)
    { }

    /**
     * @dev Callable by OWNER_ROLE.
     * @notice adds an acceptable chain to bridge to
     * @param chainSelector chainSelector of chain
     * @param allowMessagesFrom allow messages from this chain
     * @param allowMessagesTo allow messages to the chain
     * @param targetTeller address of the target teller on this chain
     * @param messageGasLimit to pass to bridge
     * @param messageGasMin to require a minimum provided gas for this chain
     */
    function addChain(
        uint32 chainSelector,
        bool allowMessagesFrom,
        bool allowMessagesTo,
        address targetTeller,
        uint64 messageGasLimit,
        uint64 messageGasMin
    )
        external
        requiresAuth
    {
        if (allowMessagesTo && messageGasLimit == 0) {
            revert MultiChainTellerBase_ZeroMessageGasLimit();
        }
        selectorToChains[chainSelector] =
            Chain(allowMessagesFrom, allowMessagesTo, targetTeller, messageGasLimit, messageGasMin);

        emit ChainAdded(chainSelector, allowMessagesFrom, allowMessagesTo, targetTeller, messageGasLimit, messageGasMin);
    }

    /**
     * @dev Callable by OWNER_ROLE.
     * @notice block messages from a particular chain
     * @param chainSelector of chain
     */
    function stopMessagesFromChain(uint32 chainSelector) external requiresAuth {
        Chain storage chain = selectorToChains[chainSelector];
        chain.allowMessagesFrom = false;

        emit ChainStopMessagesFrom(chainSelector);
    }

    /**
     * @dev Callable by OWNER_ROLE.
     * @notice allow messages from a particular chain
     * @param chainSelector of chain
     */
    function allowMessagesFromChain(uint32 chainSelector, address targetTeller) external requiresAuth {
        Chain storage chain = selectorToChains[chainSelector];
        chain.allowMessagesFrom = true;
        chain.targetTeller = targetTeller;

        emit ChainAllowMessagesFrom(chainSelector, targetTeller);
    }

    /**
     * @dev Callable by OWNER_ROLE.
     * @notice Remove a chain from the teller.
     * @dev Callable by OWNER_ROLE.
     */
    function removeChain(uint32 chainSelector) external requiresAuth {
        delete selectorToChains[chainSelector];

        emit ChainRemoved(chainSelector);
    }

    /**
     * @dev Callable by OWNER_ROLE.
     * @notice Allow messages to a chain.
     */
    function allowMessagesToChain(
        uint32 chainSelector,
        address targetTeller,
        uint64 messageGasLimit
    )
        external
        requiresAuth
    {
        if (messageGasLimit == 0) {
            revert MultiChainTellerBase_ZeroMessageGasLimit();
        }
        Chain storage chain = selectorToChains[chainSelector];
        chain.allowMessagesTo = true;
        chain.targetTeller = targetTeller;
        chain.messageGasLimit = messageGasLimit;

        emit ChainAllowMessagesTo(chainSelector, targetTeller);
    }

    /**
     * @dev Callable by OWNER_ROLE.
     * @notice Stop messages to a chain.
     */
    function stopMessagesToChain(uint32 chainSelector) external requiresAuth {
        Chain storage chain = selectorToChains[chainSelector];
        chain.allowMessagesTo = false;

        emit ChainStopMessagesTo(chainSelector);
    }

    /**
     * @dev Callable by OWNER_ROLE.
     * @notice Set the gas limit for messages to a chain.
     */
    function setChainGasLimit(uint32 chainSelector, uint64 messageGasLimit) external requiresAuth {
        if (messageGasLimit == 0) {
            revert MultiChainTellerBase_ZeroMessageGasLimit();
        }
        Chain storage chain = selectorToChains[chainSelector];
        chain.messageGasLimit = messageGasLimit;

        emit ChainSetGasLimit(chainSelector, messageGasLimit);
    }

    /**
     * @notice override beforeBridge to check Chain struct
     * @param data bridge data
     */
    function _beforeBridge(BridgeData calldata data) internal override {
        Chain memory chain = selectorToChains[data.chainSelector];

        if (!chain.allowMessagesTo) {
            revert MultiChainTellerBase_MessagesNotAllowedTo(data.chainSelector);
        }

        if (chain.targetTeller == address(0)) {
            revert MultiChainTellerBase_TargetTellerIsZeroAddress();
        }

        if (data.destinationChainReceiver == address(0)) {
            revert MultiChainTellerBase_DestinationChainReceiverIsZeroAddress();
        }

        if (data.messageGas > chain.messageGasLimit) {
            revert MultiChainTellerBase_GasLimitExceeded();
        }

        if (data.messageGas < chain.minimumMessageGas) {
            revert MultiChainTellerBase_GasTooLow();
        }
    }

}
