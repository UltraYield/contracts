# UltraYield contracts
This is a repo containing a public copy of UltraYield vault contracts. The goal of our vaults is to give users the ability to deposit the assets for curators to allocate them in the most convenient way using the custody solution they deem necessary to securely implement the strategies.

The default use case is for strategy curators to use an MPC wallet that allows a whitelist setup that limits the protocols that can be used and contracts/addresses where the funds can be allocated. This way we get full security of the provided solution (eg. an ERC-20 token can't simply be withdrawn to a new address which wasn't whitelisted by a trusted set of operators) while also maintaining flexibility of swiftly integrating new protocols that might provide great market opportunities, without the tedious process of on-chain verification of all the necessary interactions that might be necessary.

Upon the deposit the funds are immediately transferred to an address that's mutually controlled by a curator and infrastructure provider, but they are not 
required to stay within this initial wallet, and can be distributed to other wallets or even chains, if the strategy might require so.

This repository is the on-chain core for vault accounting, redeem lifecycle management, pricing integration, and operational controls.

## Documentation

- [Overview for users](docs/OVERVIEW.md)
- [Vault economics](docs/ECONOMICS.md)
- [Vault lifecycle and flows](docs/FLOWS.md)
- [Contracts architecture](docs/ARCHITECTURE.md)
- [Oracles system](docs/ORACLES.md)
- [Roles and permissions](docs/PERMISSIONS.md)

The pricing can be performed independently with the calculation done off-chain and the pricing data supplied to a provided oracle address, which can have a separate set of owners and is expected to be mutually agreed upon by the infrastructure provider and the curator. Such a setup allows for a flexibility of inclusion of the uncrystallized rewards that the curator is certain will be delivered in the future but currently can't be fetched on-chain. The curators always use a conservative estimate for the price to ensure that the redemptions can be fully honored in case users decide to withdraw the funds.

## Audits

[See the list of audits](/audits/)
