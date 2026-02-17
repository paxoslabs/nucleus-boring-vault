// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { Test, stdStorage, StdStorage, stdError, console } from "@forge-std/Test.sol";
import { VmSafe } from "@forge-std/Vm.sol";
import { BoringVault } from "src/base/BoringVault.sol";
import { TellerWithMultiAssetSupport } from "src/base/Roles/TellerWithMultiAssetSupport.sol";
import { AccountantWithRateProviders } from "src/base/Roles/AccountantWithRateProviders.sol";
import { WithdrawQueue } from "src/base/Roles/WithdrawQueue.sol";
import { RolesAuthority, Authority } from "@solmate/auth/authorities/RolesAuthority.sol";
import { SimpleFeeModule, IFeeModule } from "src/helper/SimpleFeeModule.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import { FixedPointMathLib } from "solmate/utils/FixedPointMathLib.sol";

contract tERC20 is ERC20 {

    bool public failSwitch;

    constructor(uint8 _decimalsInput) ERC20("test name", "test", _decimalsInput) { }

    function setFailSwitch(bool _failSwitch) public {
        failSwitch = _failSwitch;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (failSwitch) revert("TEST_ERROR: transfer failed");
        return super.transfer(to, amount);
    }

}

contract BaseWithdrawQueueTest is Test {

    using FixedPointMathLib for uint256;

    event FeeModuleUpdated(IFeeModule indexed oldFeeModule, IFeeModule indexed newFeeModule);
    event MinimumOrderSizeUpdated(uint256 oldMinimum, uint256 newMinimum);
    event FeeRecipientUpdated(address indexed oldFeeRecipient, address indexed newFeeRecipient);
    event OrderSubmitted(
        uint256 indexed orderIndex,
        WithdrawQueue.Order order,
        address indexed receiver,
        address indexed depositor,
        bool isSubmittedViaSignature
    );
    event OrdersProcessedInRange(uint256 indexed startIndex, uint256 indexed endIndex);
    event OrderProcessed(
        uint256 indexed orderIndex,
        WithdrawQueue.Order order,
        address indexed receiver,
        bool indexed isForceProcessed,
        uint256 feeAmount,
        uint256 assetsOut
    );
    event OrderRefunded(uint256 indexed orderIndex, WithdrawQueue.Order order);
    event TellerUpdated(TellerWithMultiAssetSupport indexed oldTeller, TellerWithMultiAssetSupport indexed newTeller);
    event OrderMarkedForRefund(uint256 indexed orderIndex, bool indexed isMarkedByUser);

    BoringVault boringVault;
    TellerWithMultiAssetSupport teller;
    AccountantWithRateProviders accountant;

    WithdrawQueue withdrawQueue;
    RolesAuthority rolesAuthority;
    SimpleFeeModule feeModule;

    IERC20 public USDC;

    address owner = makeAddr("owner");
    address user = makeAddr("user");
    address user2 = makeAddr("user2");
    address payout_address = makeAddr("payout_address");
    address feeRecipient = makeAddr("fee recipient");
    address alice;
    uint256 alicePk;
    address bob;
    uint256 bobPk;

    uint8 public constant MINTER_ROLE = 1;
    uint8 public constant BURNER_ROLE = 2;
    uint8 public constant QUEUE_ROLE = 8;
    uint256 public constant TEST_OFFER_FEE_PERCENTAGE = 10; // 0.1% fee

    // A simple params struct used in most tests
    WithdrawQueue.SignatureParams defaultSignatureParams = WithdrawQueue.SignatureParams({
        approvalMethod: WithdrawQueue.ApprovalMethod.EIP20_APPROVE,
        approvalV: 0,
        approvalR: bytes32(0),
        approvalS: bytes32(0),
        submitWithSignature: false,
        deadline: block.timestamp + 1000,
        eip2612Signature: ""
    });

    function setUp() public virtual {
        vm.startPrank(owner);
        USDC = IERC20(address(new tERC20(6)));
        require(address(USDC) != address(0), "USDC is not deployed");
        (alice, alicePk) = makeAddrAndKey("alice");
        (bob, bobPk) = makeAddrAndKey("bob");

        // Deploy the vault contracts
        boringVault = new BoringVault(owner, "Boring Vault", "BV", 6);

        accountant = new AccountantWithRateProviders(
            owner, address(boringVault), payout_address, 1e6, address(USDC), 1.001e4, 0.999e4, 1, 0, 0
        );

        teller = new TellerWithMultiAssetSupport(owner, address(boringVault), address(accountant));

        rolesAuthority = new RolesAuthority(owner, Authority(address(0)));

        feeModule = new SimpleFeeModule(TEST_OFFER_FEE_PERCENTAGE);
        withdrawQueue = new WithdrawQueue("Withdraw Queue", "WQ", feeRecipient, teller, feeModule, 0, owner);

        // Set Role Authorities, user roles and Capabilities
        boringVault.setAuthority(rolesAuthority);
        accountant.setAuthority(rolesAuthority);
        teller.setAuthority(rolesAuthority);
        withdrawQueue.setAuthority(rolesAuthority);

        rolesAuthority.setRoleCapability(MINTER_ROLE, address(boringVault), BoringVault.enter.selector, true);
        rolesAuthority.setRoleCapability(BURNER_ROLE, address(boringVault), BoringVault.exit.selector, true);
        rolesAuthority.setRoleCapability(
            QUEUE_ROLE, address(teller), TellerWithMultiAssetSupport.bulkWithdraw.selector, true
        );

        rolesAuthority.setPublicCapability(address(teller), TellerWithMultiAssetSupport.deposit.selector, true);
        rolesAuthority.setPublicCapability(
            address(teller), TellerWithMultiAssetSupport.depositWithPermit.selector, true
        );
        rolesAuthority.setPublicCapability(address(withdrawQueue), WithdrawQueue.submitOrder.selector, true);
        rolesAuthority.setPublicCapability(address(withdrawQueue), WithdrawQueue.cancelOrder.selector, true);
        rolesAuthority.setPublicCapability(
            address(withdrawQueue), WithdrawQueue.cancelOrderWithSignature.selector, true
        );
        rolesAuthority.setPublicCapability(address(withdrawQueue), WithdrawQueue.processOrders.selector, true);
        rolesAuthority.setPublicCapability(address(withdrawQueue), WithdrawQueue.submitOrderAndProcess.selector, true);
        rolesAuthority.setPublicCapability(
            address(withdrawQueue), WithdrawQueue.submitOrderAndProcessAll.selector, true
        );

        rolesAuthority.setUserRole(address(withdrawQueue), QUEUE_ROLE, true);
        rolesAuthority.setUserRole(address(teller), MINTER_ROLE, true);
        rolesAuthority.setUserRole(address(teller), BURNER_ROLE, true);

        teller.addDepositAsset(ERC20(address(USDC)));
        teller.addWithdrawAsset(ERC20(address(USDC)));
        vm.stopPrank();
    }

    function _getFees(uint256 amount) internal view returns (uint256) {
        return (amount.mulDivUp(feeModule.offerFeePercentage(), 10_000));
    }

    function _getAmountAfterFees(uint256 amount) internal view returns (uint256) {
        return amount - _getFees(amount);
    }

    function _submitAnOrder() internal {
        (VmSafe.CallerMode mode,,) = vm.readCallers();
        if (mode != VmSafe.CallerMode.None) {
            revert("TEST_ERROR: Calling _submitAnOrder while in prank mode. End your prank before calling this helper");
        }

        uint256 vaultUSDCBal = USDC.balanceOf(address(boringVault));
        uint256 userShareBal = boringVault.balanceOf(user);
        deal(address(USDC), address(boringVault), vaultUSDCBal + 1e6);
        deal(address(boringVault), user, userShareBal + 1e6);
        vm.startPrank(user);
        boringVault.approve(address(withdrawQueue), 1e6);

        WithdrawQueue.SubmitOrderParams memory params =
            _createSubmitOrderParams(USDC, 1e6, user, user, user, defaultSignatureParams);

        _expectOrderSubmittedEvent(1e6, USDC, user, user, false);
        withdrawQueue.submitOrder(params);
        vm.stopPrank();
    }

    function _createSubmitOrderParams(
        IERC20 wantAsset,
        uint256 amountOffer,
        address intendedDepositor,
        address receiver,
        address refundReceiver,
        WithdrawQueue.SignatureParams memory signatureParams
    )
        internal
        returns (WithdrawQueue.SubmitOrderParams memory)
    {
        return WithdrawQueue.SubmitOrderParams({
            amountOffer: amountOffer,
            wantAsset: wantAsset,
            intendedDepositor: intendedDepositor,
            receiver: receiver,
            refundReceiver: refundReceiver,
            signatureParams: signatureParams
        });
    }

    function _expectOrderSubmittedEvent(
        uint256 amountOffer,
        IERC20 wantAsset,
        address receiver,
        address depositor,
        bool isSubmittedViaSignature
    )
        internal
    {
        WithdrawQueue.Order memory order = WithdrawQueue.Order({
            amountOffer: amountOffer,
            wantAsset: wantAsset,
            refundReceiver: receiver,
            orderType: WithdrawQueue.OrderType.DEFAULT,
            didOrderFailTransfer: false
        });
        vm.expectEmit(true, true, true, true);
        emit WithdrawQueue.OrderSubmitted(
            withdrawQueue.latestOrder() + 1, order, receiver, depositor, isSubmittedViaSignature
        );
    }

    function _expectOrderProcessedEvent(
        uint256 orderIndex,
        IERC20 wantAsset,
        address receiver,
        uint256 amountOffer,
        WithdrawQueue.OrderType orderType,
        bool isForceProcessed
    )
        internal
    {
        WithdrawQueue.Order memory order = WithdrawQueue.Order({
            amountOffer: amountOffer,
            wantAsset: wantAsset,
            refundReceiver: receiver,
            orderType: orderType,
            didOrderFailTransfer: false
        });
        uint256 feeAmount = feeModule.calculateOfferFees(amountOffer, wantAsset, IERC20(receiver), receiver);
        uint256 expectedAssetsOut = teller.accountant().getRateInQuoteSafe(ERC20(address(wantAsset)))
            .mulDivDown((amountOffer - feeAmount), 10 ** boringVault.decimals());
        vm.expectEmit(true, true, true, true);
        emit WithdrawQueue.OrderProcessed(orderIndex, order, receiver, isForceProcessed, feeAmount, expectedAssetsOut);
    }

    function _expectOrderRefundedEvent(
        uint256 orderIndex,
        IERC20 wantAsset,
        address receiver,
        uint256 amountOffer
    )
        internal
    {
        WithdrawQueue.Order memory order = WithdrawQueue.Order({
            amountOffer: amountOffer,
            wantAsset: wantAsset,
            refundReceiver: receiver,
            orderType: WithdrawQueue.OrderType.REFUND,
            didOrderFailTransfer: false
        });
        vm.expectEmit(true, true, true, true);
        emit WithdrawQueue.OrderRefunded(orderIndex, order);
    }

    function _getPermitSignature(
        IERC20 token,
        address owner,
        uint256 ownerPk,
        address spender,
        uint256 value,
        uint256 deadline
    )
        internal
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 permitHash = keccak256(
            abi.encodePacked(
                "\x19\x01",
                IERC20Permit(address(token)).DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                        owner,
                        spender,
                        value,
                        IERC20Permit(address(token)).nonces(owner),
                        deadline
                    )
                )
            )
        );
        (v, r, s) = vm.sign(ownerPk, permitHash);
    }

}
