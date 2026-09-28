// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Docket} from "../src/Docket.sol";
import {FuzzBase} from "./helpers/FuzzBase.sol";

/// @dev Drives Docket from six actors with inputs bounded to straddle every limit, so unknown
///      ideas, unknown comments, bad lengths, duplicate votes and ether all arrive at random
///      points of the sequence. Ghost state is what the contract should hold; the handler never
///      reverts (the run is configured to fail on revert) and asserts each call's outcome.
contract DocketActorHandler is FuzzBase {
    Docket public immutable docket;
    address[] private actors;

    uint256 public ghostIdeas;
    uint256 public ghostTotalComments;
    uint256 public ghostTotalVotes;
    mapping(uint256 ideaId => uint256 count) public ghostComments;
    mapping(uint256 ideaId => mapping(uint256 commentId => uint256 count)) public ghostUpvotes;
    mapping(uint256 ideaId => mapping(uint256 commentId => mapping(address voter => bool voted))) public ghostVoted;

    uint256 public calls;
    uint256 public accepted;
    uint256 public rejected;
    uint256 private lastIdeaCount;

    constructor(Docket target) {
        docket = target;
        actors = _actorSet(address(this));
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function actor(uint256 index) external view returns (address) {
        return actors[index];
    }

    function createIdea(uint256 actorSeed, uint256 titleSeed, uint256 bodySeed) external {
        address caller = actors[actorSeed % actors.length];
        uint256 titleLength = _length(titleSeed, 120);
        uint256 bodyLength = _length(bodySeed, 4000);
        bool valid = titleLength > 0 && titleLength <= 120 && bodyLength > 0 && bodyLength <= 4000;
        uint256 before = docket.ideaCount();

        vm.prank(caller);
        (bool ok, bytes memory ret) =
            address(docket).call(abi.encodeCall(Docket.createIdea, (filled(titleLength), filled(bodyLength))));

        if (valid) {
            assert(ok && abi.decode(ret, (uint256)) == before + 1);
            ++ghostIdeas;
            ++accepted;
        } else {
            assert(!ok && _revertedWith(ret, Docket.BadLength.selector));
            ++rejected;
        }
        assert(docket.ideaCount() == before + (valid ? 1 : 0));
        _afterCall();
    }

    function comment(uint256 actorSeed, uint256 ideaSeed, uint256 bodySeed) external {
        address caller = actors[actorSeed % actors.length];
        uint256 ideaId = _bound(ideaSeed, 0, ghostIdeas + 1);
        uint256 bodyLength = _length(bodySeed, 2000);
        bool ideaKnown = ideaId != 0 && ideaId <= ghostIdeas;
        bool lengthOk = bodyLength > 0 && bodyLength <= 2000;
        uint256 before = docket.commentCount(ideaId);

        vm.prank(caller);
        (bool ok, bytes memory ret) = address(docket).call(abi.encodeCall(Docket.comment, (ideaId, filled(bodyLength))));

        bool success;
        if (!ideaKnown) {
            assert(!ok && _revertedWith(ret, Docket.UnknownIdea.selector));
        } else if (!lengthOk) {
            assert(!ok && _revertedWith(ret, Docket.BadLength.selector));
        } else {
            assert(ok && abi.decode(ret, (uint256)) == before + 1);
            ++ghostComments[ideaId];
            ++ghostTotalComments;
            success = true;
        }
        if (success) ++accepted;
        else ++rejected;
        assert(docket.commentCount(ideaId) == before + (success ? 1 : 0));
        _afterCall();
    }

    function upvote(uint256 actorSeed, uint256 ideaSeed, uint256 commentSeed) external {
        address caller = actors[actorSeed % actors.length];
        uint256 ideaId = _bound(ideaSeed, 0, ghostIdeas + 1);
        uint256 commentId = _bound(commentSeed, 0, ghostComments[ideaId] + 1);
        bool ideaKnown = ideaId != 0 && ideaId <= ghostIdeas;
        bool commentKnown = commentId <= ghostComments[ideaId];
        bool already = ghostVoted[ideaId][commentId][caller];
        uint256 before = docket.upvotes(ideaId, commentId);

        vm.prank(caller);
        (bool ok, bytes memory ret) = address(docket).call(abi.encodeCall(Docket.upvote, (ideaId, commentId)));

        bool success;
        if (!ideaKnown) {
            assert(!ok && _revertedWith(ret, Docket.UnknownIdea.selector));
        } else if (!commentKnown) {
            assert(!ok && _revertedWith(ret, Docket.UnknownComment.selector));
        } else if (already) {
            assert(!ok && _revertedWith(ret, Docket.AlreadyUpvoted.selector));
        } else {
            assert(ok && ret.length == 0);
            ghostVoted[ideaId][commentId][caller] = true;
            ++ghostUpvotes[ideaId][commentId];
            ++ghostTotalVotes;
            success = true;
        }
        if (success) ++accepted;
        else ++rejected;
        assert(docket.upvotes(ideaId, commentId) == before + (success ? 1 : 0));
        assert(docket.hasUpvoted(ideaId, commentId, caller) == ghostVoted[ideaId][commentId][caller]);
        _afterCall();
    }

    /// @dev Ether is refused on every entry point, with the empty revert of a nonpayable function.
    function sendEther(uint256 amountSeed, uint256 entrySeed) external {
        uint256 amount = _bound(amountSeed, 1, 10 ether);
        vm.deal(address(this), amount);
        uint256 entry = entrySeed % 4;
        bytes memory data;
        if (entry == 1) data = abi.encodeCall(Docket.createIdea, ("t", "b"));
        else if (entry == 2) data = abi.encodeCall(Docket.comment, (1, "b"));
        else if (entry == 3) data = abi.encodeCall(Docket.upvote, (1, 0));

        (bool ok, bytes memory ret) = address(docket).call{value: amount}(data);
        assert(!ok && ret.length == 0);
        assert(address(docket).balance == 0);
        assert(docket.ideaCount() == ghostIdeas);
        ++rejected;
        _afterCall();
    }

    /// @dev Zero, one over the limit, or a length inside the accepted range.
    function _length(uint256 seed, uint256 max) private pure returns (uint256) {
        uint256 mode = seed % 6;
        if (mode == 0) return 0;
        if (mode == 1) return max + 1;
        if (mode == 2) return max;
        return _bound(seed / 6, 1, max);
    }

    function _afterCall() private {
        assert(docket.ideaCount() >= lastIdeaCount);
        lastIdeaCount = docket.ideaCount();
        ++calls;
        assert(calls == accepted + rejected);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 48
contract DocketActorsInvariantTest is FuzzBase {
    Docket private docket;
    DocketActorHandler private handler;

    function setUp() public {
        docket = new Docket();
        handler = new DocketActorHandler(docket);
    }

    function targetContracts() external view returns (address[] memory targets) {
        targets = new address[](1);
        targets[0] = address(handler);
    }

    function invariant_ideaCountEqualsGhost() public view {
        assert(docket.ideaCount() == handler.ghostIdeas());
    }

    /// @dev Every known idea's comment count matches the model, their sum is the number of
    ///      accepted comments, and no comment ever landed on id zero or beyond the last idea.
    function invariant_commentCountsEqualGhostAndAreZeroBeyondIdeas() public view {
        uint256 ideas = handler.ghostIdeas();
        uint256 sum;
        for (uint256 i = 1; i <= ideas; ++i) {
            uint256 count = docket.commentCount(i);
            assert(count == handler.ghostComments(i));
            sum += count;
        }
        assert(sum == handler.ghostTotalComments());
        assert(docket.commentCount(0) == 0 && docket.commentCount(ideas + 1) == 0);
        assert(docket.commentCount(type(uint256).max) == 0);
    }

    /// @dev Conservation: the upvotes over every existing target sum to the accepted votes, and
    ///      each target's count is exactly the number of actors the contract records as having
    ///      voted on it. Nobody's vote is counted twice or lost.
    function invariant_upvotesSumToAcceptedVotesAndMatchRecordedVoters() public view {
        uint256 ideas = handler.ghostIdeas();
        uint256 actorCount = handler.actorCount();
        uint256 sum;
        for (uint256 i = 1; i <= ideas; ++i) {
            uint256 comments = handler.ghostComments(i);
            for (uint256 c; c <= comments; ++c) {
                uint256 count = docket.upvotes(i, c);
                assert(count == handler.ghostUpvotes(i, c));
                uint256 recorded;
                for (uint256 a; a < actorCount; ++a) {
                    address voter = handler.actor(a);
                    bool voted = docket.hasUpvoted(i, c, voter);
                    assert(voted == handler.ghostVoted(i, c, voter));
                    if (voted) ++recorded;
                }
                assert(count == recorded && count <= actorCount);
                sum += count;
            }
            // The comment id after the last one is not a target.
            assert(docket.upvotes(i, comments + 1) == 0);
        }
        assert(sum == handler.ghostTotalVotes());
    }

    function invariant_unknownTargetsHoldNoVotes() public view {
        uint256 next = handler.ghostIdeas() + 1;
        assert(docket.upvotes(0, 0) == 0 && docket.upvotes(next, 0) == 0 && docket.upvotes(next, 1) == 0);
        for (uint256 a; a < handler.actorCount(); ++a) {
            address voter = handler.actor(a);
            assert(!docket.hasUpvoted(0, 0, voter) && !docket.hasUpvoted(next, 0, voter));
            assert(!docket.hasUpvoted(next, 1, voter));
        }
        assert(!docket.hasUpvoted(1, 0, STRANGER));
    }

    function invariant_docketHoldsNoEther() public view {
        assert(address(docket).balance == 0);
    }

    function invariant_everyCallWasAcceptedOrRejectedExactly() public view {
        assert(handler.calls() == handler.accepted() + handler.rejected());
        assert(handler.accepted() == handler.ghostIdeas() + handler.ghostTotalComments() + handler.ghostTotalVotes());
    }
}
