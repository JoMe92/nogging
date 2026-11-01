"""Effects of `nogg dashboard`: the Git and token loaders.

Filled by the usage-data task of the dashboard change. `scripts/nogg` already calls
`read_git(home)` and `read_tokens(collect_store, usage_report_module)`, where both
arguments of the second are callables, each returning the reader snapshot of the data
contract.
"""
