// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { TransitStation } from "src/transit/TransitStation.sol";
import { Authority } from "@solmate/auth/Auth.sol";
import { Origin } from "src/base/Roles/CrossChain/OAppAuth/OAppAuth.sol";

/// @notice Test harness that exposes `TransitStation`'s internal functions so they can be exercised directly.
/// @dev Inherit from this contract in tests, or deploy it standalone with the same constructor args as
/// `TransitStation`.
contract TransitStationInternal is TransitStation {

    constructor(
        address _owner,
        Authority _authority,
        address _endpoint,
        address _protocolFeeRecipient,
        address _quoteSigner,
        address _offerReceiver,
        address _wantAssetSource
    )
        TransitStation(
            _owner, _authority, _endpoint, _protocolFeeRecipient, _quoteSigner, _offerReceiver, _wantAssetSource
        )
    { }

    function exposedSubmitOrder(Quote calldata quote, bytes calldata signature)
        external
        payable
        returns (bytes32 uuid)
    {
        return _submitOrder(quote, signature);
    }

    function exposedVerifyAndCollect(
        Quote calldata quote,
        bytes calldata signature
    )
        external
        returns (bytes32 digest, uint256 offerAmountNormalized18AfterFees)
    {
        return _verifyAndCollect(quote, signature);
    }

    function exposedSendOrder(uint32 destEID, OrderTerms calldata terms) external payable {
        _sendOrder(destEID, terms);
    }

    function exposedPushOrder(OrderTerms calldata terms) external returns (Order memory) {
        return _pushOrder(terms);
    }

    function exposedLzReceive(Origin calldata origin, bytes32 guid, bytes calldata payload) external {
        bytes calldata emptyOptions = msg.data[0:0];
        _lzReceive(origin, guid, payload, address(0), emptyOptions);
    }

    function exposedDomainSeparator() external view returns (bytes32) {
        return _domainSeparator();
    }

    function exposedToTokenDecimals(uint256 amountNormalized18, uint8 decimals) external pure returns (uint256) {
        return _toTokenDecimals(amountNormalized18, decimals);
    }

    function exposedToNormalizedDecimals(uint256 amountTokenUnits, uint8 decimals) external pure returns (uint256) {
        return _toNormalizedDecimals(amountTokenUnits, decimals);
    }

}
