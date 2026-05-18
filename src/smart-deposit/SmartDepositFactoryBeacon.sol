// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { BeaconProxy } from "@openzeppelin-v5.0.1/contracts/proxy/beacon/BeaconProxy.sol";
import { UpgradeableBeacon } from "@openzeppelin-v5.0.1/contracts/proxy/beacon/UpgradeableBeacon.sol";

import { SmartDepositAddress } from "src/smart-deposit/SmartDepositAddress.sol";
import { ICreateX } from "src/interfaces/ICreateX.sol";

/**
 * @title SmartDepositFactoryBeacon
 * @notice Dual-purpose contract that is both the UpgradeableBeacon for every SmartDepositAddress
 *         proxy it spawns and the factory that deploys those proxies at deterministic,
 *         cross-chain-stable addresses.
 * @dev One SmartDepositFactoryBeacon serves one SmartDepositAddress implementation with one immutable DCD (and
 *      therefore one BoringVault). If necessary, DCD can be upgraded by deploying a new
 *      implementation contract. Deployment uses CreateX's CREATE3 flow keyed on
 *      `msg.sender == this`, so the SDA address is a pure function
 *      of the inputs and this factory's address — identical on every chain.
 * @custom:security-contact security@paxoslabs.com
 */
contract SmartDepositFactoryBeacon is UpgradeableBeacon {

    /**
     * @notice Canonical CreateX deployer used for CREATE3 deployments.
     * @dev Same address on every EVM chain where CreateX is deployed, which is what enables
     *      cross-chain deterministic SDA addresses.
     */
    ICreateX public constant CREATEX = ICreateX(0x1077f8ea07EA34D9F23BC39256BF234665FB391f);

    /**
     * @notice Emitted when a new SmartDepositAddress beacon proxy is deployed.
     * @param userDestinationAddress The end-user configured as the SDA's `userDestinationAddress`.
     * @param organizationId Organization identifier mixed into the deployment salt; surfaced here
     *                       so indexers can correlate SDAs to an off-chain org.
     * @param inputToken The stablecoin the SDA accepts and forwards.
     * @param boringVault The vault whose shares will be sent to the userDestinationAddress.
     * @param smartDepositAddress Address of the freshly deployed BeaconProxy (the SDA).
     */
    event BeaconProxyDeployed(
        address indexed userDestinationAddress,
        bytes32 indexed organizationId,
        address indexed inputToken,
        address boringVault,
        address smartDepositAddress
    );

    /// @notice Thrown when a required address argument is the zero address.
    error ZeroAddress();

    /// @notice Thrown when `inputToken` has no contract code at the given address.
    error NoCode();

    /// @notice Thrown when an upgrade's new implementation changes the boringVault referenced by the DCD.
    error BoringVaultMismatch(address expected, address actual);

    /**
     * @param _implementation Initial SmartDepositAddress implementation this beacon serves.
     * @param _owner Address authorized to call upgradeTo() on the inherited UpgradeableBeacon.
     */
    constructor(address _implementation, address _owner) UpgradeableBeacon(_implementation, _owner) {
        SmartDepositAddress impl = SmartDepositAddress(_implementation);
        if (impl.DCD().boringVault() == address(0)) revert ZeroAddress();
    }

    /**
     * @notice Upgrades the beacon's implementation, enforcing that the new implementation's
     *         boringVault (via DCD) matches the current implementation's.
     * @dev `boringVault` is mixed into the deterministic deployment salt, so changing it would
     *      orphan every previously deployed SDA from its computed address. Rejecting the upgrade
     *      on mismatch preserves the invariant that `computeSDAAddress(orgId, user, inputToken)`
     *      remains stable across upgrades.
     * @param newImplementation The proposed new SmartDepositAddress implementation.
     */
    function upgradeTo(address newImplementation) public override onlyOwner {
        SmartDepositAddress oldImpl = SmartDepositAddress(implementation());
        address oldBoringVault = oldImpl.DCD().boringVault();

        super.upgradeTo(newImplementation);

        SmartDepositAddress newImpl = SmartDepositAddress(implementation());
        address newBoringVault = newImpl.DCD().boringVault();

        if (newBoringVault != oldBoringVault) revert BoringVaultMismatch(oldBoringVault, newBoringVault);
    }

    /**
     * @notice Deploys a SmartDepositAddress beacon proxy at a deterministic address via CreateX.
     * @dev The beacon for the new proxy is always this contract, and the salt disables CreateX's
     *      cross-chain redeploy protection so identical inputs produce the same address on every chain.
     *      `boringVault` is read through the implementation's DCD; `inputToken` is supplied by the
     *      caller and folded into the deployment salt so each (orgId, user, token) tuple lands at a
     *      distinct address. Initializer calldata is constructed internally as
     *      `SmartDepositAddress.initialize(userDestinationAddress, inputToken)` and executed via
     *      delegatecall during proxy construction, so `msg.sender` of `initialize` is the proxy itself.
     *      Callers relying on cross-chain determinism MUST ensure this factory was deployed to the
     *      same address on each target chain.
     * @param organizationId Organization identifier as bytes32, typically a UUID left-padded to 32
     *                       bytes; used only as salt entropy.
     *                       Example:
     *                       Input: "700768ae-c71d-42cc-9ff9-13b777d6d379"
     *                       Output: "0x00000000000000000000000000000000700768aec71d42cc9ff913b777d6d379"
     * @param userDestinationAddress Canonical end-user identity included in the deployment salt and event,
     *                               and set in the proxy's storage via its initializer.
     * @param inputToken The stablecoin this proxy will accept and forward. Included in the deployment
     *                   salt and set in the proxy's storage via its initializer.
     * @return sda The deployed BeaconProxy address.
     */
    function deployBeaconProxy(
        bytes32 organizationId,
        address userDestinationAddress,
        address inputToken
    )
        external
        returns (address sda)
    {
        if (userDestinationAddress == address(0)) revert ZeroAddress();
        if (inputToken == address(0)) revert ZeroAddress();
        if (inputToken.code.length == 0) revert NoCode();

        SmartDepositAddress impl = SmartDepositAddress(implementation());
        address boringVault = impl.DCD().boringVault();

        bytes memory initData =
            abi.encodeWithSelector(SmartDepositAddress.initialize.selector, userDestinationAddress, inputToken);
        bytes memory creationCode =
            abi.encodePacked(type(BeaconProxy).creationCode, abi.encode(address(this), initData));
        bytes32 salt = _makeSDASalt(boringVault, organizationId, userDestinationAddress, inputToken);
        sda = CREATEX.deployCreate3(salt, creationCode);

        emit BeaconProxyDeployed(userDestinationAddress, organizationId, inputToken, boringVault, sda);
    }

    /**
     * @notice Computes the SDA address that `deployBeaconProxy` would produce for the given inputs,
     *         without deploying.
     * @dev Replicates CreateX's `_guard` logic for (MsgSender, CrosschainProtected=false):
     *      guardedSalt = keccak256(abi.encode(address(this), salt)).
     *      `boringVault` is sourced from the current implementation's DCD, so this result can change
     *      across beacon upgrades that alter the underlying DCD's vault.
     * @param organizationId Same meaning as in `deployBeaconProxy`.
     * @param userDestinationAddress Same meaning as in `deployBeaconProxy`.
     * @param inputToken Same meaning as in `deployBeaconProxy`.
     * @return The address at which the SDA will be (or has been) deployed for the given inputs.
     */
    function computeSDAAddress(
        bytes32 organizationId,
        address userDestinationAddress,
        address inputToken
    )
        external
        view
        returns (address)
    {
        SmartDepositAddress impl = SmartDepositAddress(implementation());
        address boringVault = impl.DCD().boringVault();

        bytes32 salt = _makeSDASalt(boringVault, organizationId, userDestinationAddress, inputToken);
        bytes32 guardedSalt = keccak256(abi.encode(address(this), salt));
        return CREATEX.computeCreate3Address(guardedSalt, address(CREATEX));
    }

    /**
     * @notice Computes the deterministic CreateX salt for a SDA deployment.
     * @return The assembled 32-byte salt to pass to CREATEX.deployCreate3.
     */
    function _makeSDASalt(
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
