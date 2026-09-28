// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LaunchToken} from "../src/LaunchToken.sol";
import {FuzzBase} from "./helpers/FuzzBase.sol";

/// @dev The handler deploys the token, so it stands in for the factory and starts with the whole
///      supply. Six actors transfer, approve and spend allowances with amounts that land on zero,
///      the full balance, one over it and the maximum, and recipients that include address zero.
///      Ghost balances and allowances are the accounting the token must reproduce.
contract LaunchTokenHandler is FuzzBase {
    uint256 internal constant SUPPLY = 1_000_000_000e18;

    LaunchToken public immutable token;
    address[] private actors;

    mapping(address holder => uint256 balance) public ghostBalance;
    mapping(address owner => mapping(address spender => uint256 amount)) public ghostAllowance;
    uint256 public moved;
    uint256 public accepted;
    uint256 public rejected;

    constructor() {
        token = new LaunchToken();
        actors = _actorSet(address(this));
        ghostBalance[address(this)] = SUPPLY;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function actor(uint256 index) external view returns (address) {
        return actors[index];
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = actors[fromSeed % actors.length];
        address to = _recipient(toSeed);
        uint256 amount = _amount(amountSeed, ghostBalance[from]);
        bytes4 expected = to == address(0)
            ? LaunchToken.ZeroAddress.selector
            : amount > ghostBalance[from] ? LaunchToken.InsufficientBalance.selector : bytes4(0);

        vm.prank(from);
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(LaunchToken.transfer, (to, amount)));

        _settle(ok, ret, expected, from, to, amount);
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        uint256 amount = _amount(amountSeed, ghostBalance[owner]);

        vm.prank(owner);
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(LaunchToken.approve, (spender, amount)));

        assert(ok && abi.decode(ret, (bool)));
        ghostAllowance[owner][spender] = amount;
        ++accepted;
        assert(token.allowance(owner, spender) == amount);
    }

    function transferFrom(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address spender = actors[spenderSeed % actors.length];
        address from = actors[fromSeed % actors.length];
        address to = _recipient(toSeed);
        uint256 amount = _amount(amountSeed, ghostBalance[from]);
        uint256 allowed = ghostAllowance[from][spender];
        bytes4 expected;
        if (allowed != type(uint256).max && allowed < amount) expected = LaunchToken.InsufficientAllowance.selector;
        else if (to == address(0)) expected = LaunchToken.ZeroAddress.selector;
        else if (amount > ghostBalance[from]) expected = LaunchToken.InsufficientBalance.selector;

        vm.prank(spender);
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(LaunchToken.transferFrom, (from, to, amount)));

        if (expected == bytes4(0) && allowed != type(uint256).max) ghostAllowance[from][spender] = allowed - amount;
        _settle(ok, ret, expected, from, to, amount);
        assert(token.allowance(from, spender) == ghostAllowance[from][spender]);
    }

    /// @dev The mint and admin shapes the protected token floor probes, from a random actor.
    function probeAdmin(uint256 actorSeed, uint256 selectorSeed) external {
        address caller = actors[actorSeed % actors.length];
        string[9] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "setMinter(address)"
        ];
        bytes memory data = abi.encodeWithSignature(signatures[selectorSeed % signatures.length], caller, SUPPLY);
        vm.prank(caller);
        (bool ok,) = address(token).call(data);
        assert(!ok);
        ++rejected;
        assert(token.totalSupply() == SUPPLY && token.balanceOf(caller) == ghostBalance[caller]);
    }

    function sendEther(uint256 amountSeed) external {
        uint256 amount = _bound(amountSeed, 1, 10 ether);
        vm.deal(address(this), amount);
        (bool ok,) = address(token).call{value: amount}("");
        assert(!ok && address(token).balance == 0);
        ++rejected;
    }

    function _settle(bool ok, bytes memory ret, bytes4 expected, address from, address to, uint256 amount) private {
        uint256 fromBefore = ghostBalance[from];
        uint256 toBefore = ghostBalance[to];
        if (expected == bytes4(0)) {
            assert(ok && abi.decode(ret, (bool)));
            ghostBalance[from] = fromBefore - amount;
            ghostBalance[to] += amount;
            moved += amount;
            ++accepted;
        } else {
            assert(!ok && _revertedWith(ret, expected));
            ++rejected;
        }
        assert(token.balanceOf(from) == ghostBalance[from]);
        assert(token.balanceOf(to) == ghostBalance[to]);
        // A self-transfer changes nothing; a rejected call changes nothing.
        if (from == to || expected != bytes4(0)) {
            assert(token.balanceOf(from) == fromBefore && token.balanceOf(to) == toBefore);
        }
    }

    /// @dev Zero, the exact balance, one over, the maximum, or a random amount within balance.
    function _amount(uint256 seed, uint256 balance) private pure returns (uint256) {
        uint256 mode = seed % 8;
        if (mode == 0) return 0;
        if (mode == 1) return balance;
        if (mode == 2) return balance + 1;
        if (mode == 3) return type(uint256).max;
        return _bound(seed / 8, 0, balance);
    }

    /// @dev One slot in seven is address zero, so the zero-recipient path is reached at random.
    function _recipient(uint256 seed) private view returns (address) {
        uint256 pick = seed % (actors.length + 1);
        return pick == actors.length ? address(0) : actors[pick];
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 32
contract LaunchTokenInvariantTest is FuzzBase {
    uint256 private constant SUPPLY = 1_000_000_000e18;

    LaunchTokenHandler private handler;
    LaunchToken private token;

    function setUp() public {
        handler = new LaunchTokenHandler();
        token = handler.token();
    }

    function targetContracts() external view returns (address[] memory targets) {
        targets = new address[](1);
        targets[0] = address(handler);
    }

    function invariant_totalSupplyIsFixed() public view {
        assert(token.totalSupply() == SUPPLY);
    }

    /// @dev Conservation: tokens only ever move between actors, so the actors together hold the
    ///      whole supply after any sequence, and nothing leaks to address zero or a stranger.
    function invariant_actorBalancesSumToSupply() public view {
        uint256 sum;
        for (uint256 a; a < handler.actorCount(); ++a) {
            uint256 balance = token.balanceOf(handler.actor(a));
            assert(balance <= SUPPLY);
            sum += balance;
        }
        assert(sum == SUPPLY);
        assert(token.balanceOf(address(0)) == 0 && token.balanceOf(STRANGER) == 0);
    }

    function invariant_balancesMatchGhost() public view {
        for (uint256 a; a < handler.actorCount(); ++a) {
            address holder = handler.actor(a);
            assert(token.balanceOf(holder) == handler.ghostBalance(holder));
        }
    }

    function invariant_allowancesMatchGhost() public view {
        uint256 count = handler.actorCount();
        for (uint256 i; i < count; ++i) {
            for (uint256 j; j < count; ++j) {
                address owner = handler.actor(i);
                address spender = handler.actor(j);
                assert(token.allowance(owner, spender) == handler.ghostAllowance(owner, spender));
            }
        }
        assert(token.allowance(handler.actor(0), STRANGER) == 0);
    }

    function invariant_tokenHoldsNoEther() public view {
        assert(address(token).balance == 0);
    }
}
