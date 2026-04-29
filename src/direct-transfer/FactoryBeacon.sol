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

    /**
     * @notice Canonical CreateX deployer used for CREATE3 deployments.
     * @dev Same address on every EVM chain where CreateX is deployed, which is what enables
     *      cross-chain deterministic DTA addresses.
     */
    ICreateX public constant CREATEX = ICreateX(0x1077f8ea07EA34D9F23BC39256BF234665FB391f);

    /**
     * @notice Emitted when a new DirectTransferAddress beacon proxy is deployed.
     * @param directTransferAddress Address of the freshly deployed BeaconProxy (the DTA).
     * @param userDestinationAddress The end-user configured as the DTA's `userDestinationAddress`.
     * @param organizationId Organization identifier mixed into the deployment salt; surfaced here
     *                       so indexers can correlate DTAs to an off-chain org.
     * @param inputToken The stablecoin the DTA accepts and forwards.
     */
    event BeaconProxyDeployed(
        address indexed userDestinationAddress,
        bytes32 indexed organizationId,
        address indexed inputToken,
        address boringVault,
        address directTransferAddress
    );

    /// @notice Thrown when `userDestinationAddress` is the zero address.
    error ZeroAddress();

    /// @notice Thrown when an upgrade's new implementation changes the boringVault referenced by the DCD.
    error BoringVaultMismatch(address expected, address actual);

    /// @notice Thrown when an upgrade's new implementation changes the input token.
    error TokenMismatch(address expected, address actual);

    /**
     * @param _implementation Initial DirectTransferAddress implementation this beacon serves.
     * @param _owner Address authorized to call upgradeTo() on the inherited UpgradeableBeacon.
     */
    constructor(address _implementation, address _owner) UpgradeableBeacon(_implementation, _owner) {
        DirectTransferAddress impl = DirectTransferAddress(_implementation);
        if (address(impl.token()) == address(0)) revert ZeroAddress();
        if (impl.DCD().boringVault() == address(0)) revert ZeroAddress();
    }

    /**
     * @notice Upgrades the beacon's implementation, enforcing that the new implementation's
     *         boringVault (via DCD) and input token match the current implementation's.
     * @dev Both values are mixed into the deterministic deployment salt, so changing either
     *      would orphan every previously deployed DTA from its computed address. Rejecting
     *      the upgrade on mismatch preserves the invariant that
     *      `computeDTAAddress(orgId, user)` remains stable across upgrades.
     * @param newImplementation The proposed new DirectTransferAddress implementation.
     */
    function upgradeTo(address newImplementation) public override onlyOwner {
        DirectTransferAddress currentImpl = DirectTransferAddress(implementation());
        address currentBoringVault = currentImpl.DCD().boringVault();
        address currentToken = address(currentImpl.token());

        DirectTransferAddress nextImpl = DirectTransferAddress(newImplementation);
        address nextBoringVault = nextImpl.DCD().boringVault();
        address nextToken = address(nextImpl.token());

        if (nextBoringVault != currentBoringVault) revert BoringVaultMismatch(currentBoringVault, nextBoringVault);
        if (nextToken != currentToken) revert TokenMismatch(currentToken, nextToken);

        super.upgradeTo(newImplementation);
    }

    /**
     * @notice Deploys a DirectTransferAddress beacon proxy at a deterministic address via CreateX.
     * @dev The beacon for the new proxy is always this contract, and the salt disables CreateX's
     *      cross-chain redeploy protection so identical inputs produce the same address on every chain.
     *      `inputToken` is the implementation's `token` immutable; `boringVault` is read through the
     *      implementation's DCD. Initializer calldata is constructed internally as
     *      `DirectTransferAddress.initialize(userDestinationAddress)` and executed via delegatecall
     *      during proxy construction, so `msg.sender` of `initialize` is the proxy itself.
     *      Callers relying on cross-chain determinism MUST ensure this factory was deployed to the
     *      same address on each target chain.
     * @param organizationId Organization identifier as bytes32, typically a UUID left-padded to 32
     *                       bytes; used only as salt entropy.
     *                       Example:
     *                       Input: "700768ae-c71d-42cc-9ff9-13b777d6d379"
     *                       Output: "0x00000000000000000000000000000000700768aec71d42cc9ff913b777d6d379"
     * @param userDestinationAddress Canonical end-user identity included in the deployment salt and event,
     *                               and set as the proxy's `userDestinationAddress` via the internally-constructed
     *                               initializer.
     * @return dta The deployed BeaconProxy address.
     */
    function deployBeaconProxy(bytes32 organizationId, address userDestinationAddress) external returns (address dta) {
        if (userDestinationAddress == address(0)) revert ZeroAddress();

        DirectTransferAddress impl = DirectTransferAddress(implementation());
        address boringVault = impl.DCD().boringVault();
        address inputToken = address(impl.token());

        bytes memory initData =
            abi.encodeWithSelector(DirectTransferAddress.initialize.selector, userDestinationAddress);
        bytes memory creationCode =
            abi.encodePacked(type(BeaconProxy).creationCode, abi.encode(address(this), initData));
        bytes32 salt = _makeDTASalt(boringVault, organizationId, userDestinationAddress, inputToken);
        dta = CREATEX.deployCreate3(salt, creationCode);

        emit BeaconProxyDeployed(userDestinationAddress, organizationId, inputToken, boringVault, dta);
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
     * @return The address at which the DTA will be (or has been) deployed for the given inputs.
     */
    function computeDTAAddress(bytes32 organizationId, address userDestinationAddress) external view returns (address) {
        DirectTransferAddress impl = DirectTransferAddress(implementation());
        address boringVault = impl.DCD().boringVault();
        address inputToken = address(impl.token());

        bytes32 salt = _makeDTASalt(boringVault, organizationId, userDestinationAddress, inputToken);
        bytes32 guardedSalt = keccak256(abi.encode(address(this), salt));
        return CREATEX.computeCreate3Address(guardedSalt, address(CREATEX));
    }

    /**
     * @notice Computes the deterministic CreateX salt for a DTA deployment.
     * @return The assembled 32-byte salt to pass to CREATEX.deployCreate3.
     */
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
        bytes1 crosschainProtectionFlag = bytes1(0x00);
        bytes32 nameEntropyHash =
            keccak256(abi.encodePacked(boringVault, organizationId, userDestinationAddress, inputToken));
        bytes11 nameEntropyHash11 = bytes11(nameEntropyHash);
        return bytes32(abi.encodePacked(address(this), crosschainProtectionFlag, nameEntropyHash11));
    }

}
