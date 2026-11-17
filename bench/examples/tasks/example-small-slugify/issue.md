# slugify leaves runs of dashes

`slugify("Hello,   World!!")` returns `hello----world`. Punctuation and
repeated spaces each become their own dash. It should return `hello-world`:
any run of non-alphanumeric characters becomes a single dash, and no dash is
left at either end.
