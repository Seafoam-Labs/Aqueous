# Input activity latency comparison

The synthetic native Wayland test measured approximately **0.9–1.3 microseconds
of additional p95 synchronous handler time** with activity publishing enabled.
It did **not resolve an increase in application delivery latency**: paired p95
delivery differences had confidence intervals spanning zero. This is a bounded
headless measurement, not evidence of zero overhead or hardware qualification.

## Reproduce

Build the pinned wlroots dependency as usual, then from `compositor/`:

```sh
zig build -Doptimize=ReleaseSafe -Dvulkan-effects=false -Dinput-activity-testing=true
python3 scripts/test-input-activity-latency.py
```

Use `--compositor /path/to/aqueous` for a separate diagnostic installation.
Defaults are 12 rounds, 100 measured presses per category/mode/round and 2 ms
minimum spacing. Twenty additional presses per category warm up each block.
`--seed` makes the randomized mode order reproducible. An optional
`--max-p95-increase-us N` fails if the upper 95% confidence bound on a mode's
paired p95 application-delivery increase exceeds N. Functional failures (lost
input, unavailable authorized activity, or unexpected activity while bypassed)
always fail. Without a budget, successful completion means the experiment ran,
not that performance passed a particular latency limit.

The test prints its private artifact directory, which contains `results.json`,
per-sample durations, application/observer logs and the compositor log.

## Method

One private pixman/headless compositor, one normal native Wayland application
and a separate authorized activity client remain alive across all blocks. The
fixture registers synthetic physical keyboard and pointer devices through the
actual compositor ingress callbacks. It focuses the application, positions the
pointer in its surface and verifies both press and release delivery. Device
creation, startup, bootstrap, focus changes and warmup are excluded from samples.

Each round shuffles these three blocks:

- **Bypass:** skip activity press tracking and observation; disarm the activity
  manager's timer. Existing input processing and application dispatch still run.
- **Idle:** activity tracking and timer enabled, authorized manager connected,
  no activity subscription.
- **Active:** the same observer plus a ready subscriber that acknowledges
  notifications. The test checks that activity is actually delivered each block.

Both keyboard and mouse presses are interleaved in every block. Only one press
is outstanding; its matching release is received before the next sample. This
prevents ambiguous matching, repeat events and held-state changes across blocks.

The diagnostic ingress timestamp is taken immediately before invoking the
synthetic device command; a second timestamp follows its synchronous return.
Their difference includes fixed diagnostic parsing overhead plus wlroots/input
handler work. The application records a timestamp when its normal `wl_keyboard`
or `wl_pointer` callback executes. Subtracting the ingress timestamp measures
application delivery, including compositor queueing, socket delivery and client
scheduling. All timestamps use `CLOCK_MONOTONIC`; Python polling/file I/O is
outside the measured endpoint timestamps. The same diagnostic instrumentation
is present in all modes.

The bypass switch and compositor timestamp reply exist only behind
`input-activity-testing` and a private inherited control FD. Production folds out
the bypass branch. No request, input value or timestamp is added to the activity
Wayland protocol. Timestamped fixture logs concern synthetic test input only.

The report gives pooled median/p95/p99/max and block statistics. Each comparison
subtracts the bypass statistic from the corresponding mode in the same round,
then bootstraps those round differences 5,000 times to estimate a 95% interval
for the mean paired difference. This preserves block-level scheduling variation
instead of treating thousands of neighboring samples as independent experiments.
The intervals are exploratory estimates, not hard worst-case bounds.

## Recorded run: 2026-09-18

ReleaseSafe diagnostic build with LLVM, baseline CPU target, Xwayland compiled
but disabled for this native test. There were 1,200 measured samples per
category/mode (7,200 total), 12 randomized rounds and a 2 ms press period.
No other build or benchmark was deliberately run concurrently; host scheduling
and CPU frequency were not pinned. The [machine-readable record](input-activity-latency-results.json)
contains the platform, binary hash, summaries and confidence intervals.

Application delivery, microseconds:

| Input | Observer | Median | p95 | p99 |
| --- | --- | ---: | ---: | ---: |
| Keyboard | Bypass | 13.69 | 24.09 | 39.03 |
| Keyboard | Idle | 13.22 | 23.96 | 32.14 |
| Keyboard | Active | 14.50 | 25.59 | 36.10 |
| Mouse button | Bypass | 44.54 | 75.19 | 98.12 |
| Mouse button | Idle | 40.34 | 71.57 | 86.97 |
| Mouse button | Active | 48.50 | 76.24 | 92.06 |

Paired active-minus-bypass p95 differences, microseconds:

| Input | Synchronous handler | 95% interval | Application delivery | 95% interval |
| --- | ---: | --- | ---: | --- |
| Keyboard | +0.88 | [+0.13, +1.70] | +1.20 | [−0.43, +2.75] |
| Mouse button | +1.31 | [+0.37, +2.23] | +0.54 | [−3.74, +4.70] |

Paired differences need not equal subtraction of the pooled percentiles above.
Idle-minus-bypass application-delivery intervals also spanned zero. The short
smoke run was used to validate the harness; this table uses the full run only.
Full temporary artifacts: `/tmp/aq-latency-33ozg87d`.

## Limits

This compares the observer's incremental runtime work inside the same binary;
it is not a historical before/after binary comparison. The bypass still retains
protocol globals, allocations and diagnostic instrumentation. Idle represents a
connected authorized owner without a subscriber, not every possible startup
state. The test does not measure physical libinput/device latency, DRM/VT input,
Xwayland callback latency, GPU presentation, motion/scroll, saturated queues,
bootstrap work under load or Pearl animation latency. The 100 ms activity
notification coalescing delay is a separate feature and is not this measurement.
