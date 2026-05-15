// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IERC20 {
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract PaymentContract {
    address public owner;
    IERC20 public usdc;

    event PaymentReceived(address indexed from, uint256 amount);
    event FundsWithdrawn(address indexed to, uint256 amount);

    constructor(address usdcAddress) {
        owner = msg.sender;
        usdc = IERC20(usdcAddress);
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Not the owner!");
        _;
    }

    function pay(uint256 amount) public {
        require(amount > 0, "Amount must be greater than 0");
        usdc.transferFrom(msg.sender, address(this), amount);
        emit PaymentReceived(msg.sender, amount);
    }

    function withdraw() public onlyOwner {
        uint256 balance = usdc.balanceOf(address(this));
        require(balance > 0, "Nothing to withdraw");
        usdc.transfer(owner, balance);
        emit FundsWithdrawn(owner, balance);
    }

    function getBalance() public view returns (uint256) {
        return usdc.balanceOf(address(this));
    }
}