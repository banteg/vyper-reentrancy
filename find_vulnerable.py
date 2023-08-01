import csv
import os
import re
from collections import Counter
from itertools import cycle
from pathlib import Path

import requests
from diskcache import Cache
from rich import print

VULNERABLE_VERSIONS = {"0.2.15", "0.2.16", "0.3.0"}
ETHERSCAN_API_URLS = {
    "arb": "https://api.arbiscan.io/api",
    "avax": "https://api.snowtrace.io/api",
    "celo": "https://api.celoscan.io/api",
    "ethereum": "https://api.etherscan.io/api",
    "ftm": "https://api.ftmscan.com/api",
    "gnosis": "https://api.gnosisscan.io/api",
    "moonbeam": "https://api-moonbeam.moonscan.io/api",
    "op": "https://api-optimistic.etherscan.io/api",
    "poly": "https://api.polygonscan.com/api",
}
ETHERSCAN_API_VARS = {
    "arb": "ARBISCAN_API_KEY",
    "avax": "SNOWTRACE_API_KEY",
    "celo": "CELOSCAN_API_KEY",
    "ethereum": "ETHERSCAN_API_KEY",
    "ftm": "FTMSCAN_API_KEY",
    "gnosis": "GNOSISSCAN_API_KEY",
    "moonbeam": "MOONSCAN_API_KEY",
    "op": "OPTIMISTIC_ETHERSCAN_API_KEY",
    "poly": "POLYGONSCAN_API_KEY",
}
api_keys = {
    network: cycle(os.environ[key].split(","))
    for network, key in ETHERSCAN_API_VARS.items()
}
cache = Cache(".cache")


@cache.memoize()
def get_source(network, address):
    params = {
        "module": "contract",
        "action": "getsourcecode",
        "address": address,
        "apikey": next(api_keys[network]),
    }
    resp = requests.get(ETHERSCAN_API_URLS[network], params=params)
    resp.raise_for_status()
    return resp.json()


def find_closing_paren(text):
    stack = []
    slices = []
    for i, char in enumerate(text):
        if char == "(":
            stack.append(i)
        if char == ")":
            slices.append(slice(stack.pop(), i + 1))
            if not stack:
                return text[slices[-1]]


def could_be_vulnerable(source):
    nonreentrants = Counter(re.findall(r'@nonreentrant\(.*\)', source))
    multiple_nonreentrants_with_same_key = nonreentrants and nonreentrants.most_common()[0][1] > 1

    if "@payable" in source and multiple_nonreentrants_with_same_key:
        print("[red]• has payable")
        return True

    if "raw_call" in source:
        vulnerable_calls = []

        for match in re.finditer("raw_call", source):
            inner = find_closing_paren(source[match.start() :])
            print(inner)
            safe_calls = [
                # erc20 methods using raw call for handing a missing return value
                "transfer(address,uint256)",
                "transferFrom(address,address,uint256)",
                "approve(address,uint256)",
                # appears in hundred finance contracts
                "deposit_sig",
                "withdraw_sig",
                "reward_sigs",
                # appears in curve registry
                "rate_method_id",
                # appears in `_uint_to_string`
                "IDENTITY_PRECOMPILE",
                # appears in unaagi vault
                "APPROVE",
                "TRANSFER",
                # known method id probably indicates a safe use
                "method_id(",
            ]
            if not any(call in inner for call in safe_calls):
                print("[red]• no safe call", inner)
                vulnerable_calls.append(inner)

        return bool(vulnerable_calls) and multiple_nonreentrants_with_same_key
    else:
        return False


def main():
    contracts_dir = Path("contracts")
    contracts_dir.mkdir(exist_ok=True)

    for network in ETHERSCAN_API_URLS:
        network_dir = contracts_dir / network
        network_dir.mkdir(exist_ok=True)
        reader = csv.reader(open(f"etherscan-export/{network}.csv"))

        for address, version in reader:
            if version not in VULNERABLE_VERSIONS:
                continue

            print(f"\n{network} {address} {version}")
            contract_path = network_dir / f"{address}.vy"

            resp = get_source(network, address)
            source = resp["result"][0]["SourceCode"]
            version = resp["result"][0]["CompilerVersion"].split(":")[-1]

            if could_be_vulnerable(source):
                contract_path.write_text(source)
                print("[bold red]• could be vulnerable, saved")
            else:
                print("[green]• contract looks safe")
                if contract_path.exists():
                    print("[green]• narrowed down to non vulnerable")
                    contract_path.unlink()


if __name__ == "__main__":
    main()
