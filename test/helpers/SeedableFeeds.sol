// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SwarmFeed} from "src/SwarmFeed.sol";
import {PriceFeed} from "src/PriceFeed.sol";
import {NhiFeed} from "src/NhiFeed.sol";
import {SpotFeed} from "src/SpotFeed.sol";
import {SwarmWorkOracle} from "src/SwarmWorkOracle.sol";

/// @notice Test-only seeding door for the pinned feed artifacts.
/// @dev With the reporter fallback deleted, a value reaches a feed only through a signed attestation —
/// and `PriceFeed`/`NhiFeed`/`SpotFeed` pin the oracle service's attester, whose key is not ours. A
/// suite that needs a priced feed therefore cannot use the shipped artifact directly, which is
/// correct: on mainnet we cannot seed one either.
///
/// These subclasses add `seed()` and change NOTHING else, so a test still exercises the real
/// artifact's question prefix, span policy, deviation bound and staleness. Nothing under `src/` or
/// `script/` references them, so they are absent from every deployment — the same containment
/// `ConfigurableSwarmFeed` relies on.
///
/// Tests that assert what a DEPLOYED feed is — its attester, its relayer, its pinned question —
/// must use the real artifact, not these. Tests that need a number in it use these.
contract SeedablePriceFeed is PriceFeed {
    constructor(uint256 maxAge_, uint256 maxDeviationBps_) PriceFeed(maxAge_, maxDeviationBps_) {}

    function seed(uint256 value) external {
        _accept(value, uint64(block.timestamp));
    }
}

contract SeedableNhiFeed is NhiFeed {
    constructor(uint256 maxAge_, uint256 maxDeviationBps_) NhiFeed(maxAge_, maxDeviationBps_) {}

    function seed(uint256 value) external {
        _accept(value, uint64(block.timestamp));
    }
}

contract SeedableSpotFeed is SpotFeed {
    constructor(uint256 maxAge_, uint256 maxDeviationBps_) SpotFeed(maxAge_, maxDeviationBps_) {}

    function seed(uint256 value) external {
        _accept(value, uint64(block.timestamp));
    }
}

/// @notice Seedable work oracle, and the factory that makes one.
/// @dev The vault creates its work oracle through `WorkOracleFactory`, whose address is a source
/// constant, so a test substitutes the whole factory rather than the oracle — `vm.etch` this one at
/// `WORK_ORACLE_FACTORY` and every vault built in that test gets a seedable oracle. The production
/// factory and the production oracle are untouched and expose no seeding door.
contract SeedableWorkOracle is SwarmWorkOracle {
    constructor(address vault_, uint256 maxAge_) SwarmWorkOracle(vault_, maxAge_) {}

    function seed(uint256 value) external {
        _accept(value, uint64(block.timestamp));
    }
}

contract SeedableWorkOracleFactory {
    event WorkOracleCreated(address indexed vault, address oracle);

    function create(uint256 maxAge_) external returns (SeedableWorkOracle oracle) {
        oracle = new SeedableWorkOracle(msg.sender, maxAge_);
        emit WorkOracleCreated(msg.sender, address(oracle));
    }
}
