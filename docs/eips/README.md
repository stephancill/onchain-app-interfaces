# ERC Working Papers

This directory contains pre-number drafts prepared from the active ERC template and EIP-1 guidance.

The guidance review used `ethereum/EIPs` at `ac450a4ab2f37387385ee9c54b62f518d97e6cc9` and `ethereum/ercs` at `53b6c669c3cb49709c552c87a86db36697f15d63`. Both clones are retained under ignored `third-party/` paths for reference.

- `erc-draft-external-request.md` defines client-mediated HTTP continuations.
- `erc-draft-application-interfaces.md` defines the separate optional Application Queries and Application Actions interfaces.

These documents are working papers, not published ERCs. Before either is submitted:

1. Open a dedicated Ethereum Magicians discussion and replace the placeholder `discussions-to` URL.
2. Submit each proposal separately to the canonical ERC repository.
3. Let an editor assign its number, add the `eip` preamble field, and rename the file.
4. Re-run the canonical ERC repository's `eipw`, Markdown, link, spelling, and site checks.

The drafts deliberately leave descriptor serialization implementation-defined. The experimental JSON profile in `spec/DESCRIPTORS.md` has demonstrated generic clients across multiple adapters, but content addressing, schema evolution, and authenticity remain open design work.
