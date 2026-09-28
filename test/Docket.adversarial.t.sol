// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Docket} from "../src/Docket.sol";
import {FuzzBase} from "./helpers/FuzzBase.sol";
import {Vm} from "./helpers/TestBase.sol";

/// @dev A caller that has code. Docket attributes its calls to the contract, not to whoever
///      deployed or drives it.
contract Voter {
    function vote(Docket docket, uint256 ideaId, uint256 commentId) external {
        docket.upvote(ideaId, commentId);
    }

    function create(Docket docket) external returns (uint256) {
        return docket.createIdea("from a contract", "b");
    }
}

/// @notice Inputs the accepted suite leaves open: contract callers, duplicate voters, ids under
///         interleaved rejections, vote-key scoping, votes surviving later activity, and the
///         structural absence of any external call, which is what makes reentrancy impossible.
/// forge-config: default.fuzz.runs = 512
contract DocketAdversarialTest is FuzzBase {
    Docket private docket;

    function setUp() public {
        docket = new Docket();
    }

    /// @dev Docket never calls out, creates or self-destructs, so no caller can re-enter it and no
    ///      constructor-time trust is placed in msg.sender. Stepping over PUSH immediates keeps the
    ///      scan honest for constants that happen to contain these bytes.
    function testRuntimeHasNoExternalCallCreateOrSelfdestructOpcodes() public view {
        bytes memory code = address(docket).code;
        assert(code.length > 0 && code.length <= 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assert(op != 0xf0 && op != 0xf5); // CREATE, CREATE2
            assert(op != 0xf1 && op != 0xf2 && op != 0xf4 && op != 0xfa); // CALL, CALLCODE, DELEGATECALL, STATICCALL
            assert(op != 0xff); // SELFDESTRUCT
        }
    }

    /// @dev A vote is one per address, and a contract is an address of its own: two fresh
    ///      contracts and their deployer are three voters. That is the accepted design of a
    ///      permissionless board, recorded here so nobody reads the vote count as a head count.
    function testContractCallersVoteAsThemselvesOncePerAddress() public {
        docket.createIdea("t", "b");
        Voter a = new Voter();
        Voter b = new Voter();
        a.vote(docket, 1, 0);
        b.vote(docket, 1, 0);
        docket.upvote(1, 0);
        assert(docket.upvotes(1, 0) == 3);
        assert(docket.hasUpvoted(1, 0, address(a)) && docket.hasUpvoted(1, 0, address(b)));
        assert(docket.hasUpvoted(1, 0, address(this)));

        vm.expectRevert(Docket.AlreadyUpvoted.selector);
        a.vote(docket, 1, 0);
        vm.expectRevert(Docket.AlreadyUpvoted.selector);
        b.vote(docket, 1, 0);
        assert(docket.upvotes(1, 0) == 3);

        // Authorship is likewise the contract's, not its deployer's.
        vm.recordLogs();
        assert(a.create(docket) == 2);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assert(logs.length == 1 && logs[0].topics[2] == bytes32(uint256(uint160(address(a)))));
    }

    /// @dev The vote count of a target is exactly the number of distinct addresses that voted on
    ///      it, whatever order duplicates arrive in.
    function testFuzzUpvoteCountEqualsDistinctVoters(address[] memory voters) public {
        docket.createIdea("t", "b");
        docket.comment(1, "c");
        uint256 n = voters.length > 16 ? 16 : voters.length;
        uint256 distinct;
        for (uint256 i; i < n; ++i) {
            bool seen;
            for (uint256 j; j < i && !seen; ++j) {
                seen = voters[j] == voters[i];
            }
            if (seen) vm.expectRevert(Docket.AlreadyUpvoted.selector);
            else ++distinct;
            vm.prank(voters[i]);
            docket.upvote(1, 1);
            assert(docket.upvotes(1, 1) == distinct);
            assert(docket.hasUpvoted(1, 1, voters[i]));
        }
        assert(docket.upvotes(1, 0) == 0 && docket.upvotes(1, 2) == 0);
    }

    /// @dev The last existing comment is votable, the next id is not, and the next id becomes
    ///      votable, including for the voter that was just rejected, once the comment exists.
    function testFuzzUpvoteCommentBoundaryIsInclusive(uint8 commentsRaw, address voter) public {
        uint256 n = _bound(commentsRaw, 0, 12);
        docket.createIdea("t", "b");
        for (uint256 i; i < n; ++i) {
            docket.comment(1, "c");
        }
        vm.prank(voter);
        docket.upvote(1, n);
        assert(docket.upvotes(1, n) == 1);

        vm.expectRevert(Docket.UnknownComment.selector);
        vm.prank(voter);
        docket.upvote(1, n + 1);
        assert(docket.upvotes(1, n + 1) == 0 && !docket.hasUpvoted(1, n + 1, voter));

        assert(docket.comment(1, "late") == n + 1);
        vm.prank(voter);
        docket.upvote(1, n + 1);
        assert(docket.upvotes(1, n + 1) == 1 && docket.hasUpvoted(1, n + 1, voter));
        assert(docket.upvotes(1, n) == 1);
    }

    /// @dev Rejected calls never consume an id: after any interleaving of valid and invalid calls
    ///      the ids are dense from one to the count, and the count plus one is still unknown.
    function testFuzzIdsStayDenseAcrossInterleavedRejections(uint256 seed) public {
        uint256 ideas;
        uint256 commentsOnFirst;
        for (uint256 step; step < 24; ++step) {
            uint256 kind = uint256(keccak256(abi.encode(seed, step))) % 6;
            if (kind == 0) {
                assert(docket.createIdea("t", "b") == ++ideas);
            } else if (kind == 1) {
                vm.expectRevert(Docket.BadLength.selector);
                docket.createIdea("", "b");
            } else if (kind == 2) {
                if (ideas == 0) {
                    vm.expectRevert(Docket.UnknownIdea.selector);
                    docket.comment(1, "b");
                } else {
                    assert(docket.comment(1, "b") == ++commentsOnFirst);
                }
            } else if (kind == 3) {
                vm.expectRevert(Docket.UnknownIdea.selector);
                docket.comment(ideas + 1, "b");
            } else if (kind == 4) {
                vm.expectRevert(ideas == 0 ? Docket.UnknownIdea.selector : Docket.BadLength.selector);
                docket.comment(1, filled(2001));
            } else {
                vm.expectRevert(Docket.UnknownIdea.selector);
                docket.upvote(ideas + 1, 0);
            }
            assert(docket.ideaCount() == ideas && docket.commentCount(1) == commentsOnFirst);
        }
        for (uint256 id = 1; id <= ideas; ++id) {
            assert(docket.comment(id, "probe") == (id == 1 ? commentsOnFirst + 1 : 1));
            docket.upvote(id, 0);
        }
        vm.expectRevert(Docket.UnknownIdea.selector);
        docket.comment(ideas + 1, "probe");
        vm.expectRevert(Docket.UnknownIdea.selector);
        docket.upvote(ideas + 1, 0);
        assert(docket.ideaCount() == ideas);
    }

    /// @dev Later ideas and comments neither move nor unlock an earlier vote.
    function testFuzzVotesAreUnaffectedByLaterIdeasAndComments(uint8 laterRaw, address voter) public {
        docket.createIdea("t", "b");
        docket.comment(1, "c");
        vm.prank(voter);
        docket.upvote(1, 1);
        vm.prank(voter);
        docket.upvote(1, 0);

        uint256 later = _bound(laterRaw, 1, 20);
        for (uint256 i; i < later; ++i) {
            assert(docket.createIdea("n", "b") == i + 2);
            assert(docket.comment(1, "n") == i + 2);
            assert(docket.comment(i + 2, "n") == 1);
        }
        assert(docket.upvotes(1, 1) == 1 && docket.upvotes(1, 0) == 1);
        for (uint256 id = 2; id <= later + 1; ++id) {
            assert(docket.upvotes(id, 0) == 0 && docket.upvotes(id, 1) == 0);
            assert(!docket.hasUpvoted(id, 0, voter) && !docket.hasUpvoted(id, 1, voter));
        }
        for (uint256 c = 2; c <= later + 1; ++c) {
            assert(docket.upvotes(1, c) == 0 && !docket.hasUpvoted(1, c, voter));
        }
        vm.expectRevert(Docket.AlreadyUpvoted.selector);
        vm.prank(voter);
        docket.upvote(1, 1);
        vm.prank(voter);
        docket.upvote(later + 1, 1);
        assert(docket.upvotes(later + 1, 1) == 1);
    }

    /// @dev One vote sets exactly one (idea, comment, voter) record. Swapped coordinates, the
    ///      neighbouring targets and every other voter stay clear.
    function testFuzzVoteRecordIsScopedToExactTargetAndVoter(uint256 targetSeed, address voter, address other) public {
        docket.createIdea("one", "b");
        docket.createIdea("two", "b");
        docket.comment(1, "c");
        docket.comment(1, "c");
        docket.comment(2, "c");
        uint256[2][5] memory targets =
            [[uint256(1), 0], [uint256(1), 1], [uint256(1), 2], [uint256(2), 0], [uint256(2), 1]];
        uint256 pick = targetSeed % targets.length;
        vm.prank(voter);
        docket.upvote(targets[pick][0], targets[pick][1]);
        for (uint256 t; t < targets.length; ++t) {
            bool isPick = t == pick;
            uint256 ideaId = targets[t][0];
            uint256 commentId = targets[t][1];
            assert(docket.upvotes(ideaId, commentId) == (isPick ? 1 : 0));
            assert(docket.hasUpvoted(ideaId, commentId, voter) == isPick);
            assert(docket.hasUpvoted(ideaId, commentId, other) == (isPick && other == voter));
        }
        // Nonexistent neighbours of the chosen target hold nothing either.
        assert(docket.upvotes(3, 0) == 0 && docket.upvotes(0, targets[pick][1]) == 0);
        assert(!docket.hasUpvoted(0, 0, voter) && !docket.hasUpvoted(type(uint256).max, 0, voter));
    }

    /// @dev Both limits at once: the largest accepted idea and comment, then one byte more on
    ///      each field in turn, from a fuzzed caller.
    function testFuzzLimitsHoldTogether(address caller) public {
        string memory title = filled(120);
        string memory body = filled(4000);
        string memory commentBody = filled(2000);
        vm.prank(caller);
        assert(docket.createIdea(title, body) == 1);
        vm.prank(caller);
        assert(docket.comment(1, commentBody) == 1);

        vm.expectRevert(Docket.BadLength.selector);
        vm.prank(caller);
        docket.createIdea(filled(121), body);
        vm.expectRevert(Docket.BadLength.selector);
        vm.prank(caller);
        docket.createIdea(title, filled(4001));
        vm.expectRevert(Docket.BadLength.selector);
        vm.prank(caller);
        docket.comment(1, filled(2001));
        assert(docket.ideaCount() == 1 && docket.commentCount(1) == 1);
    }

    /// @dev Voting on the highest possible idea id works and touches no other id.
    function testVoteAtMaximumIdeaId() public {
        vm.store(address(docket), bytes32(uint256(0)), bytes32(type(uint256).max - 1));
        assert(docket.createIdea("last", "b") == type(uint256).max);
        docket.upvote(type(uint256).max, 0);
        assert(docket.comment(type(uint256).max, "c") == 1);
        docket.upvote(type(uint256).max, 1);
        assert(docket.upvotes(type(uint256).max, 0) == 1 && docket.upvotes(type(uint256).max, 1) == 1);
        assert(docket.upvotes(type(uint256).max - 1, 0) == 0 && docket.commentCount(type(uint256).max - 1) == 0);
        vm.expectRevert(Docket.UnknownIdea.selector);
        docket.upvote(0, 0);
    }
}
