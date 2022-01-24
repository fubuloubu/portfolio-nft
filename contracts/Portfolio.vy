# @version 0.3.2

from vyper.interfaces import ERC20
from vyper.interfaces import ERC721

implements: ERC721

# Interface for the contract called by safeTransferFrom()
interface ERC721Receiver:
    def onERC721Received(
            operator: address,
            owner: address,
            tokenId: uint256,
            data: Bytes[1024]
        ) -> bytes32: view

# @dev Emits when ownership of any NFT changes by any mechanism. This event emits when NFTs are
#      created (`from` == 0) and destroyed (`to` == 0). Exception: during contract creation, any
#      number of NFTs may be created and assigned without emitting Transfer. At the time of any
#      transfer, the approved address for that NFT (if any) is reset to none.
# @param owner Sender of NFT (if address is zero address it indicates token creation).
# @param receiver Receiver of NFT (if address is zero address it indicates token destruction).
# @param tokenId The NFT that got transfered.
event Transfer:
    sender: indexed(address)
    receiver: indexed(address)
    tokenId: indexed(uint256)

# @dev This emits when the approved address for an NFT is changed or reaffirmed. The zero
#      address indicates there is no approved address. When a Transfer event emits, this also
#      indicates that the approved address for that NFT (if any) is reset to none.
# @param owner Owner of NFT.
# @param approved Address that we are approving.
# @param tokenId NFT which we are approving.
event Approval:
    owner: indexed(address)
    approved: indexed(address)
    tokenId: indexed(uint256)

# @dev This emits when an operator is enabled or disabled for an owner. The operator can manage
#      all NFTs of the owner.
# @param owner Owner of NFT.
# @param operator Address to which we are setting operator rights.
# @param approved Status of operator rights(true if operator rights are given and false if
# revoked).
event ApprovalForAll:
    owner: indexed(address)
    operator: indexed(address)
    approved: bool

# @dev Mapping of TokenID to nonce values used for ERC4494 signature verification
nonces: public(HashMap[uint256, uint256])

DOMAIN_SEPARATOR: public(bytes32)


EIP712_DOMAIN_TYPEHASH: constant(bytes32) = keccak256(
    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
)
EIP712_DOMAIN_NAMEHASH: constant(bytes32) = keccak256("Portfolio NFT")
EIP712_DOMAIN_VERSIONHASH: constant(bytes32) = keccak256("1")

# @dev Mapping of interface id to bool about whether or not it's supported
# NOTE: incompatible w/ ERC165 until `bytes4` is added
supportsInterface: public(HashMap[bytes32, bool])

underlying: public(ERC20)

MAX_STRATEGIES: constant(uint256) = 128

# NOTE: Strategy implements ERC20 and ERC4626
interface Strategy:
    # Underlying token that shares are in
    def underlying() -> address: view

    # Returns shares
    def deposit(receiver: address, amount: uint256) -> uint256: nonpayable

    # Returns tokens
    def totalUnderlying() -> uint256: view
    def exchangeRate() -> uint256: view
    def redeem(sender: address, receiver: address, shares: uint256) -> uint256: nonpayable

struct StrategyAllocation:
    strategy: address  # NOTE: Bug in Vyper prevents from using `Strategy` here
    numShares: uint256

struct Portfolio:
    owner: address
    blockCreated: uint256
    # NOTE: Can change allocations without changing the PortfolioId
    allocations: DynArray[StrategyAllocation, MAX_STRATEGIES]

# PortfolioID {keccak(originalOwner + blockCreated)} => Portfolio
portfolios: public(HashMap[uint256, Portfolio])

balanceOf: public(HashMap[address, uint256])

# @dev Mapping from owner address to mapping of operator addresses.
isApprovedForAll: public(HashMap[address, HashMap[address, bool]])

# @dev Mapping from NFT ID to approved address.
portfolioOperator: public(HashMap[uint256, address])


@external
def __init__(underlying: ERC20):
    """
    @dev Contract constructor.
    """
    self.underlying = underlying

    # ERC721
    self.supportsInterface[
        0x0000000000000000000000000000000000000000000000000000000001ffc9a7
    ] = True

    # ERC721
    self.supportsInterface[
        0x0000000000000000000000000000000000000000000000000000000080ac58cd
    ] = True

    # ERC4494
    self.supportsInterface[
        0x000000000000000000000000000000000000000000000000000000005604e225
    ] = True

    # ERC712 domain separator for ERC4494
    self.DOMAIN_SEPARATOR = keccak256(
        _abi_encode(
            EIP712_DOMAIN_TYPEHASH,
            EIP712_DOMAIN_NAMEHASH,
            EIP712_DOMAIN_VERSIONHASH,
            chain.id,
            self,
        )
    )


@external
def setDomainSeparator():
    """
    @dev Update the domain separator in case of a hardfork where chain ID changes
    """
    self.DOMAIN_SEPARATOR = keccak256(
        _abi_encode(
            EIP712_DOMAIN_TYPEHASH,
            EIP712_DOMAIN_NAMEHASH,
            EIP712_DOMAIN_VERSIONHASH,
            chain.id,
            self,
        )
    )


### VIEW FUNCTIONS ###

@view
@external
def ownerOf(tokenId: uint256) -> address:
    """
    @dev Returns the address of the owner of the NFT.
         Throws if `tokenId` is not a valid NFT.
    @param tokenId The identifier for an NFT.
    """
    owner: address = self.portfolios[tokenId].owner
    # Throws if `tokenId` is not a valid NFT
    assert owner != ZERO_ADDRESS
    return owner


@view
@external
def getApproved(tokenId: uint256) -> address:
    """
    @dev Get the approved address for a single NFT.
         Throws if `tokenId` is not a valid NFT.
    @param tokenId ID of the NFT to query the approval of.
    """
    # Throws if `tokenId` is not a valid NFT
    assert self.portfolios[tokenId].owner != ZERO_ADDRESS
    return self.portfolioOperator[tokenId]


### TRANSFER FUNCTION HELPERS ###

@view
@internal
def _isApprovedOrOwner(spender: address, tokenId: uint256) -> bool:
    """
    @dev Returns whether the given spender can transfer a given token ID
    @param spender address of the spender to query
    @param tokenId uint256 ID of the token to be transferred
    @return bool whether the msg.sender is approved for the given token ID,
        is an operator of the owner, or is the owner of the token
    """
    owner: address = self.portfolios[tokenId].owner

    if owner == spender:
        return True

    if spender == self.portfolioOperator[tokenId]:
        return True

    if (self.isApprovedForAll[owner])[spender]:
        return True

    return False


@internal
def _transferFrom(owner: address, receiver: address, tokenId: uint256, sender: address):
    """
    @dev Exeute transfer of a NFT.
         Throws unless `msg.sender` is the current owner, an authorized operator, or the approved
         address for this NFT. (NOTE: `msg.sender` not allowed in private function so pass `_sender`.)
         Throws if `receiver` is the zero address.
         Throws if `owner` is not the current owner.
         Throws if `tokenId` is not a valid NFT.
    """
    # Check requirements
    assert self._isApprovedOrOwner(sender, tokenId)
    # Throws if `receiver` is the zero address
    assert receiver != ZERO_ADDRESS
    # Clear approval. Throws if `owner` is not the current owner
    if self.portfolioOperator[tokenId] != ZERO_ADDRESS:
        # Reset approvals
        self.portfolioOperator[tokenId] = ZERO_ADDRESS
    # Change the owner
    self.portfolios[tokenId].owner = receiver
    # Change count tracking
    self.balanceOf[receiver] -= 1
    self.balanceOf[receiver] += 1
    # Log the transfer
    log Transfer(owner, receiver, tokenId)


@external
def transferFrom(owner: address, receiver: address, tokenId: uint256):
    """
    @dev Throws unless `msg.sender` is the current owner, an authorized operator, or the approved
         address for this NFT.
         Throws if `owner` is not the current owner.
         Throws if `receiver` is the zero address.
         Throws if `tokenId` is not a valid NFT.
    @notice The caller is responsible to confirm that `receiver` is capable of receiving NFTs or else
            they maybe be permanently lost.
    @param owner The current owner of the NFT.
    @param receiver The new owner.
    @param tokenId The NFT to transfer.
    """
    self._transferFrom(owner, receiver, tokenId, msg.sender)


@external
def safeTransferFrom(
        owner: address,
        receiver: address,
        tokenId: uint256,
        data: Bytes[1024]=b""
    ):
    """
    @dev Transfers the ownership of an NFT from one address to another address.
         Throws unless `msg.sender` is the current owner, an authorized operator, or the
         approved address for this NFT.
         Throws if `owner` is not the current owner.
         Throws if `receiver` is the zero address.
         Throws if `tokenId` is not a valid NFT.
         If `receiver` is a smart contract, it calls `onERC721Received` on `receiver` and throws if
         the return value is not `bytes4(keccak256("onERC721Received(address,address,uint256,bytes)"))`.
         NOTE: bytes4 is represented by bytes32 with padding
    @param owner The current owner of the NFT.
    @param receiver The new owner.
    @param tokenId The NFT to transfer.
    @param data Additional data with no specified format, sent in call to `receiver`.
    """
    self._transferFrom(owner, receiver, tokenId, msg.sender)
    if receiver.is_contract: # check if `receiver` is a contract address
        returnValue: bytes32 = ERC721Receiver(receiver).onERC721Received(msg.sender, owner, tokenId, data)
        # Throws if transfer destination is a contract which does not implement 'onERC721Received'
        assert returnValue == method_id("onERC721Received(address,address,uint256,bytes)", output_type=bytes32)


@external
def approve(operator: address, tokenId: uint256):
    """
    @dev Set or reaffirm the approved address for an NFT. The zero address indicates there is no approved address.
         Throws unless `msg.sender` is the current NFT owner, or an authorized operator of the current owner.
    @param operator Address to be approved for the given NFT ID.
    @param tokenId ID of the token to be approved.
    """
    owner: address = self.portfolios[tokenId].owner
    # Throws if `msg.sender` is not the current owner
    if not (
        owner == msg.sender
        or (self.isApprovedForAll[owner])[msg.sender]
    ):
       raise

    self.portfolioOperator[tokenId] = operator
    log Approval(owner, operator, tokenId)


@external
def permit(spender: address, tokenId: uint256, deadline: uint256, sig: Bytes[65]):
    assert block.timestamp <= deadline

    owner: address = self.portfolios[tokenId].owner
    assert owner != ZERO_ADDRESS
    nonce: uint256 = self.nonces[tokenId]

    # Compose EIP-712 message
    message: bytes32 = keccak256(
        _abi_encode(
            0x1901,
            self.DOMAIN_SEPARATOR,
            keccak256(
                _abi_encode(
                    keccak256(
                        "Permit(address spender,uint256 tokenId,uint256 nonce,uint256 deadline)"
                    ),
                    spender,
                    tokenId,
                    nonce,
                    deadline,
                )
            )
        )
    )

    # Validate signature
    v: uint256 = 0
    r: uint256 = 0
    s: uint256 = 0

    if len(sig) == 65:
        # Normal encoded VRS signatures
        v = convert(slice(sig, 0, 1), uint256)
        r = convert(slice(sig, 1, 32), uint256)
        s = convert(slice(sig, 33, 32), uint256)

    elif len(sig) == 64:
        # EIP-2098 compact signatures
        r = convert(slice(sig, 0, 32), uint256)
        v = convert(slice(sig, 33, 1), uint256)
        s = convert(slice(sig, 34, 31), uint256)

    else:
        raise  # Other schemes not supported

    assert ecrecover(message, v, r, s) == owner

    self.nonces[tokenId] = nonce + 1
    self.portfolioOperator[tokenId] = spender


@external
def setApprovalForAll(operator: address, approved: bool):
    """
    @dev Enables or disables approval for a third party ("operator") to manage all of
         `msg.sender`'s assets. It also emits the ApprovalForAll event.
    @notice This works even if sender doesn't own any tokens at the time.
    @param operator Address to add to the set of authorized operators.
    @param approved True if the operators is approved, false to revoke approval.
    """
    self.isApprovedForAll[msg.sender][operator] = approved
    log ApprovalForAll(msg.sender, operator, approved)


#### PORTFOLIO MANAGEMENT FUNCTIONS ####

@external
def mint() -> uint256:
    """
    @dev Create a new Portfolio NFT
    @notice `tokenId` cannot be owned by someone because of hash production.
    @return uint256 Computed TokenID of new Portfolio.
    """
    # Create token
    tokenId: uint256 = convert(
        keccak256(
            concat(
                convert(msg.sender, bytes32),
                convert(block.number, bytes32),
            )
        ),
        uint256,
    )
    assert self.portfolios[tokenId].owner == ZERO_ADDRESS
    self.portfolios[tokenId] = Portfolio({
        owner: msg.sender,
        blockCreated: block.number,
        allocations: empty(DynArray[StrategyAllocation, MAX_STRATEGIES]),
    })
    self.balanceOf[msg.sender] += 1

    return tokenId


@internal
def _findStrategyIdxInPortfolio(tokenId: uint256, strategy: address) -> (bool, uint256):
    """
    Find and return the index of Strategy for a given Portfolio's set of Strategy allocations.
    Returns whether one was found, and the index of the Strategy in the Portfolio.
    If the Strategy is not found, the length of the Strategy allocations set is returned instead.
    """
    # Search for strategy in set and increase allocations
    strategy_found: bool = False
    strategy_idx: uint256 = len(self.portfolios[tokenId].allocations)
    for idx in range(MAX_STRATEGIES):
        if idx >= strategy_idx:
            break  # Greater than `len(self.portfolios[tokenId].allocations)`

        if self.portfolios[tokenId].allocations[idx].strategy == strategy:
            strategy_idx = idx
            strategy_found = True
            break

    return strategy_found, strategy_idx


@external
def allocate(
    tokenId: uint256,
    strategy: address,
    _amount: uint256 = MAX_UINT256,
    funder: address = msg.sender,
) -> uint256:
    # TODO: check that Strategy works w/ ERC4626 interface
    amount: uint256 = _amount
    if _amount == MAX_UINT256:
        amount = self.underlying.balanceOf(funder)

    else:
        assert amount <= self.underlying.balanceOf(funder)

    # Transfer funds here first
    self.underlying.transferFrom(funder, self, amount)

    # Make sure enough approval space is there for deposit function
    if self.underlying.allowance(self, strategy) < amount:
        self.underlying.approve(strategy, MAX_UINT256)  # Do unlimited approval for convienence
        # NOTE: It is secure to do an unlimited approval, because the Portfolio does not take
        #       custody of funds for longer than 1 txn.

    # Deposit tokens to strategy
    numShares: uint256 = Strategy(strategy).deposit(self, amount)

    # Search for strategy in set
    strategy_found: bool = False
    strategy_idx: uint256 = 0
    strategy_found, strategy_idx = self._findStrategyIdxInPortfolio(tokenId, strategy)

    # NOTE: Add shares to another user's NFT is not an issue because they can only benefit
    if strategy_found:
        # Strategy found, increase allocation
        self.portfolios[tokenId].allocations[strategy_idx].numShares += numShares

    else:
        # Strategy not found, add to allocations
        self.portfolios[tokenId].allocations[strategy_idx] = StrategyAllocation({
            strategy: strategy,
            numShares: numShares,
        })

    return numShares


@external
def moveShares(
    ownerTokenId: uint256,
    strategy: address,
    receiverTokenId: uint256,
    _shares: uint256 = MAX_UINT256,
 ) -> uint256:
    assert self._isApprovedOrOwner(msg.sender, ownerTokenId)

    # Clear approval if spender is not owner and is not approved for all actions.
    if self.portfolioOperator[ownerTokenId] == msg.sender:
        # Reset approvals
        self.portfolioOperator[ownerTokenId] = ZERO_ADDRESS

    # Search for strategy in owner's set
    strategy_found: bool = False
    strategy_idx: uint256 = 0
    strategy_found, strategy_idx = self._findStrategyIdxInPortfolio(ownerTokenId, strategy)
    assert strategy_found

    # Find amount of shares to transfer from strategy
    shares: uint256 = _shares
    total_shares: uint256 = self.portfolios[ownerTokenId].allocations[strategy_idx].numShares
    if _shares == MAX_UINT256:
        shares = total_shares

    else:
        assert shares <= total_shares

    # Withdraw shares from owner's Portfolio
    self.portfolios[ownerTokenId].allocations[strategy_idx].numShares = total_shares - shares

    # Search for strategy in receiver's set
    strategy_found, strategy_idx = self._findStrategyIdxInPortfolio(receiverTokenId, strategy)

    # Deposit shares to receiver's Portfolio
    # NOTE: Not an authenticated action (because receiver can only gain)
    if strategy_found:
        # Strategy found, increase allocation
        self.portfolios[receiverTokenId].allocations[strategy_idx].numShares += shares

    else:
        # Strategy not found, add to allocations
        self.portfolios[receiverTokenId].allocations[strategy_idx] = StrategyAllocation({
            strategy: strategy,
            numShares: shares,
        })

    return strategy_idx


@external
def unallocate(
    tokenId: uint256,
    strategy: address,
    _shares: uint256 = MAX_UINT256,
    receiver: address = msg.sender,
) -> uint256:
    # Must ensure approval to take shares from NFT
    assert self._isApprovedOrOwner(msg.sender, tokenId)

    # Clear approval if spender is not owner and is not approved for all actions.
    if self.portfolioOperator[tokenId] == msg.sender:
        # Reset approvals
        self.portfolioOperator[tokenId] = ZERO_ADDRESS

    # Search for strategy in set
    strategy_found: bool = False
    strategy_idx: uint256 = 0
    strategy_found, strategy_idx = self._findStrategyIdxInPortfolio(tokenId, strategy)
    assert strategy_found  # Must be a strategy in the NFT

    # Find amount of shares to withdraw from strategy
    shares: uint256 = _shares
    total_shares: uint256 = self.portfolios[tokenId].allocations[strategy_idx].numShares
    if _shares == MAX_UINT256:
        shares = total_shares

    else:
        assert shares <= total_shares

    # Withdraw shares and transfer tokens to receiver
    total_shares -= shares
    self.portfolios[tokenId].allocations[strategy_idx].numShares = total_shares
    withdrawn: uint256 = Strategy(strategy).redeem(self, self, shares)
    self.underlying.transfer(receiver, withdrawn)

    return withdrawn


@view
@external
def estimatedValue(tokenId: uint256) -> uint256:
    assert self.portfolios[tokenId].blockCreated > 0
    total_underlying: uint256 = 0

    for allocation in self.portfolios[tokenId].allocations:
        total_underlying += (
            Strategy(allocation.strategy).exchangeRate()
            * allocation.numShares
            / Strategy(allocation.strategy).totalUnderlying()
        )

    return total_underlying
