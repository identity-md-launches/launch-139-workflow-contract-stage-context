// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @title PvPadHook
/// @notice One-contract PvPad economics for a Uniswap v4 pool: a 1% swap fee paid to whoever the
/// current King named as beneficiary, a King seat bought with ETH that funds Identity MD workers, and
/// a Merkle-epoch drip that pays those workers from the pot.
///
/// @dev Factory compatible by construction. The constructor takes ONLY the PoolManager, and the hook
/// declares no initialize, liquidity or donate permission, so the launch factory can call
/// `PoolManager.initialize` itself with any sender and seed ordinary v4 liquidity. The three
/// permissions are the swap path only: `beforeSwap`, `afterSwap`, `beforeSwapReturnDelta`
/// (address bits 0xC8 = 200).
///
/// Fee mechanics, BurnHook-shaped. The specified currency of a swap is the one `amountSpecified`
/// refers to: the input for exact-input (`amountSpecified < 0`), the output for exact-output. In
/// `beforeSwap` the hook returns a positive specified delta of `|amountSpecified| * FEE_BPS / 10_000`
/// (rounded down); v4 then swaps the remaining 99% (exact input) or swaps for 101% (exact output),
/// so the trader always pays or receives exactly `amountSpecified` and the hook is credited the fee.
/// In `afterSwap` the hook checks the pool filled the whole amount, takes the fee out of the
/// PoolManager and delivers it to the beneficiary. Native ETH is pushed with a 2300-gas send (an EOA
/// or a simple receiver gets it in the swap); an ERC-20 fee is transferred by the PoolManager
/// directly to the beneficiary. Any delivery that fails becomes a pullable credit (`pending`,
/// `withdraw`), so no beneficiary can block trading. If the PoolManager cannot release the fee yet
/// (the first exact-input buys of a one-sided pool, before the trader has settled) the fee is held
/// as an ERC-6909 claim on the PoolManager and anyone may `redeem` it later. Fees earned before the
/// first King go to `unassigned` and belong to the first beneficiary (`assignUnassigned`).
///
/// There is no owner, no fee setter, no pause, no treasury, no house cut, no upgrade path, no
/// SELFDESTRUCT and no DELEGATECALL. The only privileged address is the epoch `updater`, which can
/// only publish attested Merkle roots for the worker pot and hand its role over in two steps.
contract PvPadHook is IHooks, IUnlockCallback {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    // ---------------------------------------------------------------------------------------------
    // Constants (compile-time; nothing here can be changed after deployment)
    // ---------------------------------------------------------------------------------------------

    /// @notice The address that may publish worker epochs at deployment. Baked in source, not a
    /// constructor argument. Rotation only through `proposeUpdater` / `acceptUpdater`.
    address public constant INITIAL_UPDATER = 0x5b95A971B4583A5f011E9DA082acdD679b870D06;
    /// @notice Swap fee skimmed from the specified currency, in basis points (100 = 1%).
    uint256 public constant FEE_BPS = 100;
    /// @notice Basis-point denominator.
    uint256 public constant BPS_DENOMINATOR = 10_000;
    /// @notice The first King bid must exceed this many wei.
    uint256 public constant INITIAL_CLAIM_PRICE = 0.01 ether;
    /// @notice Each winning bid raises the next `claimPrice` by this many basis points (1000 = +10%).
    uint256 public constant BUMP_BPS = 1000;
    /// @notice Longest claim window a worker epoch may have.
    uint256 public constant MAX_EPOCH_WINDOW = 90 days;
    /// @notice Gas forwarded when pushing an ETH fee inside a swap. Enough for an EOA or a receiver
    /// that only logs; too little to re-enter the PoolManager or this hook.
    uint256 public constant PUSH_GAS = 2300;

    /// @notice The pool manager this hook serves; the only caller allowed to drive its callbacks.
    IPoolManager public immutable poolManager;

    // ---------------------------------------------------------------------------------------------
    // King state
    // ---------------------------------------------------------------------------------------------

    /// @notice The current King (the last successful claimer). Zero before the first claim.
    address public king;
    /// @notice Where swap fees go while the current King reigns. Zero before the first claim.
    address public beneficiary;
    /// @notice The minimum bid, exclusive: a claim must pay strictly more than this.
    uint256 public claimPrice;
    /// @notice Number of successful King claims.
    uint256 public claimCount;

    // ---------------------------------------------------------------------------------------------
    // Fee state (all per currency: native ETH is `Currency.wrap(address(0))`)
    // ---------------------------------------------------------------------------------------------

    /// @notice Fees credited to a beneficiary that were not pushed; pull with `withdraw`.
    mapping(address account => mapping(Currency currency => uint256 amount)) public pending;
    /// @notice Sum of all `pending` entries for a currency.
    mapping(Currency currency => uint256 amount) public totalPending;
    /// @notice Fees earned before any King existed. `assignUnassigned` gives them to the beneficiary.
    mapping(Currency currency => uint256 amount) public unassigned;
    /// @notice Fees still held as ERC-6909 claims on the PoolManager; `redeem` turns them into balance.
    mapping(Currency currency => uint256 amount) public deferred;
    /// @notice Cumulative fees skimmed per currency, however they were delivered.
    mapping(Currency currency => uint256 amount) public totalSkimmed;

    // ---------------------------------------------------------------------------------------------
    // Worker pot state
    // ---------------------------------------------------------------------------------------------

    struct Epoch {
        bytes32 root;
        uint64 windowStart;
        uint64 windowEnd;
        uint256 budget;
        uint256 paid;
    }

    /// @notice ETH from King claims (and `fundWorkers`) not yet allocated to an epoch.
    uint256 public workerPot;
    /// @notice The only address that may open epochs.
    address public updater;
    /// @notice The address `acceptUpdater` will promote; zero when no handoff is in progress.
    address public pendingUpdater;
    /// @notice Id of the latest epoch; zero before the first one.
    uint256 public currentEpoch;
    mapping(uint256 epochId => Epoch) public epochs;
    mapping(uint256 epochId => mapping(address payee => bool)) public claimed;

    // ---------------------------------------------------------------------------------------------
    // Errors and events
    // ---------------------------------------------------------------------------------------------

    error ZeroAddress();
    error NotPoolManager();
    error HookNotImplemented();
    error WrongHook();
    error InvalidSwapAmount();
    error PartialFill();
    error NoSwapOutput();
    error Reentrancy();
    error DirectEthRejected();
    error BidTooLow(uint256 claimPrice);
    error NoBeneficiary();
    error NothingToDo();
    error PaymentFailed();
    error NotUpdater();
    error NotPendingUpdater();
    error InvalidWindow();
    error EpochStillOpen();
    error EmptyPot();
    error InvalidEpoch();
    error OutsideWindow();
    error InvalidClaim();
    error InsufficientBudget();
    error InvalidProof();

    event KingClaimed(
        address indexed king,
        address indexed beneficiary,
        uint256 paid,
        uint256 nextPrice,
        uint256 indexed claimId
    );
    event FeeDelivered(
        PoolId indexed poolId,
        address indexed sender,
        Currency indexed currency,
        address beneficiary,
        uint256 amount
    );
    event FeeCredited(
        PoolId indexed poolId,
        address indexed sender,
        Currency indexed currency,
        address beneficiary,
        uint256 amount
    );
    event FeeDeferred(
        PoolId indexed poolId,
        address indexed sender,
        Currency indexed currency,
        address beneficiary,
        uint256 amount
    );
    event Redeemed(Currency indexed currency, uint256 amount);
    event UnassignedAssigned(Currency indexed currency, address indexed beneficiary, uint256 amount);
    event Withdrawn(address indexed account, Currency indexed currency, address indexed to, uint256 amount);
    event WorkersFunded(address indexed from, uint256 amount);
    event EpochSet(
        uint256 indexed epochId, bytes32 root, uint64 windowStart, uint64 windowEnd, uint256 budget
    );
    event WorkerPaid(uint256 indexed epochId, address indexed payee, uint256 amount, address relayer);
    event UpdaterProposed(address indexed current, address indexed proposed);
    event UpdaterChanged(address indexed previous, address indexed current);

    // ---------------------------------------------------------------------------------------------
    // Reentrancy guard (transient storage, Cancun)
    // ---------------------------------------------------------------------------------------------

    /// @dev Transient slot of the guard. The hook uses no other transient storage, so a small literal
    /// is unambiguous; a hashed 32-byte slot would be moved by the optimizer into a code data section
    /// that opcode scanners read as instructions.
    uint256 private constant LOCK_SLOT = 1;

    modifier nonReentrant() {
        bool locked;
        assembly ("memory-safe") {
            locked := tload(LOCK_SLOT)
        }
        if (locked) revert Reentrancy();
        assembly ("memory-safe") {
            tstore(LOCK_SLOT, 1)
        }
        _;
        assembly ("memory-safe") {
            tstore(LOCK_SLOT, 0)
        }
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @param manager The PoolManager the hook is deployed for. The deployment address must carry
    /// exactly the bits reported by `getHookPermissions` (0xC8), otherwise the constructor reverts.
    /// Nothing else is read or called at construction.
    constructor(IPoolManager manager) {
        if (address(manager) == address(0)) revert ZeroAddress();
        poolManager = manager;
        updater = INITIAL_UPDATER;
        claimPrice = INITIAL_CLAIM_PRICE;
        emit UpdaterChanged(address(0), INITIAL_UPDATER);
        Hooks.validateHookPermissions(this, getHookPermissions());
    }

    /// @notice ETH arrives only from the PoolManager (`take`). Use `claimKing` or `fundWorkers` to
    /// send value on purpose; anything else is refused so no ETH is ever unaccounted for.
    receive() external payable {
        if (msg.sender != address(poolManager)) revert DirectEthRejected();
    }

    // ---------------------------------------------------------------------------------------------
    // Permissions
    // ---------------------------------------------------------------------------------------------

    /// @notice beforeSwap + afterSwap + beforeSwapReturnDelta, nothing else. Must agree with the
    /// address bits; the launch manifest lists exactly these three.
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---------------------------------------------------------------------------------------------
    // Swap fee
    // ---------------------------------------------------------------------------------------------

    /// @notice The fee for a swap with this `amountSpecified`: 1% of its magnitude, rounded down.
    /// @dev Reverts on magnitudes the PoolManager could not account (beyond int128) and on exact
    /// outputs whose enlarged swap would overflow int128.
    function feeFor(int256 amountSpecified) public pure returns (uint256 fee) {
        if (amountSpecified < -int256(type(int128).max) || amountSpecified > int256(type(int128).max)) {
            revert InvalidSwapAmount();
        }
        uint256 magnitude = uint256(amountSpecified < 0 ? -amountSpecified : amountSpecified);
        fee = magnitude * FEE_BPS / BPS_DENOMINATOR;
        if (amountSpecified > 0 && magnitude + fee > uint256(uint128(type(int128).max))) {
            revert InvalidSwapAmount();
        }
    }

    /// @notice The currency `amountSpecified` refers to for a swap on `key`.
    function specifiedCurrency(PoolKey calldata key, SwapParams calldata params)
        public
        pure
        returns (Currency)
    {
        return (params.amountSpecified < 0) == params.zeroForOne ? key.currency0 : key.currency1;
    }

    /// @inheritdoc IHooks
    /// @dev Reserves the fee: a positive specified delta means the trader owes the hook `fee` on top
    /// of the (reduced or enlarged) swap. Nothing moves yet; `afterSwap` takes it once the pool has
    /// actually executed. No LP fee override, no unspecified delta.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (address(key.hooks) != address(this)) revert WrongHook();
        uint256 fee = feeFor(params.amountSpecified);
        if (fee == 0) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        // feeFor bounds `fee` to int128.max / 100, so the cast cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(int256(fee)), 0), 0);
    }

    /// @inheritdoc IHooks
    /// @dev Checks the pool filled exactly `amountSpecified + fee` of the specified currency (a partial
    /// fill would charge the trader for volume that never traded), then takes and delivers the fee.
    /// The PoolManager credits the hook's `beforeSwap` delta after this callback, cancelling the
    /// debt created by `take` or `mint`; the router still has to settle every currency at unlock.
    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager nonReentrant returns (bytes4, int128) {
        if (address(key.hooks) != address(this)) revert WrongHook();
        uint256 fee = feeFor(params.amountSpecified);
        if (fee == 0) return (IHooks.afterSwap.selector, 0);

        bool specifiedIsZero = (params.amountSpecified < 0) == params.zeroForOne;
        int128 specifiedDelta = specifiedIsZero ? delta.amount0() : delta.amount1();
        // forge-lint: disable-next-line(unsafe-typecast)
        if (int256(specifiedDelta) != params.amountSpecified + int256(fee)) revert PartialFill();
        if (params.amountSpecified < 0 && (specifiedIsZero ? delta.amount1() : delta.amount0()) <= 0) {
            revert NoSwapOutput();
        }

        _skim(key.toId(), sender, specifiedIsZero ? key.currency0 : key.currency1, fee);
        return (IHooks.afterSwap.selector, 0);
    }

    /// @dev Moves `fee` of `currency` from the PoolManager to the beneficiary, or to a credit, or to
    /// a deferred claim. Never reverts for a reason the beneficiary controls.
    function _skim(PoolId id, address sender, Currency currency, uint256 fee) internal {
        address to = beneficiary;
        totalSkimmed[currency] += fee;

        if (currency.isAddressZero()) {
            try poolManager.take(currency, address(this), fee) {
                if (to != address(0) && _send(to, fee, PUSH_GAS)) {
                    emit FeeDelivered(id, sender, currency, to, fee);
                    return;
                }
                _credit(currency, to, fee);
                emit FeeCredited(id, sender, currency, to, fee);
                return;
            } catch {}
        } else {
            if (to != address(0)) {
                try poolManager.take(currency, to, fee) {
                    emit FeeDelivered(id, sender, currency, to, fee);
                    return;
                } catch {}
            }
            try poolManager.take(currency, address(this), fee) {
                _credit(currency, to, fee);
                emit FeeCredited(id, sender, currency, to, fee);
                return;
            } catch {}
        }

        // The PoolManager cannot release the currency yet: hold the fee as an ERC-6909 claim. It is
        // already credited to the right party; `redeem` turns the claim into balance later.
        poolManager.mint(address(this), currency.toId(), fee);
        deferred[currency] += fee;
        _credit(currency, to, fee);
        emit FeeDeferred(id, sender, currency, to, fee);
    }

    function _credit(Currency currency, address to, uint256 amount) internal {
        if (to == address(0)) {
            unassigned[currency] += amount;
        } else {
            pending[to][currency] += amount;
            totalPending[currency] += amount;
        }
    }

    /// @notice Give fees earned before the first King to the beneficiary current now. Anyone may call.
    function assignUnassigned(Currency currency) external nonReentrant {
        address to = beneficiary;
        if (to == address(0)) revert NoBeneficiary();
        uint256 amount = unassigned[currency];
        if (amount == 0) revert NothingToDo();
        unassigned[currency] = 0;
        pending[to][currency] += amount;
        totalPending[currency] += amount;
        emit UnassignedAssigned(currency, to, amount);
    }

    /// @notice Pull the caller's credited fees in `currency` to `to`. Any deferred claim in that
    /// currency is redeemed first, so the payment never borrows from the worker pot.
    /// @dev Not callable from inside a PoolManager unlock while a claim is outstanding (`redeem`
    /// needs to unlock); call `redeem` from a plain transaction first in that case.
    function withdraw(Currency currency, address to) external nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = pending[msg.sender][currency];
        if (amount == 0) revert NothingToDo();
        pending[msg.sender][currency] = 0;
        totalPending[currency] -= amount;
        if (deferred[currency] != 0) _redeem(currency);
        _pay(currency, to, amount);
        emit Withdrawn(msg.sender, currency, to, amount);
    }

    /// @notice Turn every deferred claim in `currency` into hook balance. Anyone may call.
    function redeem(Currency currency) external nonReentrant {
        if (deferred[currency] == 0) revert NothingToDo();
        _redeem(currency);
    }

    function _redeem(Currency currency) internal {
        poolManager.unlock(abi.encode(currency));
    }

    /// @inheritdoc IUnlockCallback
    /// @dev Only reachable through `_redeem`: the PoolManager calls back whoever called `unlock`.
    /// Burns the hook's claim (+amount) and takes the same amount out (-amount): net zero.
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        Currency currency = abi.decode(data, (Currency));
        uint256 amount = deferred[currency];
        deferred[currency] = 0;
        poolManager.burn(address(this), currency.toId(), amount);
        poolManager.take(currency, address(this), amount);
        emit Redeemed(currency, amount);
        return "";
    }

    // ---------------------------------------------------------------------------------------------
    // King of the pad
    // ---------------------------------------------------------------------------------------------

    /// @notice Become King. `msg.value` must exceed `claimPrice`; every wei goes to the worker pot.
    /// The previous King is never paid from the bid. There are no refunds and no expiry.
    /// @param newBeneficiary Nonzero address that receives swap fees while this claim stands: an
    /// EOA, a smart wallet or any contract with a pull path (see `withdraw`).
    /// @dev Next price = paid + ceil(paid * BUMP_BPS / 10_000).
    function claimKing(address newBeneficiary) external payable nonReentrant {
        if (newBeneficiary == address(0)) revert ZeroAddress();
        uint256 price = claimPrice;
        if (msg.value <= price) revert BidTooLow(price);
        uint256 nextPrice = msg.value + (msg.value * BUMP_BPS + BPS_DENOMINATOR - 1) / BPS_DENOMINATOR;
        king = msg.sender;
        beneficiary = newBeneficiary;
        claimPrice = nextPrice;
        uint256 id = ++claimCount;
        workerPot += msg.value;
        emit KingClaimed(msg.sender, newBeneficiary, msg.value, nextPrice, id);
    }

    // ---------------------------------------------------------------------------------------------
    // Worker pot: Merkle epochs published by the updater after off-chain oracle attestation
    // ---------------------------------------------------------------------------------------------

    /// @notice Voluntary funding of the worker pot by anyone.
    function fundWorkers() external payable {
        if (msg.value == 0) revert NothingToDo();
        workerPot += msg.value;
        emit WorkersFunded(msg.sender, msg.value);
    }

    /// @notice ETH the next epoch would receive: the pot plus whatever the ended epoch left unclaimed.
    function availableForNextEpoch() external view returns (uint256) {
        uint256 id = currentEpoch;
        if (id == 0) return workerPot;
        Epoch storage prev = epochs[id];
        if (block.timestamp < prev.windowEnd) return workerPot;
        return workerPot + (prev.budget - prev.paid);
    }

    /// @notice Open the next epoch with an attested root. The whole pot becomes its budget; the
    /// previous epoch's unclaimed remainder rolls into it first.
    /// @dev Only after the previous epoch's `windowEnd` has passed. The updater is expected to call
    /// this only once the off-chain Identity MD oracle (panelSize 70, quorum 67, bool) attested the
    /// root; the contract can verify the updater and the proofs, never the attestation.
    function setEpoch(bytes32 root, uint64 windowStart, uint64 windowEnd) external nonReentrant {
        if (msg.sender != updater) revert NotUpdater();
        if (
            root == bytes32(0) || windowEnd <= windowStart || windowEnd <= block.timestamp
                || windowEnd - windowStart > MAX_EPOCH_WINDOW
        ) revert InvalidWindow();
        uint256 id = currentEpoch;
        uint256 budget = workerPot;
        if (id != 0) {
            Epoch storage prev = epochs[id];
            if (block.timestamp < prev.windowEnd) revert EpochStillOpen();
            budget += prev.budget - prev.paid;
        }
        if (budget == 0) revert EmptyPot();
        workerPot = 0;
        id += 1;
        currentEpoch = id;
        epochs[id] =
            Epoch({root: root, windowStart: windowStart, windowEnd: windowEnd, budget: budget, paid: 0});
        emit EpochSet(id, root, windowStart, windowEnd, budget);
    }

    /// @notice StandardMerkleTree-style double-hashed leaf, bound to chain, contract and epoch.
    function leaf(uint256 epochId, address payee, uint256 amount) public view returns (bytes32) {
        return
            keccak256(
                bytes.concat(keccak256(abi.encode(block.chainid, address(this), epochId, payee, amount)))
            );
    }

    /// @notice Pay `amount` to `payee` from epoch `epochId`. Anyone may relay; ETH always goes to
    /// the leaf's payee, once per epoch.
    function claimWorker(uint256 epochId, address payable payee, uint256 amount, bytes32[] calldata proof)
        external
        nonReentrant
    {
        if (epochId == 0 || epochId != currentEpoch) revert InvalidEpoch();
        Epoch storage epoch = epochs[epochId];
        if (block.timestamp < epoch.windowStart || block.timestamp >= epoch.windowEnd) {
            revert OutsideWindow();
        }
        if (payee == address(0) || amount == 0 || claimed[epochId][payee]) revert InvalidClaim();
        if (amount > epoch.budget - epoch.paid) revert InsufficientBudget();
        if (!_verify(proof, epoch.root, leaf(epochId, payee, amount))) revert InvalidProof();
        claimed[epochId][payee] = true;
        epoch.paid += amount;
        if (deferred[CurrencyLibrary.ADDRESS_ZERO] != 0) _redeem(CurrencyLibrary.ADDRESS_ZERO);
        if (!_send(payee, amount, gasleft())) revert PaymentFailed();
        emit WorkerPaid(epochId, payee, amount, msg.sender);
    }

    /// @notice Start handing the updater role to `next`. Zero cancels a pending handoff.
    function proposeUpdater(address next) external {
        if (msg.sender != updater) revert NotUpdater();
        pendingUpdater = next;
        emit UpdaterProposed(msg.sender, next);
    }

    /// @notice Complete the handoff. Only the proposed address can, so a typo cannot lose the role.
    function acceptUpdater() external {
        address next = pendingUpdater;
        if (next == address(0) || msg.sender != next) revert NotPendingUpdater();
        address previous = updater;
        updater = next;
        pendingUpdater = address(0);
        emit UpdaterChanged(previous, next);
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    /// @dev Sorted-pair Merkle proof, compatible with OpenZeppelin `MerkleProof` and StandardMerkleTree.
    function _verify(bytes32[] calldata proof, bytes32 root, bytes32 node) internal pure returns (bool) {
        for (uint256 i = 0; i < proof.length; i++) {
            bytes32 sibling = proof[i];
            node = node < sibling
                ? keccak256(abi.encodePacked(node, sibling))
                : keccak256(abi.encodePacked(sibling, node));
        }
        return node == root;
    }

    /// @dev Full-gas payment used by `withdraw`; reverts if the recipient refuses.
    function _pay(Currency currency, address to, uint256 amount) internal {
        if (currency.isAddressZero()) {
            if (!_send(to, amount, gasleft())) revert PaymentFailed();
        } else {
            currency.transfer(to, amount);
        }
    }

    /// @dev Plain ETH send that ignores return data, so a recipient cannot return-bomb the hook.
    function _send(address to, uint256 amount, uint256 gasBudget) internal returns (bool ok) {
        assembly ("memory-safe") {
            ok := call(gasBudget, to, amount, 0, 0, 0, 0)
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Callbacks this hook does not enable. Their address bits are off, so the PoolManager never calls
    // them; they exist to satisfy IHooks and refuse everyone.
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IHooks
    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }
}
