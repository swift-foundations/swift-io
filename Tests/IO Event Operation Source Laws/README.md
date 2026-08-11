# IO event operation source laws

These fixtures record compile-time ownership and lifetime laws for
`Event.Actor.run`. They are documentation inputs, not an executable test target.

- `positive-move-only.swift.fixture` records a move-only sending result.
- `negative-escape-descriptor.swift.fixture` records that the descriptor borrow
  cannot escape through the operation result.
- `negative-repeat-operation.swift.fixture` records one-shot operation ownership.
- `negative-blocking-strategy.swift.fixture` records the absence of a
  cancellable blocking-strategy overload.

Runtime coverage belongs with the event actor fake: cancellation must wake the
source, remove the exact sender and registration, deregister before return, and
permit descriptor close only after the physically joined attempt completes.
