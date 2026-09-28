// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TestBase} from "./TestBase.sol";

/// @dev Helpers shared by the adversarial and invariant suites: bounded inputs (constraints live in
///      the input, never in a discard), a fixed actor set with one contract caller, and exact
///      revert matching. Built on the project's own cheatcode shim; the project vendors no forge-std.
abstract contract FuzzBase is TestBase {
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA401);
    address internal constant DAVE = address(0xDA7E);
    address internal constant EVE = address(0xE5E);
    address internal constant STRANGER = address(0x57A9E);

    /// @dev Maps any fuzzed word into [min, max]. Never called with the full uint256 range.
    function _bound(uint256 x, uint256 min, uint256 max) internal pure returns (uint256) {
        assert(min <= max && max - min < type(uint256).max);
        return min + x % (max - min + 1);
    }

    function _revertedWith(bytes memory reason, bytes4 selector) internal pure returns (bool) {
        return keccak256(reason) == keccak256(abi.encodeWithSelector(selector));
    }

    /// @dev Five externally owned actors plus `self`, so every handler also drives the contract
    ///      from a caller that has code.
    function _actorSet(address self) internal pure returns (address[] memory set) {
        set = new address[](6);
        set[0] = self;
        set[1] = ALICE;
        set[2] = BOB;
        set[3] = CAROL;
        set[4] = DAVE;
        set[5] = EVE;
    }
}
