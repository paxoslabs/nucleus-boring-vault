// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { IRateProvider } from "./../interfaces/IRateProvider.sol";
import { IPriceFeed } from "./../interfaces/IPriceFeed.sol";
import { Auth, Authority } from "@solmate/auth/Auth.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/**
 * @notice Reports the price of a token in terms of an underlying stablecoin. The underlying price
 * feed must be compatible with the Redstone interface.
 *
 * @notice
 *  Base Asset: Refers to the vault's base asset
 *  Quote Asset: Refers to the asset user's are depositing/withdrawing from the vault
 *  EXAMPLE:
 *      - Base: USDC, a user wants to deposit into a USDC denominated vault
 *      - Quote: USDT, the vault needs to value their USDT deposit in terms of USDC
 *      - This rate provider will determine the rate of the USDT as QUOTE per USD / BASE per USD = QUOTE per BASE
 *      - Redstone will return the QUOTE per USD and BASE per USD. This contract
 *          will determine the QUOTE per BASE rate with appropriate decimal precision.
 * @custom:security-contact security@paxoslabs.com
 */
contract RedstoneStablecoinRateProvider is Auth, IRateProvider {

    using SafeCast for int256;

    error MaxTimeFromLastUpdatePassed(uint256 blockTimestamp, uint256 lastUpdated);
    error InvalidPriceFeedDecimals(uint8 priceFeedDecimals);
    error InvalidDescription();
    error BoundsViolated(uint256 rate, uint256 violatedBound);

    /**
     * @notice The description of the Base asset price feed
     */
    string public DESCRIPTION_BaseFeed;

    /**
     * @notice The description of the Quote asset price feed
     */
    string public DESCRIPTION_QuoteFeed;

    /**
     * @notice bounds on rate to keep it at a reasonable level
     */
    uint256 public lowerBound;

    /**
     * @notice The redstone price feed that returns the value of the Base asset in USD denomination
     */
    IPriceFeed public immutable PRICE_FEED_BaseFeed;

    /**
     * @notice The redstone price feed that returns the value of the quote asset in USD denomination
     */
    IPriceFeed public immutable PRICE_FEED_QuoteFeed;

    /**
     * @notice Number of seconds since last update to determine whether the
     * price feeds are stale.
     */
    uint256 public immutable MAX_TIME_FROM_LAST_UPDATE;

    /**
     * @notice The precision of the rate returned by this contract. This must be equal to the decimals of the quote
     * asset
     */
    uint8 public immutable RATE_DECIMALS;

    /**
     * @notice all redstone oracles should have 8 decimals
     */
    uint8 public constant REDSTONE_DECIMALS = 8;

    /**
     * @param _descriptionBaseFeed The baseFeed asset pair. ex USDC/USD
     * @param _descriptionQuoteFeed The quoteFeed asset pair. ex USDT/USD
     */
    constructor(
        address _owner,
        string memory _descriptionBaseFeed,
        string memory _descriptionQuoteFeed,
        ERC20 _quoteAsset,
        IPriceFeed _baseFeed,
        IPriceFeed _quoteFeed,
        uint256 _maxTimeFromLastUpdate
    )
        Auth(_owner, Authority(address(0)))
    {
        if (!_isEqual(_descriptionBaseFeed, _baseFeed.description())) {
            revert InvalidDescription();
        }
        if (!_isEqual(_descriptionQuoteFeed, _quoteFeed.description())) revert InvalidDescription();

        uint8 _priceFeedDecimals = _baseFeed.decimals();
        if (_priceFeedDecimals != REDSTONE_DECIMALS) {
            revert InvalidPriceFeedDecimals(_priceFeedDecimals);
        }
        _priceFeedDecimals = _quoteFeed.decimals();

        if (_priceFeedDecimals != REDSTONE_DECIMALS) {
            revert InvalidPriceFeedDecimals(_priceFeedDecimals);
        }

        RATE_DECIMALS = _quoteAsset.decimals();

        DESCRIPTION_BaseFeed = _descriptionBaseFeed;
        DESCRIPTION_QuoteFeed = _descriptionQuoteFeed;
        PRICE_FEED_BaseFeed = _baseFeed;
        PRICE_FEED_QuoteFeed = _quoteFeed;
        MAX_TIME_FROM_LAST_UPDATE = _maxTimeFromLastUpdate;
        // Default Lower Bound is 5 bps
        lowerBound = 10 ** RATE_DECIMALS * 9995 / 10_000;
    }

    /**
     * @notice change the bounds (defaults are 5 bps based on decimals provided)
     * @dev callable by OWNER
     */
    function setLowerBound(uint256 _lowerBound) external requiresAuth {
        lowerBound = _lowerBound;
    }

    /**
     * @notice Gets the price of the quote token in terms of the base feed stablecoin.
     * @return rate in terms of base feed stablecoin.
     */
    function getRate() public view returns (uint256) {
        _validityCheck();

        (, int256 _baseRate,, uint256 lastUpdatedAtUsd,) = PRICE_FEED_BaseFeed.latestRoundData();

        if (block.timestamp - lastUpdatedAtUsd > MAX_TIME_FROM_LAST_UPDATE) {
            revert MaxTimeFromLastUpdatePassed(block.timestamp, lastUpdatedAtUsd);
        }

        (, int256 _quoteRate,, uint256 lastUpdatedAtQuote,) = PRICE_FEED_QuoteFeed.latestRoundData();

        if (block.timestamp - lastUpdatedAtQuote > MAX_TIME_FROM_LAST_UPDATE) {
            revert MaxTimeFromLastUpdatePassed(block.timestamp, lastUpdatedAtQuote);
        }

        // rate(quote decimals) = quoteRate(8) * 10^(quote decimals) / baseRate(8)
        uint256 rate = (_quoteRate.toUint256() * 10 ** (RATE_DECIMALS) / _baseRate.toUint256());

        _rateCheck(rate);

        uint256 ONE = 10 ** RATE_DECIMALS;

        if (rate > ONE) {
            return ONE;
        }

        return rate;
    }

    /**
     * @dev To revert upon custom checks such as sequencer liveness.
     */
    // solhint-disable-next-line no-empty-blocks
    function _validityCheck() internal view virtual { }

    /**
     * @dev To check rate remains in reasonable bounds
     */
    function _rateCheck(uint256 rate) internal view {
        if (rate < lowerBound) {
            revert BoundsViolated(rate, lowerBound);
        }
    }

    function _isEqual(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(abi.encodePacked(a)) == keccak256(abi.encodePacked(b));
    }

    function _isEqual(string memory a, bytes32 b) internal pure returns (bool) {
        return bytes32(bytes(a)) == b;
    }

}
