# Durations: compound values, days, and a way back to text

`parse_duration` only accepts one unit, so `1h30m` is refused, and there is no
day unit. Please:

- accept compound durations such as `1h30m` or `2d4h` (units in any order, no
  separators);
- accept `d` for days (86400 seconds);
- add `format_duration(seconds)` that writes a number of seconds as the
  shortest compound duration (`5400` becomes `1h30m`, `0` becomes `0s`), and
  export it from the package, so that `parse_duration(format_duration(n)) == n`.

Anything that is not a duration must still raise `ValueError`.
