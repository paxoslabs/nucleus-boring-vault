// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { IRateProvider } from "./../interfaces/IRateProvider.sol";
import { IPriceFeed } from "./../interfaces/IPriceFeed.sol";

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/**
 * @notice Reports the price of a token in terms of ETH. The underlying price
 * feed must be compatible with the Chainlink interface.
 *
 * @custom:security-contact security@paxoslabs.com
 */
contract EthPerTokenRateProvider is IRateProvider {

    using SafeCast for int256;

    error MaxTimeFromLastUpdatePassed(uint256 blockTimestamp, uint256 lastUpdated);
    error InvalidPriceFeedDecimals(uint8 rateDecimals, uint8 priceFeedDecimals);
    error InvalidDescription();
    error InvalidPriceFeedType();

    enum PriceFeedType {
        CHAINLINK,
        REDSTONE
    }

    /**
     * @notice The type of price feed providers.
     */
    PriceFeedType public immutable PRICE_FEED_TYPE;

    /**
     * @notice The asset pair the rate provider queries.
     */
    string public DESCRIPTION;

    /**
     * @notice The underlying price feed that this rate provider reads from.
     */
    IPriceFeed public immutable PRICE_FEED;

    /**
     * @notice Number of seconds since last update to determine whether the
     * price feed is stale.
     */
    uint256 public immutable MAX_TIME_FROM_LAST_UPDATE;

    /**
     * @notice The preicision of the rate returned by this contract.
     */
    uint8 public immutable RATE_DECIMALS;

    /**
     * @notice The offset between the intended return decimals and the price
     * feed decimals.
     * @dev Based on the `PriceFeedType`, the price feed's asset pair label is
     * retrieved differently.
     */
    uint8 public immutable DECIMALS_OFFSET;

    /**
     * @param _description The asset pair. ex) stETH/ETH
     */
    constructor(
        string memory _description,
        IPriceFeed _priceFeed,
        uint256 _maxTimeFromLastUpdate,
        uint8 _rateDecimals,
        PriceFeedType _priceFeedType
    ) {
        if (_priceFeedType == PriceFeedType.CHAINLINK) {
            if (!_isEqual(_description, _priceFeed.description())) revert InvalidDescription();
        } else if (_priceFeedType == PriceFeedType.REDSTONE) {
            if (!_isEqual(_description, _priceFeed.getDataFeedId())) revert InvalidDescription();
        } else {
            revert InvalidPriceFeedType();
        }

        uint8 _priceFeedDecimals = _priceFeed.decimals();

        if (_rateDecimals < _priceFeedDecimals) {
            revert InvalidPriceFeedDecimals(_rateDecimals, _priceFeedDecimals);
        }

        unchecked {
            DECIMALS_OFFSET = _rateDecimals - _priceFeedDecimals;
        }

        DESCRIPTION = _description;
        PRICE_FEED = _priceFeed;
        MAX_TIME_FROM_LAST_UPDATE = _maxTimeFromLastUpdate;
        RATE_DECIMALS = _rateDecimals;
        PRICE_FEED_TYPE = _priceFeedType;
    }

    /**
     * @notice Gets the price of token in terms of ETH.
     * @return ethPerToken price of token in ETH.
     */
    function getRate() public view returns (uint256 ethPerToken) {
        _validityCheck();

        (, int256 _ethPerToken,, uint256 lastUpdatedAt,) = PRICE_FEED.latestRoundData();

        if (block.timestamp - lastUpdatedAt > MAX_TIME_FROM_LAST_UPDATE) {
            revert MaxTimeFromLastUpdatePassed(block.timestamp, lastUpdatedAt);
        }

        ethPerToken = _ethPerToken.toUint256() * 10 ** DECIMALS_OFFSET;
    }

    /**
     * @dev To revert upon custom checks such as sequencer liveness.
     */
    // solhint-disable-next-line no-empty-blocks
    function _validityCheck() internal view virtual { }

    function _isEqual(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(abi.encodePacked(a)) == keccak256(abi.encodePacked(b));
    }

    function _isEqual(string memory a, bytes32 b) internal pure returns (bool) {
        return bytes32(bytes(a)) == b;
    }

}
