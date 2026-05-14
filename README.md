## Solidity Development Template(Foundry)

[![CI Status](https://github.com/alchemix-finance/alchemix-sol-template/actions/workflows/test/badge.svg)](https://github.com/alchemix-finance/alchemix-sol-template/actions)

This template repo is a quick and easy way to get started with a new Solidity project. It comes with a number of features that are useful for developing and deploying smart contracts. Such as pre-commit hooks for formatting, auto generated documentation, and more

This template is inspired by and largely based on Polygon's [Foundry Template](https://github.com/0xPolygon/foundry-template). We express our thanks to Polygon and their smart contracts and security teams for publicly publishing their work for general use.

#### Table of Contents

- [Install and Quickstart](#install-and-quickstart)
- [Pre-commit Hooks](#pre-commit-hooks)
- [Actions](#actions)
- [Audits](#audits)
- [Branching](#branching)
  - [Main](#main)
  - [Staging](#staging)
  - [Dev](#dev)
  - [Feature](#feature)
  - [Fix](#fix)
- [Code Practices](#code-practices)
  - [Code Style](#code-style)
  - [Interfaces](#interfaces)
  - [NatSpec and Comments](#natspec-and-comments)
  - [Scripts](#scripts)
- [Versioning](#versioning)
- [Testing](#testing)
  - [Deployer Template](#deployer-template)
- [Deployment](#deployment)
  - [Deployer Template](#deployer-template-1)
  - [Deployment](#deployment-1)
  - [Deployment Info Generation](#deployment-info-generation)
- [Deployer Template Script](#deployer-template-script)
- [Releases](#releases)
- [Docs](#docs)
- [License](#license)

## Install and Quickstart

Follow these steps to set up your local environment for development:

- [Install foundry](https://book.getfoundry.sh/getting-started/installation)
- Install dependencies: `forge install` (TODO: consider Soldeer)
- [Install pre-commit](https://pre-commit.com/#installation)
- Install pre commit hooks: `pre-commit install`
- Build contracts: `forge build`
- Test contracts: `forge test`
- Run coverage: `forge coverage`

Note: the CI badge above is configured to run from `github.com/alchemix-finance/alchemix-sol-template/`. When forking to use this template, the badge should be modified (via the url embedded in the Markdown at the beginning of the README) to point at the target repo.

## Pre-commit Hooks

Follow the [installation steps](#install) to enable pre-commit hooks. To ensure consistency in our formatting `pre-commit` is used to check whether code was formatted properly and the documentation is up to date. Whenever a commit does not meet the checks implemented by pre-commit, the commit will fail and the pre-commit checks will modify the files to make the commits pass. Include these changes in your commit for the next commit attempt to succeed. On pull requests the CI checks whether all pre-commit hooks were run correctly.
This repo includes the following pre-commit hooks that are defined in the `.pre-commit-config.yaml`:

- `mixed-line-ending`: This hook ensures that all files have the same line endings (LF).
- `format`: This hook uses `forge fmt` to format all Solidity files.
- `doc`: This hook uses `forge doc` to automatically generate documentation for all Solidity files whenever the NatSpec documentation changes. The `script/util/doc_gen.sh` script is used to generate documentation. Forge updates the commit hash in the documentation automatically. To only generate new documentation when the documentation has actually changed, the script checks whether more than just the hash has changed in the documentation and discard all changes if only the hash has changed.
- `prettier`: All remaining files are formatted using prettier.

## Actions

Scripts for [GitHub Actions](https://docs.github.com/en/actions) is included in `.github/workflows/`. `test.yaml` is run on any PR, and runs all forge tests, inspects coverage, and runs [Slither](https://github.com/crytic/slither). There is also a script barring PRs to main from anywhere other than the staging branch, and another running the pre-commit hooks before a PR.

## Audits

Any audit reports received on the codebase should be added to the repo in a top-level `audits/` directory.

## Branching

This section outlines the branching strategy of this repo.

### Main

The main branch is supposed to reflect the deployed state on all networks. Any pull requests into this branch MUST come from the staging branch. The main branch is protected and requires a separate code review whenever it is updated. Whenever the main branch is updated, a new release is created with the latest version. For more information on versioning, check [here](#versioning).

### Staging

The staging branch reflects new code complete deployments or upgrades containing fixes and/or features. Any pull requests into this branch MUST come from the dev branch. The staging branch is used for security audits and deployments. Once the deployment is complete the branch can be merged into main. For more information on the deployment check [here](#deployment--versioning).

TODO: deployment docgen/logging

### Dev

This is the active development branch. All pull requests into this branch MUST come from fix or feature branches. Upon code completion this branch is merged into staging for auditing and deployment.

### Feature

Any new feature should be developed on a separate branch. The naming convention for these branches is `feat/*`. Once the feature is complete, a pull request into the dev branch can be created.

### Fix

Any bug fixes should be developed on a separate branch. The naming convention for these branches is `fix/*`. Once the fix is complete, a pull request into the dev branch can be created.

## Code Practices

### Code Style

The repo follows the official [Solidity Style Guide](https://docs.soliditylang.org/en/latest/style-guide.html). In addition to that, this repo also borrows the following rules from [OpenZeppelin](https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/GUIDELINES.md#solidity-conventions):

- Internal or private state variables or functions should have an underscore prefix.

  ```solidity
  contract TestContract {
      uint256 private _privateVar;
      uint256 internal _internalVar;
      function _testInternal() internal { ... }
      function _testPrivate() private { ... }
  }
  ```

- Events should generally be emitted immediately after the state change that they
  represent, and should be named in the past tense. Some exceptions may be made for gas
  efficiency if the result doesn't affect observable ordering of events.

  ```solidity
  function _burn(address who, uint256 value) internal {
      super._burn(who, value);
      emit TokensBurned(who, value);
  }
  ```

- Interface names should have a capital I prefix.

  ```solidity
  interface IERC777 {
  ```

- Contracts not intended to be used standalone should be marked abstract
  so they are required to be inherited to other contracts.

  ```solidity
  abstract contract AccessControl is ..., {
  ```

- Unchecked arithmetic blocks should contain comments explaining why overflow is guaranteed not to happen. If the reason is immediately apparent from the line above the unchecked block, the comment may be omitted.

### Interfaces

Every contract MUST implement their corresponding interface that includes all externally callable functions, errors and events.

### NatSpec and Comments

Interfaces should be the entrypoint for all contracts. When exploring the a contract within the repository, the interface MUST contain all relevant information to understand the functionality of the contract in the form of NatSpec comments. This includes all externally callable functions, errors and events. The NatSpec documentation MUST be added to the functions (including view/pure functions), errors and events within the interface. This allows a reader to understand the functionality of a function before moving on to the implementation. The implementing functions MUST point to the NatSpec documentation in the interface using `@inheritdoc`. Internal and private functions do not require function-level NatSpec documentation. While code should be kept readable and self-explanatory to the extent possible, additional comments are welcome for explaining design reasoning, algorithms and calculations, or adding context.

### Scripts

Any scripts needed for the usage of the code being written and/or running tests should be updated as the code is written and merged in. This includes deployment scripts and scripts for updating prxies when their implementation changes.

## Versioning

This repo utilizes [semantic versioning](https://semver.org/) for smart contracts. An `IVersioned` interface is included in the [interfaces directory](src/interface/IVersioned.sol) exposing a unified versioning interface for all contracts. This version MUST be included in all contracts, whether they are upgradeable or not, to be able to easily match deployed versions. For example, in the case of a non-upgradeable contract one version could be deployed to a network and later a new version might be deployed to another network.

Whenever contracts are modified, only the version of the changed contracts should be updated. Unmodified contracts should remain on the version of their last change.

## Testing

Pull Requests to `dev` should have at least 95% branch coverage, optimally more. Rules should be set blocking merges with less coverage, where possible.

While branch coverage is a good start, care must be taken to ensure that tests actually test the invariants of the system. Scenario tests simulating common flows usage of the contracts in sufficiently realistic conditions are needed. In addition, forge's native testing features, fuzzing and invariant testing, should be leveraged wherever possible. Special attention should be given to properly articulating invariants.

Helper functions for common tasks inside tests and commonly used constants should be set up and included in a base test contract inherited by other test contracts. NatSpec should be used on these functions, and for constants that are not immediately obvious.

### Review

Review should be required prior to any merge into `dev`. Optimially, at least two other parties should review. This can be subject to change based on team size. In an organization with a dedicated Security team, Security shold participate in the reviews.

Review includes inspection of what production code has changed, verifying that the tests assert intended behavior and absence of unintended effects, and running the tests.

### Deployment

This repo sets up the following RPCs in the `foundry.toml` file:

- mainnet: Ethereum Mainnet
- sepolia: Ethereum Sepolia

To deploy the contracts, provide the `--broadcast` flag to the forge script command. Should the etherscan verification time out, it can be picked up again by replacing the `--broadcast` flag with `--resume`.
Deploy the contracts to one of the predefined networks by providing the according key with the `--rpc-url` flag. Most of the predefined networks require the `INFURA_KEY` environment variable to be set in the `.env` file.
Including the `--verify` flag will verify deployed contracts on Etherscan. Define the appropriate environment variable for the Etherscan api key in the `.env` file.

This repo utilizes versioned deployments. Any changes to a contract should update the version of this specific contract. A script is provided that extracts deployment information from the `run-latest.json` file within the `broadcast` directory generated while the forge script runs. From this information a JSON and markdown file is generated containing various information about the deployment itself as well as past deployments.

Once everything is ready, contracts can be updated/deployed and verified using the following:

```shell
forge script script/Deploy.s.sol --broadcast --rpc-url <rpc_url> --verify
```

## Releases

Releases should be created whenever the code on the main branch is updated to reflect a deployment or an upgrade on a network. The release should be named after the version of the contracts deployed or upgraded.
The release should include the following:

- In case of a MAJOR version
  - changelog
  - summary of breaking changes
  - summary of new features
  - summary of fixes
- In case of a MINOR version
  - changelog
  - summary of new features
  - summary of fixes
- In case of a PATCH version
  - changelog
  - summary of fixes
- Deployment information (can be copied from the generated log files)
  - Addresses of the deployed contracts

## Docs

The documentation and architecture diagrams for the contracts within this repo can be found [here](docs/).
Detailed documentation generated from the NatSpec documentation of the contracts can be found [here](docs/autogen/src/src/).

## License

[License Alchemix Association](./LICENSE-BSD-V3_LICENSE-MIT-MYT.txt)
