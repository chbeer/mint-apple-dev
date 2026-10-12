# Contributing

This fork supports Linux Mint 22.x on x86_64.

## Reporting a problem

Include:

- Linux Mint version and architecture;
- `swift --version` and `xtool --version`;
- the full command output, not only the last error;
- whether setup used `full`, `no-xcode`, or `--user-only` mode;
- iPhone and iOS version for device-related failures.

## Sending a change

- Keep installer work idempotent: rerunning a successful stage must be safe.
- Pin source downloads or verify signed release archives.
- Explain every new network fetch.
- Keep `--user-only` free of `sudo` and system package changes.
- Run `bash -n` on changed shell scripts.
- Run `python3 -m py_compile` on changed Python tools.
- Run `tests/run.sh` and describe any test that cannot run on the current host.
