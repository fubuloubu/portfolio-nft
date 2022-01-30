# Takes ERC721 Portfolio and rebalances from current to requested allocations

from vyper.interfaces import ERC20

import ERC4626 as ERC4626

MAX_STRATEGIES: constant(uint256) = 128

struct Allocation:
    strategy: address
    numShares: uint256

struct PortfolioInfo:
    owner: address
    blockCreated: uint256
    allocations: DynArray[Allocation, MAX_STRATEGIES]

interface Portfolio:
    def asset() -> address: view
    def portfolios(tokenId: uint256) -> PortfolioInfo: view
    def permit(
        spender: address,
        tokenId: uint256,
        deadline: uint256,
        sig: Bytes[65],
    ) -> bool: nonpayable
    # All these methods require permit
    def allocate(
        tokenId: uint256,
        strategy: address,
        amount: uint256,
        funder: address,
    ) -> uint256: nonpayable
    def moveShares(
        ownerTokenId: uint256,
        strategy: address,
        receiverTokenId: uint256,
        shares: uint256,
    ) -> uint256: nonpayable
    def unallocate(
        tokenId: uint256,
        strategy: address,
        shares: uint256,
        receiver: address,
    ) -> uint256: nonpayable

interface ERC2612:
    def permit(
        owner: address,
        spender: address,
        amount: uint256,
        deadline: uint256,
        v: uint8,
        r: bytes32,
        s: bytes32,
    ): nonpayable

struct SignedPaymentPermit:
    spender: address
    amount: uint256
    deadline: uint256
    sig: Bytes[65]

struct SignedPortfolioPermit:
    portfolio: address
    tokenId: uint256
    deadline: uint256
    sig: Bytes[65]


paymentToken: public(address)
treasury: public(address)

approvalCost: public(uint256)
rebalanceCostPerStrategy: public(uint256)


# @dev Mapping of Portfolio NFTs => user => nonce values used for Rebalance Order sig verification
nonces: public(HashMap[address, HashMap[address, uint256]])

DOMAIN_SEPARATOR: public(bytes32)

EIP712_DOMAIN_TYPEHASH: constant(bytes32) = keccak256(
    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
)
EIP712_DOMAIN_NAMEHASH: constant(bytes32) = keccak256("Portfolio Rebalancer")
EIP712_DOMAIN_VERSIONHASH: constant(bytes32) = keccak256("1")


struct SignedRebalanceOrder:
    portfolio: address
    tokenId: uint256
    deadline: uint256
    allocations: DynArray[Allocation, MAX_STRATEGIES]
    sig: Bytes[65]

REBALANCE_MESSAGE_TYPEHASH: constant(bytes32) = keccak256(
    "RebalancOrder("
    "address portfolio,"
    "uint256 tokenId,"
    "uint256 nonce,"
    "uint256 deadline,"
    "allocations Allocation[]"
    ")"
)

MAX_ORDERS: constant(uint256) = 16


@external
def __init__(paymentToken: address, treasury: address):
    self.paymentToken = paymentToken  # Try to use native token wrapper (e.g. WETH)
    self.treasury = treasury
    self.approvalCost = 10 ** 16  # 0.01 ETH or native token
    self.rebalanceCostPerStrategy = 10 ** 15  # 0.001 ETH or native token

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


@external
def batchApprovals(
    payment_permits: DynArray[SignedPaymentPermit, 128],
    portfolio_permits: DynArray[SignedPortfolioPermit, 128],
):
    paymentToken: address = self.paymentToken
    for permit in payment_permits:
        if block.timestamp > permit.deadline:
            continue  # Skip expired permits

        v: uint8 = 0
        r: bytes32 = EMPTY_BYTES32
        s: bytes32 = EMPTY_BYTES32

        if len(permit.sig) == 65:
            # Normal encoded VRS signatures
            v = convert(slice(permit.sig, 0, 1), uint8)
            r = convert(slice(permit.sig, 1, 32), bytes32)
            s = convert(slice(permit.sig, 33, 32), bytes32)

        elif len(permit.sig) == 64:
            # EIP-2098 compact signatures
            r = convert(slice(permit.sig, 0, 32), bytes32)
            v = convert(slice(permit.sig, 33, 1), uint8)
            s = convert(slice(permit.sig, 34, 31), bytes32)

        else:
            raise

        # NOTE: Check signature is valid, and nonce is correct for permit off-chain
        ERC2612(paymentToken).permit(permit.spender, self, permit.amount, permit.deadline, v, r, s)

    approvalCost: uint256 = self.approvalCost
    for permit in portfolio_permits:
        if block.timestamp > permit.deadline:
            continue  # Skip expired permits

        owner: address = Portfolio(permit.portfolio).portfolios(permit.tokenId).owner
        if ERC20(paymentToken).allowance(owner, self) < approvalCost:
            continue  # Skip lowballers

        assert ERC20(paymentToken).transferFrom(owner, self.treasury, approvalCost)

        # NOTE: Check signature is valid, and nonce is correct for permit off-chain
        assert Portfolio(permit.portfolio).permit(self, permit.tokenId, permit.deadline, permit.sig)


@internal
def _validateOrder(order: SignedRebalanceOrder) -> address:
    # Permit is still valid
    assert block.timestamp <= order.deadline

    # Ensure the token is owned by someone
    owner: address = Portfolio(order.portfolio).portfolios(order.tokenId).owner
    assert owner != ZERO_ADDRESS

    # Nonce for given user (signer must ensure they use latest)
    nonce: uint256 = (self.nonces[order.portfolio])[owner]

    # Compose EIP-712 message
    message: bytes32 = keccak256(
        _abi_encode(
            0x1901,
            self.DOMAIN_SEPARATOR,
            keccak256(
                _abi_encode(
                    REBALANCE_MESSAGE_TYPEHASH,
                    order.portfolio,
                    order.tokenId,
                    nonce,
                    order.deadline,
                    order.allocations,
                )
            )
        )
    )

    # Validate signature
    v: uint256 = 0
    r: uint256 = 0
    s: uint256 = 0

    if len(order.sig) == 65:
        # Normal encoded VRS signatures
        v = convert(slice(order.sig, 0, 1), uint256)
        r = convert(slice(order.sig, 1, 32), uint256)
        s = convert(slice(order.sig, 33, 32), uint256)

    elif len(order.sig) == 64:
        # EIP-2098 compact signatures
        r = convert(slice(order.sig, 0, 32), uint256)
        v = convert(slice(order.sig, 33, 1), uint256)
        s = convert(slice(order.sig, 34, 31), uint256)

    else:
        raise  # Other schemes not supported

    # Ensure owner signed permit
    assert ecrecover(message, v, r, s) == owner

    (self.nonces[order.portfolio])[owner] = nonce + 1

    return owner


struct Deposit:
    tokenId: uint256
    strategy: address
    amount: uint256
    funder: address


struct Swap:
    tokenId_from: uint256
    strategy: address
    tokenId_to: uint256
    shares: uint256


struct Withdrawal:
    tokenId: uint256
    strategy: address
    shares: uint256
    receiver: address


struct Transfer:
    receiver: address
    amount: uint256


@internal
def _findStrategyInAllocations(
    strategy: address,
    allocations: DynArray[Allocation, MAX_STRATEGIES],
) -> uint256:
    location: uint256 = MAX_UINT256  # NOT FOUND

    for idx in range(MAX_STRATEGIES):
        if idx >= len(allocations):
            break

        if allocations[idx].strategy == strategy:
            return idx

    return location  # NOT FOUND


@external
def matchOrders(portfolio: address, orders: DynArray[SignedRebalanceOrder, MAX_ORDERS]):
    paymentToken: address = self.paymentToken
    portfolio_asset: address = Portfolio(portfolio).asset()
    rebalanceCost: uint256 = self.rebalanceCost

    # Organize our orders into these 4 buckets for efficiency
    # NOTE: Rebalancer should try to maximize the number of swaps/transfers to reduce overall rebalancing costs
    # NOTE: The algorithm here is sensitive to the ordering of `orders`, and Rebalancer should try to optimize to reduce overall cost
    deposits: DynArray[Deposit, MAX_ORDERS * MAX_STRATEGIES] = empty(DynArray[Deposit, MAX_ORDERS * MAX_STRATEGIES])
    swaps: DynArray[Swap, MAX_ORDERS * MAX_STRATEGIES] = empty(DynArray[Swap, MAX_ORDERS * MAX_STRATEGIES])
    withdrawals: DynArray[Withdrawal, MAX_ORDERS * MAX_STRATEGIES] = empty(DynArray[Withdrawal, MAX_ORDERS * MAX_STRATEGIES])
    transfers: DynArray[Transfer, MAX_ORDERS * MAX_STRATEGIES] = empty(DynArray[Transfer, MAX_ORDERS * MAX_STRATEGIES])

    for order in orders:
        # NOTE: All orders must be for the same Portfolio NFT (for simplicity)
        assert order.portfolio == portfolio
        owner: address = self._validateOrder(order)
        current_allocations: DynArray[Allocation, MAX_STRATEGIES] = Portfolio(portfolio).portfolios(order.tokenId).allocations

        # Process payment first
        totalOrderCost: uint256 = rebalanceCostPerStrategy * max(len(order.allocations), len(current_allocations))

        if ERC20(paymentToken).allowance(owner, self) < totalOrderCost:
            continue  # Skip lowballers

        assert ERC20(paymentToken).transferFrom(owner, self.treasury, totalOrderCost)

        # Then find all strategies we want to partially/fully deposit to
        net_deposit: uint256 = 0
        for allocation in order.allocations:
            strategy_idx: uint256 = self._findStrategyInAllocations(allocation.strategy, current_allocations)

            if strategy_idx != MAX_UINT256:  # We found something
                # Is this a net allocation or deallocation?
                current: uint256 = current_allocations[strategy_idx].numShares
                if current < allocation.numShares:
                    # Allocate

                elif current > allocation.numShares:
                    # Deallocate

                else:  # No change
                    pass

            else:  # We didn't find it, so we need to allocate
                deposit_amount = (
                    ERC4626(allocation.strategy).pricePerShare()
                    * allocation.numShares
                    / ERC4626(allocation.strategy).totalAssets()
                )

                deposits.append(
                    Deposit({
                        tokenId: order.tokenId,
                        strategy: allocation.strategy,
                        amount: deposit_amount,
                        funder: owner,
                    })
                )

                # Adjust net deposits for reducing token movements
                net_deposit += deposit_amount

        # Then find all strategies we want to partially/fully withdraw from
        for allocation in current_allocations:
            strategy_idx: uint256 = self._findStrategyInAllocations(allocation.strategy, order.allocations)

            if strategy_idx != MAX_UINT256:  # We found something
            else:  # We didn't find it, so we need to deallocate
                withdrawal_amount = (
                    ERC4626(allocation.strategy).pricePerShare()
                    * allocation.numShares
                    / ERC4626(allocation.strategy).totalAssets()
                )

                # Adjust net deposits for reducing token movements
                if withdrawal_amount <= net_deposit:
                    net_deposit -= withdrawal_amount
                    withdrawal_amount

                else:
                    withdrawal_amount -= net_deposit
                    net_deposit = 0

        # If user is making a net deposit, process that to put it in the pool
        if net_deposit > 0:
            assert ERC20(portfolio_asset).transferFrom(owner, self, net_deposit)

        # Finished pre-processing orders, execute delta changes

    # Process all our collected deposits
    for deposit in deposits:
        shares: uint256 = Portfolio(portfolio).allocate(
            deposit.tokenId,
            deposit.strategy,
            deposit.amount,
            deposit.funder,
        )

    # Process all our collected swaps
    for swap in swaps:
        Portfolio(portfolio).moveShares(
            swap.tokenId_from,
            swap.strategy,
            swap.tokenId_to,
            swap.shares,
        )

    # Process all our collected withdrawals
    for withdrawal in withdrawals:
        Portfolio(portfolio).unallocate(
            withdrawal.tokenId,
            withdrawal.strategy,
            withdrawal.shares,
            withdrawal.receiver,
        )

    # Process all our collected transfers
    # NOTE: after this action, there should be no extra `portfolio_asset` tokens left in this contract
    for transfer in transfers:
        assert ERC20(portfolio_asset).transfer(transfer.receiver, transfer.amount)


@external
def cancelOrder(portfolio: address):
    (self.nonces[portfolio])[msg.sender] += 1
