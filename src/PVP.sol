// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Pepe Values Pepe
/// @notice Fixed-issuance ERC-20. The zero-argument constructor mints exactly 10^27 minor units
/// (1,000,000,000 PVP at 18 decimals) to `msg.sender`, the launch factory, and nothing else, ever.
/// @dev Self-contained on purpose: no inherited library, no owner, no mint path, no pause, no proxy,
/// no hooks on transfer and no fee on transfer. Supply can only fall, through `burn`. The 10/80/10
/// allocation is the launch policy's business and is not encoded here.
contract PVP {
    string public constant name = "Pepe Values Pepe";
    string public constant symbol = "PVP";
    uint8 public constant decimals = 18;
    /// @notice 1,000,000,000 PVP in minor units. Never 10^24.
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 1e18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error InsufficientBalance(address account, uint256 balance, uint256 needed);
    error InsufficientAllowance(address spender, uint256 allowance, uint256 needed);
    error InvalidReceiver();

    constructor() {
        totalSupply = INITIAL_SUPPLY;
        balanceOf[msg.sender] = INITIAL_SUPPLY;
        emit Transfer(address(0), msg.sender, INITIAL_SUPPLY);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount);
        return true;
    }

    /// @notice Destroys `amount` of the caller's tokens. The only way supply changes after deployment.
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    /// @notice Destroys `amount` of `from`'s tokens using the caller's allowance.
    function burnFrom(address from, uint256 amount) external {
        _spendAllowance(from, msg.sender, amount);
        _burn(from, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal {
        if (to == address(0)) revert InvalidReceiver();
        uint256 fromBalance = balanceOf[from];
        if (fromBalance < amount) revert InsufficientBalance(from, fromBalance, amount);
        unchecked {
            balanceOf[from] = fromBalance - amount;
            // Sum of balances never exceeds totalSupply, so this cannot overflow.
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }

    function _burn(address from, uint256 amount) internal {
        uint256 fromBalance = balanceOf[from];
        if (fromBalance < amount) revert InsufficientBalance(from, fromBalance, amount);
        unchecked {
            balanceOf[from] = fromBalance - amount;
            totalSupply -= amount;
        }
        emit Transfer(from, address(0), amount);
    }

    function _spendAllowance(address owner, address spender, uint256 amount) internal {
        uint256 current = allowance[owner][spender];
        if (current != type(uint256).max) {
            if (current < amount) revert InsufficientAllowance(spender, current, amount);
            unchecked {
                allowance[owner][spender] = current - amount;
            }
        }
    }
}
