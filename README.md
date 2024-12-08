# Modern POSDAO
A modernized version for [POSDAO](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=3368483) consensus with better security, new optimizations, the latest Solidity version, and the support for a wide variety of new consensus mechanisms such as [HBBFT](https://eprint.iacr.org/2016/199.pdf).

## Project Overview
### Goals
- [ ] Port POSDAO AuRa consensus to a more modern version of Solidity and implement new optimizations.
- [ ] Restructure bridge related code to utilize ERC20 instead of ERC677 due to previous security issues.
- [ ] Implement support for additional consensus algorithms such as HoneyBadger BFT.

### File Structure
The smart contract codebase is split amongst the following folders:
- ``src`` - Codebase for the POSDAO smart contracts
  - ``src/AuRa`` - Smart contract code related to the implementation of Authority Round in POSDAO.
  - ``src/hbbft`` - Smart contract code related to the implementation of HoneyBadger BFT in POSDAO.
  - ``src/shared`` - Shared codebase between the consensus implementations.
- ``test`` - POSDAO smart contract tests
- ``scripts`` Deployment and other utility scripts for the POSDAO contracts
