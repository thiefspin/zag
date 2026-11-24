# Contributing to Zag

Thanks for helping. This page covers setup, the code rules, how CI checks a
change, and how releases happen.

## Setup

You need:

- **Zig 0.17.1** exactly (`zig version`). Other versions may not build.
- **Docker** (or [Colima](https://github.com/abiosoft/colima) on macOS) for
  zag-pg's integration tests. Without it those tests skip, and everything else
  still runs.

```sh
make pg-up     # Postgres 17 on :54329 (users: zag, md5user, plainuser)
make check     # what CI runs: format check, tests in Debug and ReleaseSafe
```

Run `make` with no target to see every command.

## Making a change

1. Open an issue first for anything bigger than a bug fix, so we can agree on
   the API before you write it.
2. Write tests with the change:
   - **Unit tests** go at the bottom of the file they test.
   - **End-to-end tests** live in `src/tests.zig`, for both the server and the
     database client.
   - All tests use `std.testing.allocator`, so leaks fail them.
3. Update the docs: the library's `README.md` for anything users see, and its
   `technical_spec.md` if the design changes.
4. Add a line under **Unreleased** in `CHANGELOG.md` for user-visible changes.
5. Run `make check` before opening a pull request. Run it with `make pg-up`
   if you touched zag-pg.

## Code rules

These apply to every library, and reviewers check them. The full reasoning is
in [`zag-http/technical_spec.md`](zag-http/technical_spec.md) §8–§10.

**Low cognitive complexity**

| Rule                           | Limit |
|--------------------------------|-------|
| Lines per function             | 40    |
| Nesting depth                  | 3     |
| Parameters per function        | 4 (group the rest in an options struct) |
| Lines per file                 | 400   |

Prefer early returns over `else` chains, and small named helpers over comments
explaining a block. Keep comptime reflection in the one file that needs it
(`handler.zig`, `fields.zig`, `rows.zig`).

**Zig practice**

- Pass allocators and `std.Io` explicitly. No globals and no hidden threads.
- Pair every allocation with `defer`/`errdefer`, or put it in an arena with a
  clear owner. Each library's README has a "Memory" section describing who
  owns what.
- Use specific error sets in public APIs, not `anyerror`, except where the
  user supplies the code (middleware).
- Give clear compile errors for misuse (`@compileError` naming the bad field
  or parameter).
- Never put user-supplied text in SQL or log anything secret. Never send
  internal error details to HTTP clients.
- Run `zig fmt` on everything (`make fmt`).

## Continuous integration

Every push to `main` and every pull request runs
[`ci.yml`](.github/workflows/ci.yml):

| Job       | Checks |
|-----------|--------|
| Format    | `zig fmt --check` |
| Test      | All tests on Linux and macOS, Debug and ReleaseSafe. On Linux, Postgres runs in Docker and the database tests **must** run (`ZAG_PG_REQUIRE=1`); on macOS they skip. |
| Examples  | Every example builds. `client_tour` runs, and the Postgres `todos` service gets a curl smoke test. |
| Package   | All `build.zig.zon` versions agree, and a fresh project can `zig fetch` the repo and import every module. This catches files missing from `.paths`. |
| API docs  | `zig build docs` succeeds |

[`docs.yml`](.github/workflows/docs.yml) publishes the API reference to GitHub
Pages on every push to `main`. Dependabot keeps the workflow actions up to
date.

## Releasing

All libraries share one version, which is set in the root `build.zig.zon` and
in every `zag-*/build.zig.zon`.

1. Bump `.version` in all of them (CI fails if they differ).
2. In `CHANGELOG.md`, move the **Unreleased** notes under
   `## [X.Y.Z] - YYYY-MM-DD` and update the comparison links at the bottom.
3. Commit, push, and wait for CI to pass.
4. Tag and push: `git tag vX.Y.Z && git push origin vX.Y.Z`.

[`release.yml`](.github/workflows/release.yml) then runs:

- It checks the tag against the versions and the changelog.
- It runs the full test suite with Postgres and repeats the package check.
- It publishes a GitHub release with the changelog section, a source
  tarball, and the `zig fetch` command with the package hash.

A tag with a suffix, such as `v0.2.0-rc.1`, becomes a pre-release.

## Adding a library

1. Create `zag-<name>/` with its own `build.zig` and `build.zig.zon`
   (`.name = .zag_<name>`, same version as the others). Run `zig build` once to
   get a fingerprint.
2. Expose its module as `zag-<name>` from its `build.zig`, and add a `test`
   step.
3. Root `build.zig.zon`: add `.zag_<name> = .{ .path = "zag-<name>" }` to
   `dependencies` and `"zag-<name>"` to `paths`.
4. Root `build.zig`: add it to `libraries`, which covers tests and docs.
5. `Makefile`: add it to `LIBS`.
6. Give it a `README.md` (add it to the package's `.paths`), a
   `technical_spec.md`, and a row in the root README's table.
7. Add the module to the consumer in `.github/scripts/package-check.sh`.

Libraries may depend on each other by path, as zag-pg's example does on
zag-http. Keep library code itself free of cross-library dependencies where
you can. zag-http recognises zag-pg's error names without importing it.
