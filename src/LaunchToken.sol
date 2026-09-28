// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice The fixed-supply launch token the evm_project launch kind requires.
/// @dev Deployed by ProjectFactory alongside Docket. The whole supply is minted once, to the
///      deployer, in the constructor. There is no owner, mint, burn, pause, blocklist, fee,
///      hook or upgrade path, and Docket never references this contract.
contract LaunchToken {
    error InsufficientBalance();
    error InsufficientAllowance();
    error ZeroAddress();

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    string public constant name = "Docket";
    string public constant symbol = "DOCKET";
    uint8 public constant decimals = 18;
    /// @dev Exactly 1,000,000,000 tokens in minor units, as the launch reference requires.
    uint256 public constant totalSupply = 1_000_000_000e18;

    mapping(address account => uint256 balance) public balanceOf;
    mapping(address owner => mapping(address spender => uint256 amount)) public allowance;

    constructor() {
        balanceOf[msg.sender] = totalSupply;
        emit Transfer(address(0), msg.sender, totalSupply);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance();
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) private {
        if (to == address(0)) revert ZeroAddress();
        uint256 fromBalance = balanceOf[from];
        if (fromBalance < amount) revert InsufficientBalance();
        unchecked {
            balanceOf[from] = fromBalance - amount;
            // The supply is fixed at 1e27, so no balance can overflow uint256.
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }
}
