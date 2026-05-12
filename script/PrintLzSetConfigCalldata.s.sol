// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { Script } from "@forge-std/Script.sol";
import { console2 } from "@forge-std/console2.sol";
import {
    IMessageLibManager,
    SetConfigParam
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLibManager.sol";

/// @notice Prints the `to` address and calldata required to call `setConfig` on a LayerZero V2
///         endpoint for a given teller/OApp. Intended to produce a multisig transaction payload;
///         this script does NOT broadcast any transactions. Mirrors the ULN config encoding used
///         in `script/deploy/single/06b_DeployMultiChainLayerZeroTellerWithMultiAssetSupport.s.sol`.
/// @dev    The send and receive libraries are fetched from the endpoint at runtime, so this
///         script must be run against an RPC. Modify the inline constants and the DVN arrays in
///         `run()` below, then execute with:
///         `forge script script/PrintLzSetConfigCalldata.s.sol --rpc-url <rpc> -vvv`
contract PrintLzSetConfigCalldata is Script {

    // Must match the struct used by LayerZero's ULN302 message library.
    struct UlnConfig {
        uint64 confirmations;
        uint8 requiredDVNCount;
        uint8 optionalDVNCount;
        uint8 optionalDVNThreshold;
        address[] requiredDVNs;
        address[] optionalDVNs;
    }

    // LayerZero ULN config type identifier.
    uint32 internal constant ULN_CONFIG_TYPE = 2;

    // =======================================================================
    //                     FILL IN THESE VALUES BEFORE RUNNING
    // =======================================================================

    // Teller / OApp address whose config is being set. This is the address the
    // endpoint will treat as the OApp when applying the ULN config.
    address internal constant TELLER = 0xF3B8fe425895825bD92c1C6F44F21Ab30Cc2eed7;

    // LayerZero V2 endpoint on the chain where this config will be applied.
    address internal constant LZ_ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;

    // Endpoint ID of the remote peer chain this config applies to.
    uint32 internal constant PEER_EID = 30_101;

    // Number of block confirmations required before a DVN verifies.
    uint64 internal constant DVN_BLOCK_CONFIRMATIONS = 15;

    // Number of optional DVNs that must verify (0 if no optional DVNs).
    uint8 internal constant OPTIONAL_DVN_THRESHOLD = 0;

    // =======================================================================

    function run() public view {
        // Fill in required DVN addresses (unsorted is fine, we sort below).
        address[] memory requiredDvns = new address[](3);
        requiredDvns[0] = 0x9e059a54699a285714207b43B055483E78FAac25; // lz labs
        requiredDvns[1] = 0xc2A0C36f5939A14966705c7Cec813163FaEEa1F0; // Deutsche Telekom
        requiredDvns[2] = 0xcd37CA043f8479064e10635020c65FfC005d36f6; // Nethermind

        // Fill in optional DVN addresses (unsorted is fine, we sort below).
        address[] memory optionalDvns = new address[](0);

        require(DVN_BLOCK_CONFIRMATIONS != 0, "dvn block confirmations 0");
        require(requiredDvns.length != 0, "no required dvns");
        require(TELLER != address(0), "TELLER not set");
        require(LZ_ENDPOINT != address(0), "LZ_ENDPOINT not set");
        require(PEER_EID != 0, "PEER_EID not set");

        // Fetch the libraries currently in effect for this teller+peer from the endpoint.
        // `getSendLibrary` / `getReceiveLibrary` return the teller-specific override if one
        // has been set, otherwise the chain default. Requires running against an RPC.
        IMessageLibManager endpoint = IMessageLibManager(LZ_ENDPOINT);
        address sendLib = endpoint.getSendLibrary(TELLER, PEER_EID);
        (address receiveLib,) = endpoint.getReceiveLibrary(TELLER, PEER_EID);
        require(sendLib != address(0), "sendLib = 0, check PEER_EID");
        require(receiveLib != address(0), "receiveLib = 0, check PEER_EID");

        // DVNs must be in ascending order when encoded for the ULN config.
        requiredDvns = _sortAddresses(requiredDvns);
        optionalDvns = _sortAddresses(optionalDvns);

        bytes memory ulnConfigBytes = abi.encode(
            UlnConfig(
                DVN_BLOCK_CONFIRMATIONS,
                uint8(requiredDvns.length),
                uint8(optionalDvns.length),
                OPTIONAL_DVN_THRESHOLD,
                requiredDvns,
                optionalDvns
            )
        );

        SetConfigParam[] memory setConfigParams = new SetConfigParam[](1);
        setConfigParams[0] = SetConfigParam(PEER_EID, ULN_CONFIG_TYPE, ulnConfigBytes);

        console2.log("================================================================");
        console2.log("Multisig transaction(s) to set LayerZero ULN config");
        console2.log("================================================================");
        console2.log("OApp (teller):", TELLER);
        console2.log("Peer EID:     ", PEER_EID);
        console2.log("");

        bytes memory sendCalldata = abi.encodeCall(IMessageLibManager.setConfig, (TELLER, sendLib, setConfigParams));
        console2.log("--- SEND LIB CONFIG ---");
        console2.log("to:      ", LZ_ENDPOINT);
        console2.log("value:    0");
        console2.log("lib:     ", sendLib);
        console2.log("calldata:");
        console2.logBytes(sendCalldata);
        console2.log("");

        bytes memory receiveCalldata =
            abi.encodeCall(IMessageLibManager.setConfig, (TELLER, receiveLib, setConfigParams));
        console2.log("--- RECEIVE LIB CONFIG ---");
        console2.log("to:      ", LZ_ENDPOINT);
        console2.log("value:    0");
        console2.log("lib:     ", receiveLib);
        console2.log("calldata:");
        console2.logBytes(receiveCalldata);
        console2.log("");

        console2.log("================================================================");
        console2.log("NOTE: msg.sender for these calls must be the delegate set on the");
        console2.log("teller (typically the multisig after setDelegate has been called).");
        console2.log("================================================================");
    }

    function _sortAddresses(address[] memory addresses) internal pure returns (address[] memory) {
        uint256 length = addresses.length;
        if (length < 2) return addresses;

        for (uint256 i; i < length - 1; ++i) {
            for (uint256 j; j < length - i - 1; ++j) {
                if (addresses[j] > addresses[j + 1]) {
                    address temp = addresses[j];
                    addresses[j] = addresses[j + 1];
                    addresses[j + 1] = temp;
                }
            }
        }
        return addresses;
    }

}
