// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Docket} from "../src/Docket.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {TestBase, Vm} from "./helpers/TestBase.sol";

/// @dev Stands in for ProjectFactory: deploys the launch token and Docket with CREATE2 from one
///      address, so the tests check what the factory sees (deployer holds the whole supply,
///      Docket's constructor leaves it untouched) rather than what an EOA would.
contract FactoryStandIn {
    function deploy(bytes memory code, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        require(deployed != address(0) && deployed.code.length > 0, "constructor failed");
    }
}

contract LaunchTokenTest is TestBase {
    uint256 internal constant SUPPLY = 1_000_000_000e18;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    LaunchToken internal token;

    function setUp() public {
        token = new LaunchToken();
    }

    function testMetadataAndFixedSupply() public view {
        assert(same(token.name(), "Docket"));
        assert(same(token.symbol(), "DOCKET"));
        assert(token.decimals() == 18);
        assert(token.totalSupply() == SUPPLY);
        assert(token.totalSupply() == 10 ** 27);
        assert(token.balanceOf(address(this)) == SUPPLY);
    }

    function testConstructorMintsWholeSupplyToDeployerWithEvent() public {
        vm.recordLogs();
        LaunchToken fresh = new LaunchToken();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assert(logs.length == 1);
        assert(logs[0].emitter == address(fresh));
        assert(logs[0].topics[0] == keccak256("Transfer(address,address,uint256)"));
        assert(logs[0].topics[1] == bytes32(0));
        assert(logs[0].topics[2] == bytes32(uint256(uint160(address(this)))));
        assert(abi.decode(logs[0].data, (uint256)) == SUPPLY);
        assert(fresh.balanceOf(address(this)) == SUPPLY);
    }

    function testTransferMovesExactlyTheAmount() public {
        address alice = address(0xA11CE);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), alice, 1e18);
        assert(token.transfer(alice, 1e18));
        assert(token.balanceOf(alice) == 1e18);
        assert(token.balanceOf(address(this)) == SUPPLY - 1e18);
        assert(token.totalSupply() == SUPPLY);

        vm.prank(alice);
        assert(token.transfer(address(0xB0B), 4e17));
        assert(token.balanceOf(alice) == 6e17);
        assert(token.balanceOf(address(0xB0B)) == 4e17);
    }

    function testTransferRejectsInsufficientBalanceAndZeroRecipient() public {
        vm.expectRevert(LaunchToken.InsufficientBalance.selector);
        token.transfer(address(0xA11CE), SUPPLY + 1);

        vm.prank(address(0xA11CE));
        vm.expectRevert(LaunchToken.InsufficientBalance.selector);
        token.transfer(address(0xB0B), 1);

        vm.expectRevert(LaunchToken.ZeroAddress.selector);
        token.transfer(address(0), 1);

        assert(token.balanceOf(address(this)) == SUPPLY);
    }

    function testSelfTransferKeepsBalance() public {
        assert(token.transfer(address(this), 5e18));
        assert(token.balanceOf(address(this)) == SUPPLY);
        assert(token.transfer(address(this), SUPPLY));
        assert(token.balanceOf(address(this)) == SUPPLY);
    }

    function testApproveAndTransferFrom() public {
        address spender = address(0x5E11);
        address to = address(0xB0B);
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(address(this), spender, 3e18);
        assert(token.approve(spender, 3e18));
        assert(token.allowance(address(this), spender) == 3e18);

        vm.prank(spender);
        vm.expectRevert(LaunchToken.InsufficientAllowance.selector);
        token.transferFrom(address(this), to, 3e18 + 1);

        vm.prank(spender);
        assert(token.transferFrom(address(this), to, 2e18));
        assert(token.allowance(address(this), spender) == 1e18);
        assert(token.balanceOf(to) == 2e18);
        assert(token.balanceOf(address(this)) == SUPPLY - 2e18);

        vm.prank(spender);
        vm.expectRevert(LaunchToken.InsufficientAllowance.selector);
        token.transferFrom(address(this), to, 1e18 + 1);

        vm.prank(address(0xDEAD));
        vm.expectRevert(LaunchToken.InsufficientAllowance.selector);
        token.transferFrom(address(this), to, 1);
    }

    function testInfiniteAllowanceIsNotDecremented() public {
        address spender = address(0x5E11);
        assert(token.approve(spender, type(uint256).max));
        vm.prank(spender);
        assert(token.transferFrom(address(this), address(0xB0B), 7e18));
        assert(token.allowance(address(this), spender) == type(uint256).max);
        assert(token.balanceOf(address(0xB0B)) == 7e18);
    }

    function testTransferFromRejectsInsufficientBalanceEvenWithAllowance() public {
        address alice = address(0xA11CE);
        vm.prank(alice);
        token.approve(address(this), type(uint256).max);
        vm.expectRevert(LaunchToken.InsufficientBalance.selector);
        token.transferFrom(alice, address(0xB0B), 1);
    }

    function testFuzzTransferConservesSupply(address to, uint256 amount, uint256 back) public {
        if (to == address(0)) to = address(1);
        amount = amount % (SUPPLY + 1);
        assert(token.transfer(to, amount));
        if (to == address(this)) {
            assert(token.balanceOf(address(this)) == SUPPLY);
            return;
        }
        assert(token.balanceOf(to) == amount);
        assert(token.balanceOf(address(this)) == SUPPLY - amount);
        assert(token.balanceOf(to) + token.balanceOf(address(this)) == token.totalSupply());

        back = back % (amount + 1);
        vm.prank(to);
        assert(token.transfer(address(this), back));
        assert(token.balanceOf(to) == amount - back);
        assert(token.balanceOf(to) + token.balanceOf(address(this)) == token.totalSupply());

        vm.prank(to);
        vm.expectRevert(LaunchToken.InsufficientBalance.selector);
        token.transfer(address(this), amount - back + 1);
    }

    /// @dev The selectors the protected token floor probes. None exists, so every call reverts
    ///      and the supply and the attacker's balance never move.
    function testNoAdminOrMintSelectorExists() public {
        address attacker = address(0xBEEF);
        string[10] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], attacker, type(uint128).max);
            vm.prank(attacker);
            (bool ok,) = address(token).call(data);
            assert(!ok);
            assert(token.totalSupply() == SUPPLY);
            assert(token.balanceOf(attacker) == 0);
        }
        // Not even the deployer.
        (bool deployerOk,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", address(this), 1));
        assert(!deployerOk);
        assert(token.totalSupply() == SUPPLY);
    }

    function testRejectsEtherAndUnknownSelectors() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(token).call{value: 1}("");
        assert(!ok);
        (ok,) = address(token).call{value: 1}(abi.encodeWithSignature("transfer(address,uint256)", address(1), 1));
        assert(!ok);
        (ok,) = address(token).call(abi.encodeWithSignature("burn(uint256)", 1));
        assert(!ok);
        assert(address(token).balance == 0);
        assert(token.totalSupply() == SUPPLY);
    }

    /// @dev Mirrors the protected project floor: token and Docket deployed by one factory address,
    ///      the factory holds the whole supply, and Docket's constructor does not move it.
    function testFactoryDeploymentKeepsSupplyWithFactoryAcrossDocketConstructor() public {
        FactoryStandIn factory = new FactoryStandIn();
        LaunchToken launched = LaunchToken(factory.deploy(type(LaunchToken).creationCode, bytes32(uint256(1))));
        assert(launched.totalSupply() == SUPPLY);
        assert(launched.balanceOf(address(factory)) == SUPPLY);
        assert(launched.balanceOf(address(this)) == 0);

        Docket docket = Docket(factory.deploy(type(Docket).creationCode, bytes32(uint256(2))));
        assert(address(docket).code.length > 0);
        assert(docket.ideaCount() == 0);
        assert(launched.totalSupply() == SUPPLY);
        assert(launched.balanceOf(address(factory)) == SUPPLY);
    }

    function testRuntimeIsBoundedAndHasNoEscapeOpcodes() public {
        _scan(address(token).code);
        _scan(address(new Docket()).code);
    }

    function _scan(bytes memory code) private pure {
        assert(code.length > 0);
        assert(code.length <= 24_576);
        for (uint256 j; j < code.length; ++j) {
            uint8 op = uint8(code[j]);
            if (op >= 0x60 && op <= 0x7f) {
                j += op - 0x5f;
                continue;
            }
            assert(op != 0xf4 && op != 0xf2 && op != 0xff);
        }
    }
}
