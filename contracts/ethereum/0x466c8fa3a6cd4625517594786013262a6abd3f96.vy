# @version 0.2.16
"""
@title Curve Registry Exchange Contract
@license MIT
@author Curve.Fi
@notice Find pools, query exchange rates and perform swaps
"""

from vyper.interfaces import ERC20


interface AddressProvider:
    def admin() -> address: view
    def get_registry() -> address: view
    def get_address(idx: uint256) -> address: view

interface CurvePool:
    def exchange(i: int128, j: int128, dx: uint256, min_dy: uint256): payable
    def exchange_underlying(i: int128, j: int128, dx: uint256, min_dy: uint256): payable
    def get_dy(i: int128, j: int128, amount: uint256) -> uint256: view
    def get_dy_underlying(i: int128, j: int128, amount: uint256) -> uint256: view

interface Registry:
    def address_provider() -> address: view
    def get_A(_pool: address) -> uint256: view
    def get_fees(_pool: address) -> uint256[2]: view
    def get_coin_indices(_pool: address, _from: address, _to: address) -> (int128, int128, bool): view
    def get_n_coins(_pool: address) -> uint256[2]: view
    def get_balances(_pool: address) -> uint256[MAX_COINS]: view
    def get_underlying_balances(_pool: address) -> uint256[MAX_COINS]: view
    def get_rates(_pool: address) -> uint256[MAX_COINS]: view
    def get_decimals(_pool: address) -> uint256[MAX_COINS]: view
    def get_underlying_decimals(_pool: address) -> uint256[MAX_COINS]: view
    def find_pool_for_coins(_from: address, _to: address, i: uint256) -> address: view
    def get_lp_token(_pool: address) -> address: view
    def is_meta(_pool: address) -> bool: view

interface Calculator:
    def get_dx(n_coins: uint256, balances: uint256[MAX_COINS], amp: uint256, fee: uint256,
               rates: uint256[MAX_COINS], precisions: uint256[MAX_COINS],
               i: int128, j: int128, dx: uint256) -> uint256: view
    def get_dy(n_coins: uint256, balances: uint256[MAX_COINS], amp: uint256, fee: uint256,
               rates: uint256[MAX_COINS], precisions: uint256[MAX_COINS],
               i: int128, j: int128, dx: uint256[CALC_INPUT_SIZE]) -> uint256[CALC_INPUT_SIZE]: view


event TokenExchange:
    buyer: indexed(address)
    receiver: indexed(address)
    pool: indexed(address)
    token_sold: address
    token_bought: address
    amount_sold: uint256
    amount_bought: uint256


ETH_ADDRESS: constant(address) = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE
MAX_COINS: constant(int128) = 8
CALC_INPUT_SIZE: constant(uint256) = 100
EMPTY_POOL_LIST: constant(address[8]) = [
    ZERO_ADDRESS,
    ZERO_ADDRESS,
    ZERO_ADDRESS,
    ZERO_ADDRESS,
    ZERO_ADDRESS,
    ZERO_ADDRESS,
    ZERO_ADDRESS,
    ZERO_ADDRESS,
]


address_provider: AddressProvider
registry: public(address)
factory_registry: public(address)

default_calculator: public(address)
is_killed: public(bool)
pool_calculator: HashMap[address, address]

is_approved: HashMap[address, HashMap[address, bool]]


@external
def __init__(_address_provider: address, _calculator: address):
    """
    @notice Constructor function
    """
    self.address_provider = AddressProvider(_address_provider)
    self.registry = AddressProvider(_address_provider).get_registry()
    self.factory_registry = AddressProvider(_address_provider).get_address(3)
    self.default_calculator = _calculator


@external
@payable
def __default__():
    pass


@view
@internal
def _get_exchange_amount(
    _registry: address,
    _pool: address,
    _from: address,
    _to: address,
    _amount: uint256
) -> uint256:
    """
    @notice Get the current number of coins received in an exchange
    @param _registry Registry address
    @param _pool Pool address
    @param _from Address of coin to be sent
    @param _to Address of coin to be received
    @param _amount Quantity of `_from` to be sent
    @return Quantity of `_to` to be received
    """
    i: int128 = 0
    j: int128 = 0
    is_underlying: bool = False
    i, j, is_underlying = Registry(_registry).get_coin_indices(_pool, _from, _to) # dev: no market

    if is_underlying and (_registry == self.registry or Registry(_registry).is_meta(_pool)):
        return CurvePool(_pool).get_dy_underlying(i, j, _amount)

    return CurvePool(_pool).get_dy(i, j, _amount)


@internal
def _exchange(
    _registry: address,
    _pool: address,
    _from: address,
    _to: address,
    _amount: uint256,
    _expected: uint256,
    _sender: address,
    _receiver: address,
) -> uint256:

    assert not self.is_killed

    initial_balance: uint256 = 0
    eth_amount: uint256 = 0
    received_amount: uint256 = 0

    i: int128 = 0
    j: int128 = 0
    is_underlying: bool = False
    i, j, is_underlying = Registry(_registry).get_coin_indices(_pool, _from, _to)  # dev: no market
    if is_underlying and _registry == self.factory_registry and Registry(_registry).is_meta(_pool):
        is_underlying = False

    # record initial balance
    if _to == ETH_ADDRESS:
        initial_balance = self.balance
    else:
        initial_balance = ERC20(_to).balanceOf(self)

    # perform / verify input transfer
    if _from == ETH_ADDRESS:
        eth_amount = _amount
    else:
        response: Bytes[32] = raw_call(
            _from,
            concat(
                method_id("transferFrom(address,address,uint256)"),
                convert(_sender, bytes32),
                convert(self, bytes32),
                convert(_amount, bytes32),
            ),
            max_outsize=32,
        )
        if len(response) != 0:
            assert convert(response, bool)

    # approve input token
    if not self.is_approved[_from][_pool]:
        response: Bytes[32] = raw_call(
            _from,
            concat(
                method_id("approve(address,uint256)"),
                convert(_pool, bytes32),
                convert(MAX_UINT256, bytes32),
            ),
            max_outsize=32,
        )
        if len(response) != 0:
            assert convert(response, bool)
        self.is_approved[_from][_pool] = True

    # perform coin exchange
    if is_underlying:
        CurvePool(_pool).exchange_underlying(i, j, _amount, _expected, value=eth_amount)
    else:
        CurvePool(_pool).exchange(i, j, _amount, _expected, value=eth_amount)

    # perform output transfer
    if _to == ETH_ADDRESS:
        received_amount = self.balance - initial_balance
        raw_call(_receiver, b"", value=received_amount)
    else:
        received_amount = ERC20(_to).balanceOf(self) - initial_balance
        response: Bytes[32] = raw_call(
            _to,
            concat(
                method_id("transfer(address,uint256)"),
                convert(_receiver, bytes32),
                convert(received_amount, bytes32),
            ),
            max_outsize=32,
        )
        if len(response) != 0:
            assert convert(response, bool)

    log TokenExchange(_sender, _receiver, _pool, _from, _to, _amount, received_amount)

    return received_amount


@payable
@external
@nonreentrant("lock")
def exchange_with_best_rate(
    _from: address,
    _to: address,
    _amount: uint256,
    _expected: uint256,
    _receiver: address = msg.sender,
) -> uint256:
    """
    @notice Perform an exchange using the pool that offers the best rate
    @dev Prior to calling this function, the caller must approve
         this contract to transfer `_amount` coins from `_from`
         Does NOT check rates in factory-deployed pools
    @param _from Address of coin being sent
    @param _to Address of coin being received
    @param _amount Quantity of `_from` being sent
    @param _expected Minimum quantity of `_from` received
           in order for the transaction to succeed
    @param _receiver Address to transfer the received tokens to
    @return uint256 Amount received
    """
    if _from == ETH_ADDRESS:
        assert _amount == msg.value, "Incorrect ETH amount"
    else:
        assert msg.value == 0, "Incorrect ETH amount"

    registry: address = self.registry
    best_pool: address = ZERO_ADDRESS
    max_dy: uint256 = 0
    for i in range(65536):
        pool: address = Registry(registry).find_pool_for_coins(_from, _to, i)
        if pool == ZERO_ADDRESS:
            break
        dy: uint256 = self._get_exchange_amount(registry, pool, _from, _to, _amount)
        if dy > max_dy:
            best_pool = pool
            max_dy = dy

    return self._exchange(registry, best_pool, _from, _to, _amount, _expected, msg.sender, _receiver)


@payable
@external
@nonreentrant("lock")
def exchange(
    _pool: address,
    _from: address,
    _to: address,
    _amount: uint256,
    _expected: uint256,
    _receiver: address = msg.sender,
) -> uint256:
    """
    @notice Perform an exchange using a specific pool
    @dev Prior to calling this function, the caller must approve
         this contract to transfer `_amount` coins from `_from`
         Works for both regular and factory-deployed pools
    @param _pool Address of the pool to use for the swap
    @param _from Address of coin being sent
    @param _to Address of coin being received
    @param _amount Quantity of `_from` being sent
    @param _expected Minimum quantity of `_from` received
           in order for the transaction to succeed
    @param _receiver Address to transfer the received tokens to
    @return uint256 Amount received
    """
    if _from == ETH_ADDRESS:
        assert _amount == msg.value, "Incorrect ETH amount"
    else:
        assert msg.value == 0, "Incorrect ETH amount"

    registry: address = self.registry
    if Registry(registry).get_lp_token(_pool) == ZERO_ADDRESS:
        registry = self.factory_registry
    return self._exchange(registry, _pool, _from, _to, _amount, _expected, msg.sender, _receiver)


@view
@external
def get_best_rate(
    _from: address, _to: address, _amount: uint256, _exclude_pools: address[8] = EMPTY_POOL_LIST
) -> (address, uint256):
    """
    @notice Find the pool offering the best rate for a given swap.
    @dev Checks rates for regular and factory pools
    @param _from Address of coin being sent
    @param _to Address of coin being received
    @param _amount Quantity of `_from` being sent
    @param _exclude_pools A list of up to 8 addresses which shouldn't be returned
    @return Pool address, amount received
    """
    best_pool: address = ZERO_ADDRESS
    max_dy: uint256 = 0

    registry: address = self.registry
    for i in range(65536):
        pool: address = Registry(registry).find_pool_for_coins(_from, _to, i)
        if pool == ZERO_ADDRESS:
            break
        elif pool in _exclude_pools:
            continue
        dy: uint256 = self._get_exchange_amount(registry, pool, _from, _to, _amount)
        if dy > max_dy:
            best_pool = pool
            max_dy = dy

    registry = self.factory_registry
    for i in range(65536):
        pool: address = Registry(registry).find_pool_for_coins(_from, _to, i)
        if pool == ZERO_ADDRESS:
            break
        elif pool in _exclude_pools:
            continue
        if ERC20(pool).totalSupply() == 0:
            # ignore pools without TVL as the call to `get_dy` will revert
            continue
        dy: uint256 = self._get_exchange_amount(registry, pool, _from, _to, _amount)
        if dy > max_dy:
            best_pool = pool
            max_dy = dy

    return best_pool, max_dy


@view
@external
def get_exchange_amount(_pool: address, _from: address, _to: address, _amount: uint256) -> uint256:
    """
    @notice Get the current number of coins received in an exchange
    @dev Works for both regular and factory-deployed pools
    @param _pool Pool address
    @param _from Address of coin to be sent
    @param _to Address of coin to be received
    @param _amount Quantity of `_from` to be sent
    @return Quantity of `_to` to be received
    """
    registry: address = self.registry
    if Registry(registry).get_lp_token(_pool) == ZERO_ADDRESS:
        registry = self.factory_registry
    return self._get_exchange_amount(registry, _pool, _from, _to, _amount)


@view
@external
def get_input_amount(_pool: address, _from: address, _to: address, _amount: uint256) -> uint256:
    """
    @notice Get the current number of coins required to receive the given amount in an exchange
    @param _pool Pool address
    @param _from Address of coin to be sent
    @param _to Address of coin to be received
    @param _amount Quantity of `_to` to be received
    @return Quantity of `_from` to be sent
    """
    registry: address = self.registry

    i: int128 = 0
    j: int128 = 0
    is_underlying: bool = False
    i, j, is_underlying = Registry(registry).get_coin_indices(_pool, _from, _to)
    amp: uint256 = Registry(registry).get_A(_pool)
    fee: uint256 = Registry(registry).get_fees(_pool)[0]

    balances: uint256[MAX_COINS] = empty(uint256[MAX_COINS])
    rates: uint256[MAX_COINS] = empty(uint256[MAX_COINS])
    decimals: uint256[MAX_COINS] = empty(uint256[MAX_COINS])
    n_coins: uint256 = Registry(registry).get_n_coins(_pool)[convert(is_underlying, uint256)]
    if is_underlying:
        balances = Registry(registry).get_underlying_balances(_pool)
        decimals = Registry(registry).get_underlying_decimals(_pool)
        for x in range(MAX_COINS):
            if x == n_coins:
                break
            rates[x] = 10**18
    else:
        balances = Registry(registry).get_balances(_pool)
        decimals = Registry(registry).get_decimals(_pool)
        rates = Registry(registry).get_rates(_pool)

    for x in range(MAX_COINS):
        if x == n_coins:
            break
        decimals[x] = 10 ** (18 - decimals[x])

    calculator: address = self.pool_calculator[_pool]
    if calculator == ZERO_ADDRESS:
        calculator = self.default_calculator
    return Calculator(calculator).get_dx(n_coins, balances, amp, fee, rates, decimals, i, j, _amount)


@view
@external
def get_exchange_amounts(
    _pool: address,
    _from: address,
    _to: address,
    _amounts: uint256[CALC_INPUT_SIZE]
) -> uint256[CALC_INPUT_SIZE]:
    """
    @notice Get the current number of coins required to receive the given amount in an exchange
    @param _pool Pool address
    @param _from Address of coin to be sent
    @param _to Address of coin to be received
    @param _amounts Quantity of `_to` to be received
    @return Quantity of `_from` to be sent
    """
    registry: address = self.registry

    i: int128 = 0
    j: int128 = 0
    is_underlying: bool = False
    balances: uint256[MAX_COINS] = empty(uint256[MAX_COINS])
    rates: uint256[MAX_COINS] = empty(uint256[MAX_COINS])
    decimals: uint256[MAX_COINS] = empty(uint256[MAX_COINS])

    amp: uint256 = Registry(registry).get_A(_pool)
    fee: uint256 = Registry(registry).get_fees(_pool)[0]
    i, j, is_underlying = Registry(registry).get_coin_indices(_pool, _from, _to)
    n_coins: uint256 = Registry(registry).get_n_coins(_pool)[convert(is_underlying, uint256)]

    if is_underlying:
        balances = Registry(registry).get_underlying_balances(_pool)
        decimals = Registry(registry).get_underlying_decimals(_pool)
        for x in range(MAX_COINS):
            if x == n_coins:
                break
            rates[x] = 10**18
    else:
        balances = Registry(registry).get_balances(_pool)
        decimals = Registry(registry).get_decimals(_pool)
        rates = Registry(registry).get_rates(_pool)

    for x in range(MAX_COINS):
        if x == n_coins:
            break
        decimals[x] = 10 ** (18 - decimals[x])

    calculator: address = self.pool_calculator[_pool]
    if calculator == ZERO_ADDRESS:
        calculator = self.default_calculator
    return Calculator(calculator).get_dy(n_coins, balances, amp, fee, rates, decimals, i, j, _amounts)


@view
@external
def get_calculator(_pool: address) -> address:
    """
    @notice Set calculator contract
    @dev Used to calculate `get_dy` for a pool
    @param _pool Pool address
    @return `CurveCalc` address
    """
    calculator: address = self.pool_calculator[_pool]
    if calculator == ZERO_ADDRESS:
        return self.default_calculator
    else:
        return calculator


@external
def update_registry_address() -> bool:
    """
    @notice Update registry address
    @dev The registry address is kept in storage to reduce gas costs.
         If a new registry is deployed this function should be called
         to update the local address from the address provider.
    @return bool success
    """
    address_provider: address = self.address_provider.address
    self.registry = AddressProvider(address_provider).get_registry()
    self.factory_registry = AddressProvider(address_provider).get_address(3)

    return True


@external
def set_calculator(_pool: address, _calculator: address) -> bool:
    """
    @notice Set calculator contract
    @dev Used to calculate `get_dy` for a pool
    @param _pool Pool address
    @param _calculator `CurveCalc` address
    @return bool success
    """
    assert msg.sender == self.address_provider.admin()  # dev: admin-only function

    self.pool_calculator[_pool] = _calculator

    return True


@external
def set_default_calculator(_calculator: address) -> bool:
    """
    @notice Set default calculator contract
    @dev Used to calculate `get_dy` for a pool
    @param _calculator `CurveCalc` address
    @return bool success
    """
    assert msg.sender == self.address_provider.admin()  # dev: admin-only function

    self.default_calculator = _calculator

    return True


@external
def claim_balance(_token: address) -> bool:
    """
    @notice Transfer an ERC20 or ETH balance held by this contract
    @dev The entire balance is transferred to the owner
    @param _token Token address
    @return bool success
    """
    assert msg.sender == self.address_provider.admin()  # dev: admin-only function

    if _token == ETH_ADDRESS:
        raw_call(msg.sender, b"", value=self.balance)
    else:
        amount: uint256 = ERC20(_token).balanceOf(self)
        response: Bytes[32] = raw_call(
            _token,
            concat(
                method_id("transfer(address,uint256)"),
                convert(msg.sender, bytes32),
                convert(amount, bytes32),
            ),
            max_outsize=32,
        )
        if len(response) != 0:
            assert convert(response, bool)

    return True


@external
def set_killed(_is_killed: bool) -> bool:
    """
    @notice Kill or unkill the contract
    @param _is_killed Killed status of the contract
    @return bool success
    """
    assert msg.sender == self.address_provider.admin()  # dev: admin-only function
    self.is_killed = _is_killed

    return True