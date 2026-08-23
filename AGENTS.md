# Repository Guidance

## Scope

This repository develops experimental EVM standards for application-level semantic queries, action preparation, and client-mediated external HTTP requests.

## Stack

- Solidity contracts and tests use Foundry.
- TypeScript client code and tests use Bun.
- EVM interactions use viem.
- Runtime input and boundary validation uses Zod.

## Working Agreements

- Read the relevant files in `docs/` and `spec/` before changing an interface or its behavior.
- Treat every ABI as experimental until the specification explicitly marks it stable.
- Prefer the smallest interface supported by implemented use cases.
- Do not add compatibility behavior for an experimental ABI unless explicitly requested.
- Keep normative requirements in `spec/`; keep rationale and open design questions in `docs/`.
- Update `docs/implementation-notes.md` when implementation work changes behavior or resolves a design question.
- Run `forge fmt` after changing Solidity.
- Run the configured formatter, linter, typecheck, and tests after changing TypeScript.
- Never log or persist values used to satisfy sensitive request requirements.

## Specifications

Normative terms such as MUST, SHOULD, and MAY are interpreted as described by RFC 2119 and RFC 8174.
