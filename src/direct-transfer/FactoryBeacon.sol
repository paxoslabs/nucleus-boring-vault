// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { SimpleBeacon } from "src/direct-transfer/SimpleBeacon.sol";
import { SimpleBeaconProxy } from "src/direct-transfer/SimpleBeaconProxy.sol";
import { DirectTransferAddress } from "src/direct-transfer/DirectTransferAddress.sol";
import { ICreateX } from "src/interfaces/ICreateX.sol";

/**
 * @title FactoryBeacon
 * @notice Dual-purpose contract that is both the UpgradeableBeacon (via SimpleBeacon) for every
 *         DirectTransferAddress proxy it spawns and the factory that deploys those proxies at
 *         deterministic, cross-chain-stable addresses.
 * @dev One FactoryBeacon serves one DirectTransferAddress implementation, pinned to one DCD and one
 *      stablecoin. Deployment uses CreateX's CREATE3 flow keyed on `msg.sender == this`, so the DTA
 *      address is a pure function of the inputs and this factory's address — identical on every chain.
 * @custom:security-contact security@molecularlabs.io
 */
contract FactoryBeacon is SimpleBeacon {

    /// @notice Canonical CreateX deployer used for CREATE3 deployments.
    /// @dev Same address on every EVM chain where CreateX is deployed, which is what enables
    /// cross-chain deterministic DTA addresses.
    ICreateX public constant CREATEX = ICreateX(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);

    /**
     * @notice Emitted when a new DirectTransferAddress beacon proxy is deployed.
     * @param directTransferAddress Address of the freshly deployed SimpleBeaconProxy (the DTA).
     * @param user The end-user configured as the DTA's `receiver`.
     * @param organizationId Organization identifier mixed into the deployment salt; surfaced here
     *                       so indexers can correlate DTAs to an off-chain org.
     * @param inputToken The stablecoin the DTA accepts and forwards.
     */
    event BeaconProxyDeployed(
        address indexed directTransferAddress, address indexed user, bytes32 indexed organizationId, address inputToken
    );

    /// @notice Thrown when `inputToken` does not match the implementation's immutable `token`.
    /// @dev Prevents producing DTAs whose salt promises one asset but whose forward() path only
    /// handles another.
    /// @param expected The `token` returned by the current implementation.
    /// @param provided The `inputToken` passed by the caller.
    error InputTokenMismatch(address expected, address provided);

    /// @param _implementation Initial DirectTransferAddress implementation this beacon serves; must
    /// already be deployed (SimpleBeacon enforces nonzero code length).
    /// @param _owner Address authorized to call upgradeTo() on the inherited SimpleBeacon.
    constructor(address _implementation, address _owner) SimpleBeacon(_implementation, _owner) { }

    /**
     * @notice Deploys a DirectTransferAddress beacon proxy at a deterministic address via CreateX.
     * @dev The beacon for the new proxy is always this contract, and the salt disables CreateX's
     *      cross-chain redeploy protection so identical inputs produce the same address on every chain.
     *      Callers relying on cross-chain determinism MUST ensure this factory was deployed to the same address on each
     * target chain.
     * @param boringVault BoringVault where forwarded funds settle after depositing through the DCD;
     *                    used only as salt entropy.
     * @param organizationId Organization identifier as bytes32, typically a UUID left-padded to 32
     *                       bytes; used only as salt entropy.
     *                       Example:
     *                       import { Hex, size } from 'viem'
     *                       const organizationId = "700768ae-c71d-42cc-9ff9-13b777d6d379"
     *                       const organizationIdAsBytes32 = `0x${uuid.replaceAll('-', '').padStart(64, '0')}` as Hex
     *                       invariant(size === 32)
     * @param userDestinationAddress End-user that BoringVault shares are minted to on forward() and
     *                               the refund target on refund().
     * @param inputToken Single token the beaconProxy expects to receive; must equal the current
     *                   implementation's `token()`.
     * @return dta The deployed SimpleBeaconProxy address — stable across chains for identical inputs.
     */
    function deployBeaconProxy(
        address boringVault,
        bytes32 organizationId,
        address userDestinationAddress,
        address inputToken
    )
        external
        onlyOwner
        returns (address dta)
    {
        address expectedToken = address(DirectTransferAddress(implementation).token());
        if (inputToken != expectedToken) revert InputTokenMismatch(expectedToken, inputToken);

        bytes32 salt = _makeDTASalt(boringVault, organizationId, userDestinationAddress, inputToken);
        bytes memory initData =
            abi.encodeWithSelector(DirectTransferAddress.initialize.selector, userDestinationAddress);
        bytes memory creationCode =
            abi.encodePacked(type(SimpleBeaconProxy).creationCode, abi.encode(address(this), initData));
        dta = CREATEX.deployCreate3(salt, creationCode);

        emit BeaconProxyDeployed(dta, userDestinationAddress, organizationId, inputToken);
    }

    /**
     * @notice Computes the DTA address that `deployBeaconProxy` would produce for the given inputs,
     *         without deploying.
     * @dev Replicates CreateX's `_guard` logic for (MsgSender, CrosschainProtected=false):
     *      guardedSalt = keccak256(abi.encode(address(this), salt)). `inputToken` is not validated
     *      against the implementation here; callers should supply the value they intend to pass to
     *      `deployBeaconProxy`.
     * @param boringVault Same meaning as in `deployBeaconProxy`.
     * @param organizationId Same meaning as in `deployBeaconProxy`.
     * @param userDestinationAddress Same meaning as in `deployBeaconProxy`.
     * @param inputToken Same meaning as in `deployBeaconProxy`.
     * @return The address at which the DTA will be (or has been) deployed for the given inputs.
     */
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
        bytes32 guardedSalt = keccak256(abi.encode(address(this), salt));
        return CREATEX.computeCreate3Address(guardedSalt, address(CREATEX));
    }

    /**
     * @notice Computes the deterministic CreateX salt for a DTA deployment.
     * @dev Salt layout (32 bytes): [0..19] address(this) binds salt to this factory; [20] 0x00
     *      disables CreateX's cross-chain redeploy protection; [21..31] 11 bytes of keccak256 over
     *      the four inputs provide per-DTA entropy (~2^88 collision resistance).
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
