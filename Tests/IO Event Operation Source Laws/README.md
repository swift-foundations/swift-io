# IO event operation source laws

These fixtures record compile-time ownership and lifetime laws for the Event
strategy's `enlist` primitive and the generic IO Primitives owners it returns.
They are documentation inputs, not an executable test target.

- `positive-move-only.swift.fixture` records a move-only sending result and the
  separate result-free physical-completion acknowledgement.
- `negative-escape-descriptor.swift.fixture` records that an operation cannot
  return a view borrowing its owned execution descriptor.
- `negative-repeat-operation.swift.fixture` records one-result ownership.
- `negative-blocking-strategy.swift.fixture` records the absence of a
  cancellable blocking-strategy overload.
- `positive-independent-cancellation.swift.fixture` records that cancellation
  is reachable without consuming the result owner.
- `positive-close-ordering.swift.fixture` records that release consumes the
  result-free Completion before consuming the original descriptor.

Runtime coverage belongs with the event actor fake: independent cancellation
must wake the source, remove the exact sender and registration, deregister, and
signal Completion only after cancellation-before-admission or physical worker
join. Descriptor close is lawful only after consuming Completion.
