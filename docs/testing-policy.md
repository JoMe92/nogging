# Testing policy

A short, framework-neutral rule set for what to test, how, and how much. It
applies to every repository Nogging is installed in and to the agents that
write its tests. The aim is a suite that stays fast enough to run while you
work, because a suite nobody runs protects nothing.

## Always test

- **Spec scenarios.** Every scenario of a requirement you implement gets a test
  that would fail without your change.
- **One red-first regression test per bug fix.** Write the test, watch it fail
  for the reason in the report, then fix the code.
- **Error paths.** A refusal, a bad input or an unreachable dependency is
  behaviour. Show what the caller sees.
- **Contracts at module and API boundaries.** What a module accepts, returns
  and refuses is worth pinning. How it does it is not.

## Do not test

- **Framework or library behaviour.** The language, the web framework or the
  database driver has its own tests.
- **Trivia.** A getter, a constant, a pass-through call.
- **Source text.** Do not assert that a file contains a string or that a
  function is named a certain way. Run the behaviour instead. The exception is
  a document or prompt whose wording is itself the contract.
- **The same behaviour at several levels.** Test it once, at the lowest level
  that can show it.
- **Impossible cases.** Do not test a state the types, the schema or the caller
  already rule out.

## Pick the level per change

- **Small.** In-process, no subprocess, under one second each. Pure functions,
  parsers and decisions with facts passed in. This is the default.
- **Medium.** Local processes and temporary repositories or databases, seconds
  each. Use it where the behaviour is the interaction: a command line, a file
  layout, a query.
- **Large.** A packed install or a real multi-process flow. Use it only where a
  scenario cannot be shown smaller, and keep it few.

A change that touches pure logic gets small tests. Move up a level only for the
part that needs it.

## Mocks only at real process boundaries

Replace the network, the clock, the operating system and other programs you
start. Do not replace your own modules to make a test pass: a test that mocks
the code under test proves the mock. If a unit is hard to test without mocking
its neighbours, the seam is in the wrong place.

## Expensive setup once per run

Build an expensive fixture once and share it, instead of once per test. The
usual case is a database: create it and apply the schema once, keep that as a
template, and give each test a cheap copy.

```text
# once per run
create template database; apply the schema; load the static reference data
# per test
copy the template database (milliseconds); run the test; drop the copy
```

The same applies to a built package, a cloned repository or a started server.
Input validation does not need a database or an API server at all: call the
validator.

## No real sleeps

A test never waits for a wall-clock delay. Inject the clock and advance it, or
wait on the event itself with a bounded timeout. A fixed sleep is either too
short, and the test is flaky, or too long, and the suite is slow.

## Keep the suite honest

- Do not delete, skip or weaken a test to make a run pass. If a test is wrong
  or the behaviour is gone, say so in the commit and in a discovery note.
- Do not keep `_v2` or copied test files beside the originals.
- Prefer a few meaningful assertions over many that restate the code.

Nogging runs tests in stages: the files you changed while you work, those plus
lint before a commit, and the affected tests once per task. The full suite is
for CI, releases and the nightly run, not for each task.
