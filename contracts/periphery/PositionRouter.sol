// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import { IFactory } from "../interfaces/IFactory.sol";
import { IOption } from "../interfaces/IOption.sol";
import { IReceipt } from "../interfaces/IReceipt.sol";
import { IBebopSettlement } from "../interfaces/IBebopSettlement.sol";
import { ISafe } from "../interfaces/ISafe.sol";

/**
 * @title  PositionRouter: one fixed address for a writer's mint, burn, redeem and Bebop order signing
 * @notice DEMO ONLY. Not audited, not deployed, outside the audit scope in `auditors-instructions.md`.
 *
 *         Every market is its own Option/Receipt clone pair, so an account whose call permissions are
 *         scoped by target address (a Safe behind a Zodiac Roles Modifier, say) would need a new
 *         permission for every series it writes. This router gives that account one fixed target.
 *
 *         Called normally, {mint}, {burn} and {redeem} take a list of markets, validate that each
 *         belongs to {FACTORY}, then forward to its operator entry points with `msg.sender` as the
 *         account. Setup:
 *         approve collateral to the factory, then `factory.setPermissions(router, MINT | BURN | REDEEM)`.
 *         Each of those bits pays out only to the account, and the router only ever names
 *         `msg.sender`, so nobody can use it to act on anyone else's position.
 *
 *         Called by DELEGATECALL from a Safe 1.3.0, {signOrder} pre-signs one Bebop order that sells
 *         a Greek option for USDC, so a maker can execute it with `BebopSettlement.settleSingle`
 *         until `order.expiry` without the Safe signing again (same pattern as Gnosis Guild's
 *         CowswapOrderSigner). Bebop verifies the taker by calling `Safe.isValidSignature(hash, "")`,
 *         which the Safe's CompatibilityFallbackHandler answers from `signedMessages`. Selling mints
 *         just in time: Bebop's `transferFrom(Safe, maker)` runs the auto-mint, so the Safe also
 *         grants `factory.setPermissions(BEBOP, TRANSFER | MINT)`.
 */
contract PositionRouter {
    /// @dev keccak256("SafeMessage(bytes message)")
    bytes32 private constant SAFE_MSG_TYPEHASH = 0x60b3cbf8b4a223d68d641b3b6ddf9a298e7f33710cf3d3a9d1146b5a6150fbca;
    /// @dev Slot of `mapping(bytes32 => uint256) signedMessages` in Safe 1.3.0 (`GnosisSafeStorage`).
    uint256 private constant SIGNED_MESSAGES_SLOT = 7;

    /// @notice The factory whose markets this router accepts.
    IFactory public immutable FACTORY;
    /// @notice Bebop settlement contract whose order hash {signOrder} signs.
    IBebopSettlement public immutable BEBOP;
    /// @notice The two tokens a signed market may pair, and the premium token is {USDC}.
    address public immutable WETH;
    address public immutable USDC;
    /// @notice Longest time to expiration a signed market may have.
    uint256 public immutable MAX_TENOR;
    /// @notice Longest post-expiry exercise window a signed market may have.
    uint256 public immutable MAX_WINDOW;
    address private immutable SELF;

    /// @notice `option` was not created by {FACTORY}.
    error UnknownOption();
    /// @notice `options` and `amounts` differ in length.
    error LengthMismatch();
    /// @notice {signOrder} / {unsignOrder} were called directly instead of by DELEGATECALL.
    error DelegateCallOnly();
    /// @notice The order's fields break the signing rules.
    error InvalidOrder();
    /// @notice The order's market breaks the signing rules.
    error MarketNotAllowed();

    /// @dev Emitted from the Safe, as Safe's SignMessageLib does, so Safe tooling sees the signature.
    event SignMsg(bytes32 indexed msgHash);

    constructor(IFactory factory_, IBebopSettlement bebop_, address weth_, address usdc_, uint256 maxTenor_, uint256 maxWindow_) {
        FACTORY = factory_;
        BEBOP = bebop_;
        WETH = weth_;
        USDC = usdc_;
        MAX_TENOR = maxTenor_;
        MAX_WINDOW = maxWindow_;
        SELF = address(this);
    }

    /// @notice For each `i`, mint `amounts[i]` of `options[i]` for the caller, paid from the caller's
    ///         factory collateral allowance. The caller receives both the Option and the Receipt.
    ///         Needs `Perm.MINT`.
    function mint(IOption[] calldata options, uint256[] calldata amounts) external {
        if (options.length != amounts.length) revert LengthMismatch();
        for (uint256 i; i < options.length; ++i) {
            _receiptOf(options[i]);
            options[i].mint(msg.sender, amounts[i]);
        }
    }

    /// @notice For each `i`, pair-burn `amounts[i]` of the caller's matched Option + Receipt in
    ///         `options[i]`'s market; collateral returns to the caller. Needs `Perm.BURN`.
    function burn(IOption[] calldata options, uint256[] calldata amounts) external {
        if (options.length != amounts.length) revert LengthMismatch();
        for (uint256 i; i < options.length; ++i) {
            _receiptOf(options[i]);
            options[i].burn(msg.sender, amounts[i]);
        }
    }

    /// @notice Redeem the caller's full Receipt balance in each of `options`' markets; proceeds go
    ///         to the caller. Needs `Perm.REDEEM`. Without the grant {IReceipt.redeemFor} skips the
    ///         caller silently and this call succeeds having done nothing. Any market whose
    ///         redemption reverts reverts the whole batch.
    function redeem(IOption[] calldata options) external {
        address[] memory holders = new address[](1);
        holders[0] = msg.sender;
        for (uint256 i; i < options.length; ++i) {
            _receiptOf(options[i]).redeemFor(holders);
        }
    }

    /// @notice DELEGATECALL only. Mark `order` as signed by the calling Safe, at a premium of at least
    ///         `minMakerAmount` USDC. The maker settles it with `settleSingle(order, makerSig, 0,
    ///         OldSingleQuote(false, minMakerAmount, order.maker_nonce), "")` and `order.flags`
    ///         signature type 1 (EIP-1271). The maker may raise `maker_amount`; any other change
    ///         breaks the hash. The submitter picks the fill size (`filledTakerAmount` is in neither
    ///         signature): anything up to `order.taker_amount`, with the premium scaled pro-rata and
    ///         rounded down, so a dust fill can pay zero. The first fill of any size spends the maker
    ///         nonce, so the signature fills once. To survive partial fills, sign several orders on
    ///         fresh nonces and set the Safe's collateral approval to the factory to the intended
    ///         size: the approval, not the orders, then caps how much can mint.
    /// @param validDuration Upper bound on `order.expiry - now`, for the Roles Modifier to cap.
    function signOrder(IBebopSettlement.SingleOrder calldata order, uint256 minMakerAmount, uint32 validDuration) external {
        if (
            order.expiry > block.timestamp + validDuration || order.taker_address != address(this) || order.receiver != address(this)
                || order.maker_token != USDC || order.packed_commands != 0 || minMakerAmount == 0
        ) revert InvalidOrder();

        IReceipt receipt = _receiptOf(IOption(order.taker_token));
        address coll = address(receipt.collateral());
        address cons = address(receipt.consideration());
        if (
            !receipt.isEuro() || receipt.expirationDate() > block.timestamp + MAX_TENOR
                || receipt.exerciseDeadline() - receipt.expirationDate() > MAX_WINDOW
                || !((coll == WETH && cons == USDC) || (coll == USDC && cons == WETH))
        ) revert MarketNotAllowed();

        _setSigned(order, minMakerAmount, 1);
    }

    /// @notice DELEGATECALL only. Withdraw a {signOrder} signature before a maker settles it.
    function unsignOrder(IBebopSettlement.SingleOrder calldata order, uint256 minMakerAmount) external {
        _setSigned(order, minMakerAmount, 0);
    }

    /// @dev Writes `signedMessages[msgHash]` in the Safe's storage, where `msgHash` is what the Safe's
    ///      CompatibilityFallbackHandler derives from Bebop's taker hash. partnerId 0 keeps any partner
    ///      fee out of the premium.
    function _setSigned(IBebopSettlement.SingleOrder calldata order, uint256 minMakerAmount, uint256 value) private {
        if (address(this) == SELF) revert DelegateCallOnly();

        bytes32 orderHash = BEBOP.hashSingleOrder(order, 0, minMakerAmount, order.maker_nonce);
        bytes32 msgHash = keccak256(
            abi.encodePacked(
                bytes1(0x19),
                bytes1(0x01),
                ISafe(address(this)).domainSeparator(),
                keccak256(abi.encode(SAFE_MSG_TYPEHASH, keccak256(abi.encode(orderHash))))
            )
        );
        bytes32 slot = keccak256(abi.encode(msgHash, SIGNED_MESSAGES_SLOT));
        assembly ("memory-safe") {
            sstore(slot, value)
        }
        emit SignMsg(msgHash);
    }

    /// @dev The factory registers every Receipt it creates, and each Receipt names its Option, so a
    ///      registered Receipt that points back at `option` proves `option` is a factory market.
    function _receiptOf(IOption option) private view returns (IReceipt receipt) {
        receipt = option.receipt();
        if (!FACTORY.receipts(address(receipt)) || receipt.option() != address(option)) revert UnknownOption();
    }
}
