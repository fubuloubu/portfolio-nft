from vyper.interfaces import ERC20

implements: ERC20

interface ERC4626:
    # Underlying token that shares are in
    def underlying() -> address: view

    # Returns shares
    def calculateShares(underlyingAmount: uint256) -> uint256: view
    def deposit(receiver: address, amount: uint256) -> uint256: nonpayable
    def withdraw(sender: address, receiver: address, amount: uint256) -> uint256: nonpayable

    # Returns tokens
    def totalUnderlying() -> uint256: view
    def calculateUnderlying(shareAmount: uint256) -> uint256: view
    def mint(receiver: address, shares: uint256) -> uint256: nonpayable
    def redeem(sender: address, receiver: address, shares: uint256) -> uint256: nonpayable

implements: ERC4626

event Transfer:
    sender: indexed(address)
    receiver: indexed(address)
    amount: uint256

event Approval:
    owner: indexed(address)
    spender: indexed(address)
    allowance: uint256

event Deposit:
    depositor: indexed(address)
    receiver: indexed(address)
    amount: uint256

event Withdraw:
    withdrawer: indexed(address)
    receiver: indexed(address)
    amount: uint256


totalSupply: public(uint256)
balanceOf: public(HashMap[address, uint256])
allowance: public(HashMap[address, HashMap[address, uint256]])

underlying: public(ERC20)


@external
def __init__(underlying: ERC20):
    self.underlying = underlying


@external
def transfer(receiver: address, amount: uint256) -> bool:
    self.balanceOf[msg.sender] -= amount
    self.balanceOf[receiver] += amount
    log Transfer(msg.sender, receiver, amount)
    return True


@external
def approve(spender: address, amount: uint256) -> bool:
    self.allowance[msg.sender][spender] = amount
    log Approval(msg.sender, spender, amount)
    return True


@external
def transferFrom(sender: address, receiver: address, amount: uint256) -> bool:
    self.allowance[sender][msg.sender] -= amount
    self.balanceOf[sender] -= amount
    self.balanceOf[receiver] += amount
    log Transfer(sender, receiver, amount)
    return True


@view
@internal
def _calculateShares(underlyingAmount: uint256) -> uint256:
    return underlyingAmount * self.totalSupply / self.underlying.balanceOf(self)


@view
@external
def calculateShares(underlyingAmount: uint256) -> uint256:
    return self._calculateShares(underlyingAmount)


@external
def deposit(receiver: address, amount: uint256) -> uint256:
    shares: uint256 = self._calculateShares(amount)
    self.underlying.transferFrom(msg.sender, self, amount)
    self.totalSupply += shares
    self.balanceOf[receiver] += shares
    log Deposit(msg.sender, receiver, amount)
    return shares


@external
def withdraw(sender: address, receiver: address, amount: uint256) -> uint256:
    shares: uint256 = self._calculateShares(amount)

    if sender != msg.sender:
        self.allowance[sender][msg.sender] -= shares

    self.totalSupply -= shares
    self.balanceOf[sender] -= shares
    self.underlying.transfer(receiver, amount)
    log Withdraw(sender, receiver, amount)
    return shares


@view
@external
def totalUnderlying() -> uint256:
    return self.underlying.balanceOf(self)


@view
@internal
def _calculateUnderlying(shareAmount: uint256) -> uint256:
    return shareAmount * self.underlying.balanceOf(self) / self.totalSupply


@view
@external
def calculateUnderlying(shareAmount: uint256) -> uint256:
    return self._calculateUnderlying(shareAmount)


@external
def mint(receiver: address, shares: uint256) -> uint256:
    amount: uint256 = self._calculateUnderlying(shares)
    self.underlying.transferFrom(msg.sender, self, amount)
    self.totalSupply += shares
    self.balanceOf[receiver] += shares
    log Deposit(msg.sender, receiver, amount)
    return amount


@external
def redeem(sender: address, receiver: address, shares: uint256) -> uint256:
    if sender != msg.sender:
        self.allowance[sender][msg.sender] -= shares

    amount: uint256 = self._calculateUnderlying(shares)
    self.totalSupply -= shares
    self.balanceOf[sender] -= shares
    self.underlying.transfer(receiver, amount)
    log Withdraw(sender, receiver, amount)
    return amount


@external
def debug_take_tokens(amount: uint256):
    # NOTE: This is the primary method of mocking share price changes
    self.underlying.transfer(msg.sender, amount)
