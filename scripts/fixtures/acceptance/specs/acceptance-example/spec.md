## ADDED Requirements

### Requirement: The echo-note helper appends a line and echoes it

The `echo-note` helper SHALL take a single line of text, append it verbatim as a
new line to an append-only notes file, and write the same line back to standard
output. It SHALL NOT modify or reorder any existing line in the notes file.

#### Scenario: A line is appended and echoed back

- **WHEN** `echo-note` is called with the text `hello`
- **THEN** `hello` is appended as the last line of the notes file
- **AND** `hello` is written to standard output
- **AND** every previously present line in the notes file is unchanged
