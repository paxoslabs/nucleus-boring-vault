// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { BeaconProxy } from "@openzeppelin-v5.0.1/contracts/proxy/beacon/BeaconProxy.sol";
import { UpgradeableBeacon } from "@openzeppelin-v5.0.1/contracts/proxy/beacon/UpgradeableBeacon.sol";

import { DirectTransferAddress } from "src/direct-transfer/DirectTransferAddress.sol";
import { ICreateX } from "src/interfaces/ICreateX.sol";

/**
 * @title FactoryBeacon
 * @notice Dual-purpose contract that is both the UpgradeableBeacon for every DirectTransferAddress
 *         proxy it spawns and the factory that deploys those proxies at deterministic,
 *         cross-chain-stable addresses.
 * @dev One FactoryBeacon serves one DirectTransferAddress implementation, pinned to one DCD and one
 *      stablecoin. Deployment uses CreateX's CREATE3 flow keyed on `msg.sender == this`, so the DTA
 *      address is a pure function of the inputs and this factory's address — identical on every chain.
 * @custom:security-contact security@paxoslabs.com
 */
contract FactoryBeacon is UpgradeableBeacon {

    /// @notice Canonical CreateX deployer used for CREATE3 deployments.
    /// @dev Same address on every EVM chain where CreateX is deployed, which is what enables
    /// cross-chain deterministic DTA addresses.
    ICreateX public constant CREATEX = ICreateX(0x1077f8ea07EA34D9F23BC39256BF234665FB391f);

    /**
     * @notice Emitted when a new DirectTransferAddress beacon proxy is deployed.
     * @param directTransferAddress Address of the freshly deployed BeaconProxy (the DTA).
     * @param userDestinationAddress The end-user configured as the DTA's `receiver`.
     * @param organizationId Organization identifier mixed into the deployment salt; surfaced here
     *                       so indexers can correlate DTAs to an off-chain org.
     * @param inputToken The stablecoin the DTA accepts and forwards.
     */
    event BeaconProxyDeployed(
        address directTransferAddress,
        address indexed userDestinationAddress,
        bytes32 indexed organizationId,
        address indexed inputToken
    );

    /// @notice Thrown when `userDestinationAddress` is the zero address.
    error ZeroAddress();

    /// @notice Thrown when `initData` is empty.
    error EmptyInitData();

    /// @param _implementation Initial DirectTransferAddress implementation this beacon serves; must
    /// already be deployed (UpgradeableBeacon enforces nonzero code length).
    /// @param _owner Address authorized to call upgradeTo() on the inherited UpgradeableBeacon.
    constructor(address _implementation, address _owner) UpgradeableBeacon(_implementation, _owner) { }

    /**
     * @notice Deploys a DirectTransferAddress beacon proxy at a deterministic address via CreateX.
     * @dev The beacon for the new proxy is always this contract, and the salt disables CreateX's
     *      cross-chain redeploy protection so identical inputs produce the same address on every chain.
     *      `boringVault` and `inputToken` are sourced from the current implementation's immutables.
     *      `initData` must be ABI-encoded calldata for the implementation's initializer.
     *      Initialization executes via delegatecall during proxy construction, so initializer logic
     *      must not assume `msg.sender` is an EOA.
     *      Callers relying on cross-chain determinism MUST ensure this factory was deployed to the
     *      same address on each target chain.
     * @param organizationId Organization identifier as bytes32, typically a UUID left-padded to 32
     *                       bytes; used only as salt entropy.
     *                       Example:
     *                       Input: "700768ae-c71d-42cc-9ff9-13b777d6d379"
     *                       Output: "0x00000000000000000000000000000000700768aec71d42cc9ff913b777d6d379"
     * @param userDestinationAddress Canonical end-user identity included in the deployment salt and event.
     * @param initData ABI-encoded initializer calldata for the current implementation.
     * @return dta The deployed BeaconProxy address — stable across chains for identical inputs.
     */
    function deployBeaconProxy(
        bytes32 organizationId,
        address userDestinationAddress,
        bytes calldata initData
    )
        external
        onlyOwner
        returns (address dta)
    {
        if (userDestinationAddress == address(0)) revert ZeroAddress();
        if (initData.length == 0) revert EmptyInitData();

        DirectTransferAddress impl = DirectTransferAddress(implementation());
        address boringVault = impl.DCD().boringVault();
        address inputToken = address(impl.token());

        bytes32 salt =
            _makeDTASalt(boringVault, organizationId, userDestinationAddress, inputToken, keccak256(initData));
        bytes memory creationCode =
            abi.encodePacked(type(BeaconProxy).creationCode, abi.encode(address(this), initData));
        dta = CREATEX.deployCreate3(salt, creationCode);

        emit BeaconProxyDeployed(dta, userDestinationAddress, organizationId, inputToken);
    }

    /**
     * @notice Computes the DTA address that `deployBeaconProxy` would produce for the given inputs,
     *         without deploying.
     * @dev Replicates CreateX's `_guard` logic for (MsgSender, CrosschainProtected=false):
     *      guardedSalt = keccak256(abi.encode(address(this), salt)).
     *      `boringVault` and `inputToken` are sourced from the current implementation's immutables,
     *      so this result can change across beacon upgrades.
     * @param organizationId Same meaning as in `deployBeaconProxy`.
     * @param userDestinationAddress Same meaning as in `deployBeaconProxy`.
     * @param initData Same meaning as in `deployBeaconProxy`.
     * @return The address at which the DTA will be (or has been) deployed for the given inputs.
     */
    function computeDTAAddress(
        bytes32 organizationId,
        address userDestinationAddress,
        bytes memory initData
    )
        public
        view
        returns (address)
    {
        DirectTransferAddress impl = DirectTransferAddress(implementation());
        address boringVault = impl.DCD().boringVault();
        address inputToken = address(impl.token());

        bytes32 salt =
            _makeDTASalt(boringVault, organizationId, userDestinationAddress, inputToken, keccak256(initData));
        bytes32 guardedSalt = keccak256(abi.encode(address(this), salt));
        return CREATEX.computeCreate3Address(guardedSalt, address(CREATEX));
    }

    /**
     * @notice Computes the deterministic CreateX salt for a DTA deployment.
     * @dev Salt layout (32 bytes): [0..19] address(this) binds salt to this factory; [20] 0x00
     *      disables CreateX's cross-chain redeploy protection; [21..31] 11 bytes of keccak256 over
     *      five entropy inputs provide per-DTA entropy (~2^88 collision resistance).
     * @return The assembled 32-byte salt to pass to CREATEX.deployCreate3.
     */
    function _makeDTASalt(
        address boringVault,
        bytes32 organizationId,
        address userDestinationAddress,
        address inputToken,
        bytes32 initDataHash
    )
        internal
        view
        returns (bytes32)
    {
        bytes1 crosschainProtectionFlag = bytes1(0x00);
        bytes32 nameEntropyHash =
            keccak256(abi.encodePacked(boringVault, organizationId, userDestinationAddress, inputToken, initDataHash));
        bytes11 nameEntropyHash11 = bytes11(nameEntropyHash);
        return bytes32(abi.encodePacked(address(this), crosschainProtectionFlag, nameEntropyHash11));
    }

}
