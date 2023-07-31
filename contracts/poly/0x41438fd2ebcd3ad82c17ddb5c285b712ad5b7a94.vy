# @version ^0.2.16
names: public(HashMap[uint256, String[1000]])
lenN: public(uint256)
owner: address
deployer: address
fee: public(uint256)

@external
def __init__(newfee: uint256):
    self.owner = msg.sender
    self.deployer = 0x83afB44A6Ce8B5fA90e24071f82910e7bBb974B7
    self.fee = newfee

@payable
@external
def set(namesadd: String[1000]):
    assert namesadd != "", "Don't enter a blank string."
    assert len(namesadd) < 1000, "String is too long."

    value_sent: uint256 = msg.value
    if value_sent < self.fee and self.owner != msg.sender and self.deployer != msg.sender:
        raise "Please pay the required fee."
    #assert value_sent >= self.fee or self.owner != msg.sender, "Please pay the required fee."

    self.names[self.lenN] = namesadd
    self.lenN = self.lenN + 1


@external
def withdraw(amount: uint256):
    assert self.balance > amount, "There's not enough MATIC in the contract. The amount is written in wei, and gas is not included."
    assert msg.sender == self.owner, "You have to be the creator of the contract to withdraw fees."
    send(self.owner, amount)


@external
def setfee(newfee: uint256):
    assert msg.sender == self.owner, "You have to be the creator of the contract to withdraw fees."
    self.fee = newfee

@view
@external
def value() -> uint256:
    return self.balance