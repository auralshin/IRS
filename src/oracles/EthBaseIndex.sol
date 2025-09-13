// SPDX-License-Identifier: MIT
pragma solidity =0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IETHBaseIndex} from "../interfaces/IETHBaseIndex.sol";
import {IRateSource} from "../interfaces/IRateSource.sol";

/// -----------------------------------------------------------------------
/// @title EthBaseIndex
/// @notice Production-grade ETH APR index:
///         - Aggregates multiple sources (LSTs, Aave/Morpho adapters)
///         - Liveness check (max staleness)
///         - Deviation clamp (PPM bounds vs previous smoothed value)
///         - EMA smoothing
///         - Versioning on config/source changes
///         - Governance freeze & manual fallback rate
///         - Cumulative integral for funding settlement
/// @dev Implements IEthBaseIndex to stay drop-in compatible with your hook.
///      `setRatePerSecond` acts as a governance/manual override (and clears when disabled).
/// -----------------------------------------------------------------------
contract EthBaseIndex is IETHBaseIndex, Ownable {
    address public controller; // IRSController

    modifier onlyAuthorized() {
        _onlyAuthorized();
        _;
    }

    function _onlyAuthorized() internal view {
        require(msg.sender == owner() || msg.sender == controller, "NotAuthorized");
    }

    uint256 private constant ONE_PPM = 1_000_000; // parts-per-million

    // -------------------- storage: public API --------------------
    /// @inheritdoc IETHBaseIndex
    uint64 public override lastUpdate; // last checkpoint timestamp
    /// @notice EMA-smoothed effective rate per second (1e18)
    uint256 public override ratePerSecond; // current effective rate
    /// @notice cumulative integral of rate*dt (1e18 * seconds)
    uint256 public cumulative;

    // -------------------- configuration --------------------
    /// @notice EMA smoothing factor in PPM (e.g., 200_000 = 0.2)
    uint256 public alphaPPM;
    /// @notice allowable deviation bound vs previous smoothed value in PPM (e.g., 200_000 = 20%)
    uint256 public maxDeviationPPM;
    /// @notice maximum staleness allowed for a source to be considered "live" (seconds)
    uint64 public maxStale;
    /// @notice frozen flag (when true, updates are ignored; cumulative still projects linearly)
    bool public frozen;
    /// @notice bump on any config/source change (useful for off-chain subscribers)
    uint64 public version;

    address[] public sources;
    mapping(address => bool) public isSource;

    /// @notice if true, the aggregator uses `manualRatePerSecond` and ignores sources
    bool public useManualRate;
    /// @notice governance-set manual rate per second (1e18)
    uint256 public manualRatePerSecond;

    event SourceAdded(address indexed src);
    event SourceRemoved(address indexed src);
    event ParamsUpdated(uint256 alphaPPM, uint256 maxDeviationPPM, uint64 maxStale);
    event FreezeSet(bool frozen);
    event ManualRateSet(uint256 ratePerSecond, bool enabled);
    event VersionBumped(uint64 newVersion);
    event Updated(uint256 newRatePerSecond, uint256 newCumulative, uint64 at);

    constructor(
        address admin,
        uint256 _alphaPPM,
        uint256 _maxDeviationPPM,
        uint64 _maxStale,
        address[] memory initialSources
    ) Ownable(admin) {
        require(admin != address(0), "Admin=0");
        require(_alphaPPM <= ONE_PPM && _maxDeviationPPM <= ONE_PPM, "ppm");
        alphaPPM = _alphaPPM;
        maxDeviationPPM = _maxDeviationPPM;
        maxStale = _maxStale;

        // register sources
        for (uint256 i = 0; i < initialSources.length; i++) {
            address s = initialSources[i];
            require(s != address(0) && !isSource[s], "bad source");
            isSource[s] = true;
            sources.push(s);
            emit SourceAdded(s);
        }

        lastUpdate = uint64(block.timestamp);
        version = 1;
        emit VersionBumped(version);

        // initialize smoothed rate from guarded median (may be zero if no live sources)
        uint256 med = _guardedMedian(0); // pass 0 to treat "no previous" as unconstrained
        ratePerSecond = med;
        emit Updated(ratePerSecond, cumulative, lastUpdate);
    }

    function setController(address c) external onlyOwner {
        controller = c;
    }

    /// @inheritdoc IETHBaseIndex
    function setRatePerSecond(uint256 newRatePerSecond) external override onlyOwner {
        // This function acts as a *manual override* control.
        // - If you intend to enable manual, call setManualRate(newRatePerSecond, true).
        // - If you just want to update and keep current mode, we checkpoint and update the relevant field.
        _checkpoint(); // integrate up to now using current effective rate
        if (useManualRate) {
            manualRatePerSecond = newRatePerSecond;
        } else {
            // update smoothed rate directly (rarely used; mainly for emergency)
            ratePerSecond = newRatePerSecond;
        }
        emit ManualRateSet(newRatePerSecond, useManualRate);
        emit Updated(ratePerSecondEffective(), cumulative, lastUpdate);
    }

    /// @inheritdoc IETHBaseIndex
    function cumulativeIndex() external view override returns (uint256 cum, uint64 tstamp) {
        uint64 nowTs = uint64(block.timestamp);
        uint64 dt = nowTs - lastUpdate;
        cum = cumulative + ratePerSecondEffective() * dt;
        tstamp = nowTs;
    }

    function sourcesLength() external view returns (uint256) {
        return sources.length;
    }

    /// @notice current effective rate (manual if enabled, otherwise smoothed aggregator)
    function ratePerSecondEffective() public view returns (uint256) {
        return useManualRate ? manualRatePerSecond : ratePerSecond;
    }

    function addSource(address s) external onlyAuthorized {
        require(s != address(0) && !isSource[s], "bad source");
        isSource[s] = true;
        sources.push(s);
        version += 1;
        emit SourceAdded(s);
        emit VersionBumped(version);
    }

    function removeSource(address s) external onlyAuthorized {
        require(isSource[s], "not source");
        isSource[s] = false;
        for (uint256 i; i < sources.length; i++) {
            if (sources[i] == s) {
                sources[i] = sources[sources.length - 1];
                sources.pop();
                break;
            }
        }
        version += 1;
        emit SourceRemoved(s);
        emit VersionBumped(version);
    }

    function setParams(uint256 _alphaPPM, uint256 _maxDeviationPPM, uint64 _maxStale)
        external
        onlyAuthorized
    {
        require(_alphaPPM <= ONE_PPM && _maxDeviationPPM <= ONE_PPM, "ppm");
        alphaPPM = _alphaPPM;
        maxDeviationPPM = _maxDeviationPPM;
        maxStale = _maxStale;
        version += 1;
        emit ParamsUpdated(_alphaPPM, _maxDeviationPPM, _maxStale);
        emit VersionBumped(version);
    }

    function setFreeze(bool _frozen) external onlyAuthorized {
        _checkpoint();
        frozen = _frozen;
        version += 1;
        emit FreezeSet(_frozen);
        emit VersionBumped(version);
    }

    function setManualRate(uint256 newManualRatePerSecond, bool enable) external onlyAuthorized {
        _checkpoint();
        manualRatePerSecond = newManualRatePerSecond;
        useManualRate = enable;
        version += 1;
        emit ManualRateSet(newManualRatePerSecond, enable);
        emit VersionBumped(version);
        emit Updated(ratePerSecondEffective(), cumulative, lastUpdate);
    }

    /// @notice force a state checkpoint without changing parameters
    function checkpoint() external {
        _checkpoint();
    }

    /// @notice Pull-to-update: aggregates sources, applies guards, smooths via EMA,
    ///         and checkpoints the cumulative index. No-op if frozen or no time passed.
    function update() external {
        if (frozen) {
            // still checkpoint to move lastUpdate/cumulative with current effective rate
            _checkpoint();
            return;
        }
        _checkpoint();

        // if manual override is active, do not touch the smoothed rate
        if (useManualRate) return;

        uint256 prev = ratePerSecond == 0 ? _guardedMedian(0) : ratePerSecond;
        uint256 med = _guardedMedian(prev);

        // EMA: s_new = a*med + (1-a)*s_old
        uint256 a = alphaPPM; // 0..1e6
        uint256 sOld = ratePerSecond;
        uint256 sNew = (a * med + (ONE_PPM - a) * sOld) / ONE_PPM;

        ratePerSecond = sNew;
        emit Updated(ratePerSecond, cumulative, lastUpdate);
    }

    /// @dev Integrate effective rate over [lastUpdate, now].
    function _checkpoint() internal {
        uint64 nowTs = uint64(block.timestamp);
        if (nowTs <= lastUpdate) return;
        uint64 dt = nowTs - lastUpdate;
        cumulative += ratePerSecondEffective() * dt;
        lastUpdate = nowTs;
    }

    /// @dev Return median of live sources, clamped to maxDeviationPPM around `prev` if prev>0.
    ///      If no live sources, fall back to `prev` (or 0 if prev==0).
    function _guardedMedian(uint256 prev) internal view returns (uint256) {
        uint256 n = sources.length;
        if (n == 0) return prev; // no sources → return prev (may be 0 at boot)

        // collect live values
        uint256[] memory vals = new uint256[](n);
        uint256 m;
        for (uint256 i; i < n; i++) {
            address s = sources[i];
            if (!isSource[s]) continue;
            uint64 t = IRateSource(s).updatedAt();
            if (t == 0 || (block.timestamp - t) > maxStale) continue;
            vals[m++] = IRateSource(s).ratePerSecond();
        }
        if (m == 0) return prev; // no live → return prev

        // sort (insertion sort; m is expected small)
        for (uint256 i = 1; i < m; i++) {
            uint256 key = vals[i];
            uint256 j = i;
            while (j > 0 && vals[j - 1] > key) {
                vals[j] = vals[j - 1];
                unchecked {
                    j--;
                }
            }
            vals[j] = key;
        }
        uint256 median = vals[m / 2];

        if (prev == 0 || maxDeviationPPM == 0) return median;

        // clamp to deviation band around prev
        uint256 upper = (prev * (ONE_PPM + maxDeviationPPM)) / ONE_PPM;
        uint256 lower = (prev * (ONE_PPM - maxDeviationPPM)) / ONE_PPM;
        if (median > upper) return upper;
        if (median < lower) return lower;
        return median;
    }
}
