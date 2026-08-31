# Walkthrough: import photos from the local filesystem

This example shows the intended flow, not an implementation mandate.

1. The Product Owner begins a planning session and asks for a UI import action:
   select images from the PC filesystem and show successful imports in the
   image strip.
2. The Planning Agent creates `photo-import-filesystem` with requirements and
   four executable tasks. The planner adds explicit Beads dependencies so the
   strip refresh and end-to-end tests wait for the import work. Product choices—such as copy versus
   reference, allowed formats and multi-selection—are made here or marked
   explicitly as open decisions. It validates and materializes one Bead per
   task.
3. The Main Worker claims a ready Bead. A specialist implements the picker or
   import service, tests it, and returns the result. The Main Worker commits
   `feat(import): add filesystem import [SPEC-...]`, adds the SHA and test
   command to the Bead note, then closes it.
4. Within 30 seconds, the timer checks that closed Bead, ticks its OpenSpec
   task and appends an idempotent line to `execution-log.md`. It does not change
   requirements.
5. Suppose the agent discovers that multi-select was unspecified. It records a
   non-blocking `review` discovery in the Bead and implements the approved
   single-file scope. The next planning session asks the Product Owner whether
   multi-select belongs in a new task. Only then is another Bead created.
6. After all mapped Beads are closed, the change becomes eligible for `done`.
   The Product Owner accepts it and explicitly archives it after checking the
   actual behavior.
