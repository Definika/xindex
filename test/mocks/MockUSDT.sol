// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Mimics mainnet USDT: 6 decimals, transfer/transferFrom/approve return nothing,
///         and approve reverts when changing a non-zero allowance to another non-zero value. Its fee switch works like
///         mainnet's `setParams`: the recipient gets `value` less `min(value * basisPoints / 10_000, maxFee)` and the
///         deployer the fee, while the sender pays `value`. Mainnet caps the rate below 20 basis points; the mock does
///         not, so a test can charge a whole transfer. Its freezes are mainnet's too: `transfer` checks only the
///         sender and `transferFrom` only `from`, never the recipient or the caller, both stop while paused, and the
///         owner can zero a blacklisted balance with `destroyBlackFunds`.
contract MockUSDT {
    string public constant name = "Tether USD";
    string public constant symbol = "USDT";
    uint8 public constant decimals = 6;

    uint256 public totalSupply;
    address public immutable owner = msg.sender;
    uint256 public basisPointsRate;
    uint256 public maximumFee;
    bool public paused;
    mapping(address => bool) public isBlackListed;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    /// @notice The fee switch; `newMaxFee` is in whole tokens, as on mainnet.
    function setParams(uint256 newBasisPoints, uint256 newMaxFee) external {
        require(msg.sender == owner, "USDT: owner");
        basisPointsRate = newBasisPoints;
        maximumFee = newMaxFee * 10 ** decimals;
    }

    function pause() external {
        require(msg.sender == owner, "USDT: owner");
        paused = true;
    }

    function unpause() external {
        require(msg.sender == owner, "USDT: owner");
        paused = false;
    }

    function addBlackList(address user) external {
        require(msg.sender == owner, "USDT: owner");
        isBlackListed[user] = true;
    }

    function removeBlackList(address user) external {
        require(msg.sender == owner, "USDT: owner");
        isBlackListed[user] = false;
    }

    function destroyBlackFunds(address user) external {
        require(msg.sender == owner, "USDT: owner");
        require(isBlackListed[user], "USDT: not blacklisted");
        totalSupply -= balanceOf[user];
        balanceOf[user] = 0;
    }

    function approve(address spender, uint256 value) external {
        require(!(value != 0 && allowance[msg.sender][spender] != 0), "USDT: approve from non-zero");
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
    }

    function transfer(address to, uint256 value) external {
        require(!paused, "USDT: paused");
        require(!isBlackListed[msg.sender], "USDT: blacklisted");
        _transfer(msg.sender, to, value);
    }

    function transferFrom(address from, address to, uint256 value) external {
        require(!paused, "USDT: paused");
        require(!isBlackListed[from], "USDT: blacklisted");
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= value, "USDT: allowance");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - value;
        _transfer(from, to, value);
    }

    function _transfer(address from, address to, uint256 value) internal {
        require(balanceOf[from] >= value, "USDT: balance");
        uint256 fee = value * basisPointsRate / 10_000;
        if (fee > maximumFee) fee = maximumFee;
        balanceOf[from] -= value;
        balanceOf[to] += value - fee;
        emit Transfer(from, to, value - fee);
        if (fee > 0) {
            balanceOf[owner] += fee;
            emit Transfer(from, owner, fee);
        }
    }
}
