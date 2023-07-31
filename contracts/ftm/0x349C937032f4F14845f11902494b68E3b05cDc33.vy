# @version 0.3.0
"""
@title Underlying Burner
@notice Performs a direct swap to USDT
"""

from vyper.interfaces import ERC20


interface AddressProvider:
    def get_registry() -> address: view

interface Registry:
    def get_pool_from_lp_token(_lp_token: address) -> address: view
    def get_coins(_pool: address) -> address[8]: view

interface StableSwap:
    def remove_liquidity_one_coin(_amount: uint256, i: int128, _min_amount: uint256): nonpayable


struct SwapData:
    pool: address
    coin: address
    i: int128


swap_data: public(HashMap[address, SwapData])
receiver: public(address)
is_killed: public(bool)

owner: public(address)
future_owner: public(address)

is_approved: HashMap[address, HashMap[address, bool]]

ADDRESS_PROVIDER: constant(address) = 0x0000000022D53366457F9d5E68Ec105046FC4383
USDT: constant(address) = 0x049d68029688eAbF473097a2fC38ef61633A3C7A

@external
def __init__(_receiver: address, _owner: address):
    """
    @notice Contract constructor
    @param _receiver Address that converted tokens are transferred to.
                     Should be set to the `ChildBurner` deployment.
    @param _owner Owner address. Can kill the contract and recover tokens.
    """
    self.receiver = _receiver
    self.owner = _owner


@external
def burn(_coin: address) -> bool:
    """
    @notice Convert `_coin` by removing liquidity and transfer to another burner
    @param _coin Address of the coin being converted
    @return bool success
    """
    assert not self.is_killed  # dev: is killed

    # transfer coins from caller
    amount: uint256 = ERC20(_coin).balanceOf(msg.sender)
    if amount != 0:
        ERC20(_coin).transferFrom(msg.sender, self, amount)

    # get actual balance in case of transfer fee or pre-existing balance
    amount = ERC20(_coin).balanceOf(self)

    if amount != 0:
        # remove liquidity and pass to the next burner
        swap_data: SwapData = self.swap_data[_coin]
        StableSwap(swap_data.pool).remove_liquidity_one_coin(amount, swap_data.i, 0)

        amount = ERC20(swap_data.coin).balanceOf(self)
        response: Bytes[32] = raw_call(
            swap_data.coin,
            _abi_encode(self.receiver, amount, method_id=method_id("transfer(address,uint256)")),
            max_outsize=32,
        )
        if len(response) != 0:
            assert convert(response, bool)

    return True


@external
def set_swap_data(_lp_token: address, _coin: address) -> bool:
    """
    @notice Set conversion and transfer data for `_lp_token`
    @param _lp_token LP token address
    @param _coin Underlying coin to remove liquidity in
    @return bool success
    """
    assert msg.sender == self.owner

    # if another burner was previous set, revoke approvals
    pool: address = self.swap_data[_lp_token].pool
    if pool != ZERO_ADDRESS:
        # we trust that LP tokens always return True, so no need for `raw_call`
        ERC20(_lp_token).approve(pool, 0)
    coin: address = self.swap_data[_lp_token].coin

    # find `i` for `_coin` within the pool, approve transfers and save to storage
    registry: address = AddressProvider(ADDRESS_PROVIDER).get_registry()
    pool = Registry(registry).get_pool_from_lp_token(_lp_token)
    coins: address[8] = Registry(registry).get_coins(pool)
    for i in range(8):
        if coins[i] == ZERO_ADDRESS:
            raise
        if coins[i] == _coin:
            self.swap_data[_lp_token] = SwapData({pool: pool, coin: _coin, i: i})
            ERC20(_lp_token).approve(pool, MAX_UINT256)
            return True
    raise




@external
def recover_balance(_coin: address) -> bool:
    """
    @notice Recover ERC20 tokens from this contract
    @param _coin Token address
    @return bool success
    """
    assert msg.sender == self.owner  # dev: only owner

    amount: uint256 = ERC20(_coin).balanceOf(self)
    response: Bytes[32] = raw_call(
        _coin,
        _abi_encode(msg.sender, amount, method_id=method_id("transfer(address,uint256)")),
        max_outsize=32,
    )
    if len(response) != 0:
        assert convert(response, bool)

    return True


@external
def set_receiver(_receiver: address):
    assert msg.sender == self.owner
    self.receiver = _receiver


@external
def set_killed(_is_killed: bool) -> bool:
    """
    @notice Set killed status for this contract
    @dev When killed, the `burn` function cannot be called
    @param _is_killed Killed status
    @return bool success
    """
    assert msg.sender == self.owner  # dev: only owner
    self.is_killed = _is_killed

    return True


@external
def commit_transfer_ownership(_future_owner: address) -> bool:
    """
    @notice Commit a transfer of ownership
    @dev Must be accepted by the new owner via `accept_transfer_ownership`
    @param _future_owner New owner address
    @return bool success
    """
    assert msg.sender == self.owner  # dev: only owner
    self.future_owner = _future_owner

    return True


@external
def accept_transfer_ownership() -> bool:
    """
    @notice Accept a transfer of ownership
    @return bool success
    """
    assert msg.sender == self.future_owner  # dev: only owner
    self.owner = msg.sender

    return True