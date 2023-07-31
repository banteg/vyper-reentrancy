import csv
import os
from itertools import cycle
from pathlib import Path

import requests

VULNERABLE_VERSIONS = {"0.2.15", "0.2.16", "0.3.0"}
ETHERSCAN_API_URLS = {
    "arb": "https://api.arbiscan.io/api",
    "avax": "https://api.snowtrace.io/api",
    "celo": "https://api.celoscan.io/api",
    "ethereum": "https://api.etherscan.io/api",
    "ftm": "https://api.ftmscan.io/api",
    "gnosis": "https://api.gnosisscan.io/api",
    "moonbeam": "https://api.moonscan.io/api",
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


def could_be_vulnerable(source):
    return "raw_call" in source or "@payable" in source


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

            contract_path = network_dir / f"{address}.vy"
            if contract_path.exists():
                continue

            print(network, address, version)
            resp = get_source(network, address)
            source = resp["result"][0]["SourceCode"]
            version = resp["result"][0]["CompilerVersion"].split(":")[-1]

            if could_be_vulnerable(source):
                contract_path.write_text(source)
                print("could be vulnerable, saved")
            else:
                print("contract looks safe")


if __name__ == "__main__":
    main()
