// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { SimpleBeacon } from "src/direct-transfer/SimpleBeacon.sol";
import { SimpleBeaconProxy } from "src/direct-transfer/SimpleBeaconProxy.sol";
import { DirectTransferAddress1 } from "src/direct-transfer/DirectTransferAddress1.sol";
import { ICreateX } from "src/interfaces/ICreateX.sol";

/// @notice Dual-purpose Beacon and Factory contract. Holds implementation
/// logic by inheriting Beacon and adds ability to deploy new BeaconProxies.
contract FactoryBeacon is SimpleBeacon {

    ICreateX public constant CREATEX = ICreateX(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);

    event BeaconProxyDeployed(address indexed proxy, address indexed user, bytes32 salt);

    constructor(address _implementation, address _owner) SimpleBeacon(_implementation, _owner) { }

    /// @notice Deploys a DTA beacon proxy via CREATEX with a deterministic address.
    /// @dev The beacon is always this factory contract.
    /// @param organizationId Organization identifier as bytes32, typically a UUID hex string left-padded to 32 bytes.
    /// Example:
    /// import { Hex, size } from 'viem'
    /// const organizationId = "700768ae-c71d-42cc-9ff9-13b777d6d379"
    /// const organizationIdAsBytes32 = `0x${uuid.replaceAll('-', '').padStart(64, '0')}` as Hex
    /// invariant(size === 32)
    function deployBeaconProxy(
        address boringVault,
        bytes32 organizationId,
        address userDestinationAddress,
        address inputToken
    )
        external
        returns (address dta)
    {
        bytes32 salt = _makeDTASalt(boringVault, organizationId, userDestinationAddress, inputToken);
        // TODO: change selector to latest implementation's selector, so we can upgrade initializable params too.
        bytes memory initData =
            abi.encodeWithSelector(DirectTransferAddress1.initialize.selector, userDestinationAddress);
        bytes memory creationCode =
            abi.encodePacked(type(SimpleBeaconProxy).creationCode, abi.encode(address(this), initData));
        dta = CREATEX.deployCreate3(salt, creationCode);

        // TODO: add other salt components in here
        emit BeaconProxyDeployed(dta, userDestinationAddress, salt);
    }

    /// @notice Computes the expected DTA address without deploying.
    /// @dev Replicates CREATEX's _guard logic for (MsgSender, CrosschainProtected=true):
    ///      guardedSalt = keccak256(abi.encode(msg.sender, block.chainid, salt))
    function computeDTAAddress(
        address boringVault,
        bytes32 organizationId,
        address userDestinationAddress,
        address inputToken
    )
        public
        view
        returns (address)
    {
        bytes32 salt = _makeDTASalt(boringVault, organizationId, userDestinationAddress, inputToken);
        bytes32 guardedSalt = keccak256(abi.encode(address(this), block.chainid, salt));
        return CREATEX.computeCreate3Address(guardedSalt, address(CREATEX));
    }

    /// @notice Computes the deterministic salt for a DTA deployment.
    function _makeDTASalt(
        address boringVault,
        bytes32 organizationId,
        address userDestinationAddress,
        address inputToken
    )
        internal
        view
        returns (bytes32)
    {
        bytes1 crosschainProtectionFlag = bytes1(0x01);
        bytes32 nameEntropyHash =
            keccak256(abi.encodePacked(boringVault, organizationId, userDestinationAddress, inputToken));
        bytes11 nameEntropyHash11 = bytes11(nameEntropyHash);
        return bytes32(abi.encodePacked(address(this), crosschainProtectionFlag, nameEntropyHash11));
    }

}
