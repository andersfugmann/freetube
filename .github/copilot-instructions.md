# Copilot Instructions

## Project Overview

FreeTube is an OCaml-based YouTube streaming service built on Eio (structured concurrency) with cohttp-eio for HTTP and DLNA/Airplay for media casting.

## Build & Run

- `make dep` — install opam dependencies
- `make build` — build the project
- `make test` — run tests
- `make run` — run the executable

## Coding Style and Patterns

### General Principles

- Use idiomatic OCaml and functional paradigms throughout.
- Prefer pure functions. Side effects should be isolated at module boundaries.
- Do not use mutable data structures.
- Use `Base` module (shadows stdlib `String`, `List`, etc.).
- Every file should start with `open! Base`.
- Use `Eio` for async I/O (OCaml 5 effects-based). One fiber per request.
- Prefer existing opam libraries over manual implementations.
- Do not use ocamlformat.
- Never add type annotations unless strictly required by the compiler. Rely on type inference.
- YAGNI — do not add configurability, abstraction layers, or generality that is not needed right now. Hardcode what is constant today.

### Module Design

- Each module must be clearly scoped in terms of area and responsibility.
- Minimize dependencies between modules.
- Prefer defining new libraries to isolate logic (e.g. Airplay protocol, DLNA handling, Codecs, Streaming Protocols).
- Libraries live under `src/<library>/` and the dune library name must match the directory name.
- Keep module hierarchies flat. Avoid wrapping types in unnecessary nested modules — if a file defines one main thing, use `type t` at the top level.
- Never use `(wrapped false)` in dune files. Use wrapped (default); `open Lib` at the top of source files that reference multiple modules inside a library.
- Never use `include` to re-export another module's definitions unless strictly necessary (e.g. functor instantiation). It hides where implementations live and makes the codebase harder to navigate. Instead, qualify with the full module path or use `open` at the use site.
- Functions should only take parameters they directly use. Never pass a large config/context record when only one field is needed.

### Types

- ADT constructors that carry no useful information should be nullary (e.g. `Unknown` not `Unknown of string` if the string is never acted on).
- Prefer `String.split` and matching the full segment list over repeated `lsplit2` calls.
- For option-typed fields with a sentinel value (like `"none"` meaning absent), fold the option into the custom `of_yojson` — return `Ok None` directly rather than returning `Error` and relying on external wrapping.

### Control Flow

- Prefer short call chains and piping (`|>` operator).
- Avoid imperative constructs (`for`, `while`, `if`). Use pattern matching zealously.
- Never use `if ... else if ...` chains. Use `match` with where-clauses (`let ... in`) or guards instead.
- Encode invariants into the type system to eliminate unreachable branches.

### Data Processing

- Prefer higher-order functions (`map`, `fold`, `filter`, `iter`, etc.) over recursion where possible.
- Never guard on the empty list before traversing a list — `List.map` et al. handle `[]` naturally.
- Avoid complex data structures for performance when element count is expected to be very small — use lists in general.

### Serialization

- Always use `ppx_deriving_yojson` for JSON serialization and deserialization.
- Never do manual Yojson parsing or construction.

### Error Handling

- Raise exceptions (`failwith`, `_exn` variants) as the default for internal logic errors, parse failures from already-received data, and invariant violations. An error that causes a session to be torn down is not recoverable — use exceptions, not `Result.t`.
- Use `Result.t` only when an error is genuinely recoverable — transient failures the caller may retry or fall back from (e.g. a network call that might timeout). Do not use `Result.t` for control flow, bugs, invariant violations, or "errors" the caller can do nothing useful about — raise instead.
- When using `Result.t`, use the monadic bind operator (`let*`) to sequence operations. Do not manually match on `Ok`/`Error` to propagate — let the bind operator handle short-circuiting.
- Prefer `ok_or_failwith` and `find_exn` over match-and-propagate when failure means a bug.

### Concurrency and shared mutable state

- The application runs in a single Eio domain. Fibers are cooperatively scheduled and only switch at scheduling points (I/O, `Fiber.yield`, awaits).
- Mutations of shared mutable state (refs, arrays, atomics) must complete in a flow with no scheduling points. Compute the new value first, assign in a single non-yielding step, then perform any I/O on the local snapshot.
- Pattern: when removing or replacing an element that requires a slow cleanup (network teardown, file close), partition the structure, update the reference, *then* run the cleanup on the displaced element. Never do `ref := …` after I/O on values read from the same ref.

### Logging

- Use the `Logs` library with per-module sources (`Logs.Src.t`).
- Each module registers its own log source for independent filtering at runtime.

### Testing

- Use inline tests (`ppx_inline_test` + `ppx_expect`) for unit testing.
- Only test logic the type system cannot detect. Do not test trivial mappings (e.g. ADT-to-string functions).
- Keep tests minimal — functions should be clean and isolated in logic to be easily testable.
- Never use mocks. Structure code so that dependencies can be passed as arguments.

### Running

- To restart the server, always use `make run`.
- `make run` starts the server in the background with stdout/stderr redirected to `freetube.log`.
- `make run` handles everything: it stops any previous instance and starts the new one. Do not stop the previous server manually.
- `make run` returns instantly with the server already up. Do not add `sleep` or readiness polling after invoking it.

### Project documentation

- `ARCHITECTURE.md` (top-level) describes the layered design, session model, producer/consumer split, discovery, HTTP layer, and concurrency model.
- `API.md` (top-level) documents every HTTP endpoint with request/response shapes.
- `docs/protocols/` holds protocol-level notes (AirPlay, DLNA, HLS).
- Runtime config lives under `$XDG_CONFIG_HOME/freetube/`: `config.json` (global) + `devices/<slug>.json` (per-device, slug from friendly name). All optional fields; bad files are logged and deleted. Per-device entries merge into the matching discovery entry at scan time; `is_static: true` entries are seeded into the cache. Brand overrides ride on `Sink.t` and are applied at HTTP-response time via `Bmff.maybe_set_major_brand`.
- **Before designing or changing anything in those areas, read the relevant doc first.** When a change alters the architecture, session/sink model, HTTP surface, or a documented protocol behaviour, update the corresponding doc in the same commit. Docs are part of the change, not follow-up work.

### Naming & Documentation

- Follow standard OCaml conventions: `snake_case` for values, functions, and module names.
- Only use `.mli` files when useful to hide implementation details.
- Document functions as briefly as possible (one line max) and only when the name and signature are not self-explanatory.
- Code should be as self-documenting as possible.

### Git Commits

- Commit messages should be very brief and focus on observable impact, not implementation details.
- The body of the commit should start with the paraphrased prompt for the commit.

### Workflow

- Before modifying any file, always re-read it first to check if the user has made changes since your last edit. Retain all user changes — never overwrite them.
- When adding new library dependencies, update both the dune `(libraries ...)` stanza and the `dune-project` `(depends ...)` list, then regenerate the opam file with `dune build freetube.opam`.
