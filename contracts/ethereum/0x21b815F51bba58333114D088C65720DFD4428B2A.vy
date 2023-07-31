# version ^0.2.16

@external
@payable
def foo(_receiver: address):
    send(_receiver, msg.value)