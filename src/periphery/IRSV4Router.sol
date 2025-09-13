// SPDX-License-Identifier: MIT
pragma solidity =0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IRSLiquidityCaps} from "../risk/IRSLiquidityCaps.sol";
import {IWETH9} from "../interfaces/IWETH.sol";
import {IIRSHook} from "../interfaces/IIRSHook.sol";

contract IRSV4Router is IUnlockCallback, ReentrancyGuard, Pausable, Ownable {
    function _payWethWithEth(uint256 amount) internal {
        WETH.deposit{value: amount}();
        WETH.transfer(address(MANAGER), amount);
        MANAGER.settle();
    }

    function _collectAsEthIfWeth(
        Currency currency,
        address to,
        uint256 amount,
        bool unwrapWeth
    ) internal {
        if (amount == 0) return;
        if (unwrapWeth && Currency.unwrap(currency) == address(WETH)) {
            MANAGER.take(currency, address(this), amount);
            WETH.withdraw(amount);
            (bool ok, ) = payable(to).call{value: amount}("");
            require(ok, "ETHSendFail");
        } else {
            MANAGER.take(currency, to, amount);
        }
    }

    // Funding settlement events
    event FundingSettled(
        address indexed owner,
        PoolKey key,
        int24 lower,
        int24 upper,
        int256 amountToken1
    );
    event TokensPaid(
        address indexed from,
        address indexed payer,
        address indexed manager,
        address currency,
        uint256 amount
    );
    event TokensCollected(
        address indexed to,
        address indexed manager,
        address currency,
        uint256 amount
    );
    event RefundIssued(address indexed to, address currency, uint256 amount);

    // Funding settlement logic
    function settleFundingToken1(
        PoolKey calldata key,
        int24 lower,
        int24 upper,
        bytes32 salt,
        address owner,
        address recipient
    ) external nonReentrant whenNotPaused {
        // Assume hook is set as a public variable (IIRSHook)
        int256 amt = IIRSHook(address(key.hooks)).clearFundingOwedToken1(
            owner,
            key,
            lower,
            upper,
            salt
        );
        if (amt > 0) {
            // protocol owes owner token1
            _collect(key.currency1, recipient, uint256(amt));
        } else if (amt < 0) {
            // owner owes protocol token1
            _pay(key.currency1, owner, uint256(-amt));
        }
        emit FundingSettled(owner, key, lower, upper, amt);
    }

    // Use SafeERC20 for all ERC-20 flows
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    IPoolManager public immutable MANAGER;
    IWETH9 public immutable WETH;
    IRSLiquidityCaps public immutable CAPS;

    event AddLiquidity(
        address indexed lp,
        PoolId indexed id,
        int24 lower,
        int24 upper,
        int256 liquidityDelta
    );
    event RemoveLiquidity(
        address indexed lp,
        PoolId indexed id,
        int24 lower,
        int24 upper,
        int256 liquidityDelta
    );
    event Swap(
        address indexed trader,
        PoolId indexed id,
        bool zeroForOne,
        int256 amountSpecified
    );
    event Rollover(address indexed lp, PoolId fromId, PoolId toId, uint128 qty);

    // governance pause gates
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    constructor(
        IPoolManager _manager,
        IWETH9 _weth,
        IRSLiquidityCaps _caps,
        address admin
    ) Ownable(admin) {
        MANAGER = _manager;
        WETH = _weth;
        CAPS = _caps;
    }

    function multicall(
        bytes[] calldata data
    ) external payable returns (bytes[] memory results) {
        results = new bytes[](data.length);
        for (uint256 i = 0; i < data.length; i++) {
            (bool ok, bytes memory ret) = address(this).delegatecall(data[i]);
            require(ok, "MCALL_FAIL");
            results[i] = ret;
        }
    }

    function permitERC20(
        address token,
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        IERC20Permit(token).permit(owner, spender, value, deadline, v, r, s);
    }

    struct AddLiq {
        PoolKey key;
        ModifyLiquidityParams params;
        bytes hookData;
        uint256 amount0; // max to pay
        uint256 amount1; // max to pay
        bool useNative0;
        bool useNative1;
    }

    function addLiquidity(
        AddLiq calldata a
    )
        external
        payable
        whenNotPaused
        returns (BalanceDelta callerDelta, BalanceDelta feesAccrued)
    {
        // caps check (per-pool cap + allowlist)
        require(
            CAPS.canAdd(msg.sender, a.key.toId(), a.params.liquidityDelta),
            "CAPS"
        );

    bytes memory ret = MANAGER.unlock(abi.encode(keccak256("ADD_LIQ"), msg.sender, a));
    (callerDelta, feesAccrued) = abi.decode(ret, (BalanceDelta, BalanceDelta));

        emit AddLiquidity(
            msg.sender,
            a.key.toId(),
            a.params.tickLower,
            a.params.tickUpper,
            a.params.liquidityDelta
        );
    }

    struct RemoveLiq {
        PoolKey key;
        ModifyLiquidityParams params; // negative liquidityDelta
        bytes hookData;
        address to;
    }

    function removeLiquidity(
        RemoveLiq calldata r
    )
        external
        whenNotPaused
        returns (BalanceDelta callerDelta, BalanceDelta feesAccrued)
    {
        bytes memory ret = MANAGER.unlock(abi.encode(keccak256("REM_LIQ"), msg.sender, r));
        (callerDelta, feesAccrued) = abi.decode(ret, (BalanceDelta, BalanceDelta));
        emit RemoveLiquidity(
            msg.sender,
            r.key.toId(),
            r.params.tickLower,
            r.params.tickUpper,
            r.params.liquidityDelta
        );
    }

    struct SwapEx {
        PoolKey key;
        SwapParams params;
        bytes hookData;
        uint256 maxPay; // for exact-input
        bool useNative; // if paying native on input side
    }

    function swap(
        SwapEx calldata s
    )
        external
        payable
        whenNotPaused
        returns (BalanceDelta swapDelta)
    {
    bytes memory ret = MANAGER.unlock(abi.encode(keccak256("SWAP"), msg.sender, s));
    swapDelta = abi.decode(ret, (BalanceDelta));
        emit Swap(
            msg.sender,
            s.key.toId(),
            s.params.zeroForOne,
            s.params.amountSpecified
        );
    }

    struct RolloverParams {
        PoolKey fromKey;
        ModifyLiquidityParams removeParams; // negative delta
        PoolKey toKey;
        ModifyLiquidityParams addParams; // positive delta
    }

    function rollover(
        RolloverParams calldata r
    ) external whenNotPaused {
        // remove
        MANAGER.unlock(
            abi.encode(
                keccak256("REM_LIQ"),
                msg.sender,
                r.fromKey,
                r.removeParams,
                bytes("")
            )
        );
        MANAGER.unlock(
            abi.encode(
                keccak256("ADD_LIQ"),
                msg.sender,
                r.toKey,
                r.addParams,
                bytes("")
            )
        );
        emit Rollover(
            msg.sender,
            r.fromKey.toId(),
            r.toKey.toId(),
            uint128(uint256(r.addParams.liquidityDelta))
        );
    }

    /// @dev Called by PoolManager inside unlock() with our data; we execute the actual op.
    function unlockCallback(
        bytes calldata data
    ) external nonReentrant returns (bytes memory) {
        require(msg.sender == address(MANAGER), "NOT_PM");

        // Data format: abi.encode(opHash, sender, opStruct)
        bytes32 opHash = bytes32(data[0:32]);

        // ADD_LIQ: (bytes32, address, AddLiq)
        if (opHash == keccak256("ADD_LIQ")) {
            address sender;
            AddLiq memory a;
            (/*op*/, sender, a) = abi.decode(data, (bytes32, address, AddLiq));

            (BalanceDelta cd, BalanceDelta fa) = MANAGER.modifyLiquidity(
                a.key,
                a.params,
                a.hookData
            );

            // combine caller delta and fees accrued for settlement decisions
            BalanceDelta sum = cd + fa;
            int128 a0 = sum.amount0();
            int128 a1 = sum.amount1();
            if (a0 < 0) {
                uint256 pay0 = uint256(uint128(uint256(-int256(a0))));
                require(pay0 <= a.amount0, "MAX_PAY0");
                _pay(a.key.currency0, sender, pay0);
            } else if (a0 > 0) {
                _collect(a.key.currency0, sender, uint256(int256(a0)));
            }

            if (a1 < 0) {
                uint256 pay1 = uint256(uint128(uint256(-int256(a1))));
                require(pay1 <= a.amount1, "MAX_PAY1");
                _pay(a.key.currency1, sender, pay1);
            } else if (a1 > 0) {
                _collect(a.key.currency1, sender, uint256(int256(a1)));
            }

            return abi.encode(cd, fa);
        }

        // REM_LIQ: (bytes32, address, RemoveLiq)
        if (opHash == keccak256("REM_LIQ")) {
            address sender;
            RemoveLiq memory r;
            (/*op*/, sender, r) = abi.decode(data, (bytes32, address, RemoveLiq));

            (BalanceDelta cd, BalanceDelta fa) = MANAGER.modifyLiquidity(
                r.key,
                r.params,
                r.hookData
            );

            BalanceDelta sumRem = cd + fa;
            int128 ra0 = sumRem.amount0();
            int128 ra1 = sumRem.amount1();
            if (ra0 > 0) _collect(r.key.currency0, r.to, uint256(int256(ra0)));
            if (ra1 > 0) _collect(r.key.currency1, r.to, uint256(int256(ra1)));

            return abi.encode(cd, fa);
        }

        // SWAP: (bytes32, address, SwapEx)
        if (opHash == keccak256("SWAP")) {
            address sender;
            SwapEx memory s;
            (/*op*/, sender, s) = abi.decode(data, (bytes32, address, SwapEx));

            BalanceDelta sd = MANAGER.swap(s.key, s.params, s.hookData);

            int128 s0 = sd.amount0();
            int128 s1 = sd.amount1();
            if (s0 < 0) {
                uint256 pay0 = uint256(uint128(uint256(-int256(s0))));
                if (s.params.amountSpecified > 0) require(pay0 <= s.maxPay, "MAX_PAY");
                _pay(s.key.currency0, sender, pay0);
            } else if (s0 > 0) {
                _collect(s.key.currency0, sender, uint256(int256(s0)));
            }
            if (s1 < 0) {
                uint256 pay1 = uint256(uint128(uint256(-int256(s1))));
                if (s.params.amountSpecified > 0) require(pay1 <= s.maxPay, "MAX_PAY");
                _pay(s.key.currency1, sender, pay1);
            } else if (s1 > 0) {
                _collect(s.key.currency1, sender, uint256(int256(s1)));
            }

            return abi.encode(sd);
        }

        revert("BAD_OP");
    }

    function _prefund(
        Currency cur,
        address from,
        uint256 amount,
        bool useNative
    ) internal {
        if (amount == 0) return;
        if (Currency.unwrap(cur) == address(0)) {
            require(useNative, "NATIVE_FLAG");
            require(msg.value >= amount, "INSUFFICIENT_MSG_VALUE");
            // native settlement determined by msg.value – nothing else to do
        } else {
            address token = Currency.unwrap(cur);
            MANAGER.sync(cur);
            IERC20(token).safeTransferFrom(from, address(MANAGER), amount);
        }
    }

    // _pay and _collect helpers with events
    function _pay(Currency currency, address from, uint256 amount) internal {
        if (amount == 0) return;
        MANAGER.sync(currency);
        if (Currency.unwrap(currency) == address(0)) {
            MANAGER.settle{value: amount}();
            emit TokensPaid(
                from,
                from,
                address(MANAGER),
                Currency.unwrap(currency),
                amount
            );
        } else if (
            Currency.unwrap(currency) == address(WETH) && msg.value >= amount
        ) {
            _payWethWithEth(amount);
            if (msg.value > amount) {
                (bool ok, ) = payable(from).call{value: (msg.value - amount)}(
                    ""
                );
                require(ok, "RefundFail");
                emit RefundIssued(from, address(WETH), msg.value - amount);
            }
        } else {
            address token = Currency.unwrap(currency);
            IERC20(token).safeTransferFrom(from, address(MANAGER), amount);
            MANAGER.settle();
            emit TokensPaid(from, from, address(MANAGER), token, amount);
        }
    }

    function _collect(Currency currency, address to, uint256 amount) internal {
        if (amount == 0) return;
        MANAGER.take(currency, to, amount);
        address what = Currency.unwrap(currency) == address(0)
            ? address(0)
            : Currency.unwrap(currency);
        emit TokensCollected(to, address(MANAGER), what, amount);
    }

    function unwrapWETH(address to, uint256 amount) external onlyOwner {
        WETH.withdraw(amount);
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "SEND_FAIL");
    }

    receive() external payable {}
}
