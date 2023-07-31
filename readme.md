# vyper reentrancy

this repo aims to study potentially vulnerable contracts.

## usage

to download sources and check them using several rules, run `python find_vulnerable.py`.

it would use etherscan-provided list of contracts to go through, would narrow them down and only save the interesting ones.

you would need to obtain several api keys to load the contracts.

<details>
    <summary>api keys and where to obtain them</summary>
    1. ARBISCAN_API_KEY - arbiscan.io
    1. SNOWTRACE_API_KEY - snowtrace.io
    1. CELOSCAN_API_KEY - celoscan.io
    1. ETHERSCAN_API_KEY - etherscan.io
    1. FTMSCAN_API_KEY - ftmscan.com
    1. GNOSISSCAN_API_KEY - gnosisscan.io
    1. MOONSCAN_API_KEY - moonscan.io
    1. OPTIMISTIC_ETHERSCAN_API_KEY - optimistic.etherscan.io
    1. POLYGONSCAN_API_KEY - polygonscan.com
</details>

luckily, you could find them all in the `contracts/` folder.
