# Layered configuration and a `show` command

We need one place that decides the effective configuration. Add a
`miniutil.config` module and a command line on top of it:

- `merge(*layers)` merges mappings deeply, later layers win, non-mapping values
  are replaced as a whole, and the inputs are not changed;
- `from_environ(environ)` reads `MINIUTIL_DB__HOST=x` as `{"db": {"host": "x"}}`
  and ignores other variables;
- `from_assignments(["db.host=x"])` reads `key.path=value` strings the same way
  and raises `ValueError` for anything without an `=`;
- `load(defaults, environ, overrides)` layers defaults, then the environment,
  then the explicit overrides;
- `python -m miniutil show [--set key.path=value]...` prints the effective
  configuration as one line of JSON with sorted keys, so an explicit `--set`
  beats an environment variable, which beats the defaults.

Export `load` from the package and describe the command in the README.
