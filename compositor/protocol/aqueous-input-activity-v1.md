# Aqueous input activity v1

This extension reports **keyboard activity, mouse activity, or both**, without
input values. It runs on the consumer's existing Wayland display connection.
`outputd.sock` and general shell snapshots do not carry activity.

The activity event contains a generation (two uint32 words), a notification
sequence, and category bits: keyboard `1`, mouse `2`, both `3`. Different keys
produce indistinguishable keyboard notifications; different pointer buttons
produce indistinguishable mouse notifications. Multiple presses in a category
coalesce to one bit. No keys, button identities, text, modifier state, coordinates,
deltas, scroll values, input timestamps, device IDs, app identities, press counts
or intensity are transmitted. Sequence numbers count delivered notifications,
not input events. No activity data is logged or persisted.

## Eligibility and limits

V1 observes fresh physical keyboard and pointer-button presses on the default
seat at ingress, before application/WM dispatch. Compositor shortcuts count.
Virtual devices, repeats, releases, motion, scroll, touch and tablets do not count.
Local per-device press-state tracking is never exported. Other seats are excluded.

The minimum notification interval is 100 ms across subscription churn. At most
one notification is unacknowledged and one category mask is pending. Pending
activity older than 100 ms is dropped; an event-loop stall never causes catch-up
notifications. Missing an acknowledgment for 1000 ms invalidates readiness and
pending activity. Empty intervals emit nothing. Silence does not establish
session idleness or availability.

A compositor admits at most 16 manager resources, 16 subscription resources and
32 inhibitor resources. Authorized manager/subscription traffic is limited to
64 requests per second per manager and per subscription, including inert
subscriptions. Exceeding resource/flood limits is abuse
and may disconnect that client. Ordinary authorization denial, revocation and
acknowledgment timeout leave the shared Wayland display and GTK surfaces intact.

## Authorization bootstrap

The compositor creates `activity.sock` alongside its exclusive per-instance
`AQUEOUS_SOCKET` (`ipc.sock`). This endpoint delivers authorization only; it is
not an activity stream. Socket path knowledge and same UID do not grant access.

The packaged `aqueous-pearl.service` (or the matching Git instance service)
executes `aqueous-activity-launch /absolute/path/to/pearl`. The wrapper obtains
one capability before exec, so its PID remains the service MainPID and then
becomes Pearl's PID. If bootstrap fails, Pearl starts normally without activity.
The existing `KillMode=process` policy is preserved, so the locker is not killed
by a shell restart.

Before issuing a capability, Aqueous verifies all of:

- Kernel-reported Unix peer credentials match the compositor's UID.
- A peer PIDFD pins the connecting process's lifetime; it must still be alive.
- The process environment names this exact compositor's `AQUEOUS_SOCKET`.
- Its executable inode is the installed `aqueous-activity-launch` next to the
  compositor binary, including inside the private Git prefix.
- `sd_pidfd_get_user_unit` identifies the expected instance's Pearl service,
  and the user service manager reports that exact process as its MainPID.

Systemd queries run in one bounded worker, outside the compositor event thread.
The service manager and its user-controlled unit configuration are trusted
session infrastructure. This does not protect against an attacker who can
replace the trusted unit/program, inspect/control Pearl, or act as root.
Merely naming a unit or placing a helper in its cgroup is insufficient.
See [systemd process identity APIs](https://www.freedesktop.org/software/systemd/man/253/sd_pid_get_owner_uid.html).

The capability is a sealed, empty memfd transferred using SCM_RIGHTS. The
compositor retains its file identity, intended PID/PIDFD and a 10-second expiry.
It contains no input data or reusable text token. `authorize(fd)` validates the
same file object and intended live process, consumes the capability once and
binds authority only to the requesting Wayland client and manager resource.
Forged, expired, replayed, wrong-process or wrong-instance proof is denied.
A second Wayland connection cannot inherit the first connection's authority.
Security-context clients cannot authorize even with a supplied capability.
The received protocol FD is closed on every path.

The wrapper exports `AQUEOUS_INPUT_ACTIVITY_FD` only to the exec'd Pearl process.
Pearl must immediately set close-on-exec on that descriptor, remove the variable
from its environment, submit it through the existing GTK connection and close
its copy after submission. Never pass it to plugin helpers, applications or the
locker. The descriptor number by itself is not authorization.

Linux SO_PEERPIDFD and libsystemd with PIDFD identity APIs are required for this
bootstrap. Non-systemd/manual Pearl launches, unrelated `pearl.service` units,
and processes that fail these checks are denied. Core installs no Pearl service
and depends on no Pearl package. A new shell process receives a fresh capability.
Destroying the authorized manager revokes authority; reauthorization requires a
fresh service launch. Subscription recreation under a live manager needs no new
capability.

## Consumer sequence on the shared GTK display

1. Obtain GTK's existing `wl_display` through GDK and discover/bind
   `aqueous_input_activity_manager_v1` version 1. Binding only exposes static
   capabilities, never activity. The capability bitmask is `3`, interval `100`.
2. Submit `authorize(fd)` and await `authorization(available)`. Denial returns
   `permission_denied` without a fatal protocol error.
3. Create one subscription. It reports initial `suspended` state with a generation,
   or `unsupported` if no trustworthy native session activity source exists.
   Unauthorized/additional subscriptions become inert and report permission_denied.
4. Send `set_ready(serial, generation_hi, generation_lo, 1)` for the received
   generation. An available state acknowledges the serial only if all source
   gates are open. Stale generations and invalid ready values do not enable input.
5. Receive `activity(generation_hi, generation_lo, sequence, categories)` and
   acknowledge that exact generation and sequence. Recheck local session/grants
   and generation before dispatch to plugins. Unknown/stale acknowledgments do
   not acknowledge current data.
6. Before authentication/lock preparation, stop local dispatch and clear pending
   plugin events, create an inhibitor and wait for its serial in a suspended
   state. Only then accept authentication input on the normal path.
7. Destroy each inhibitor when its own flow ends. Inhibitors compose: releasing
   one cannot release another. Source gate transitions change generation and
   require fresh readiness. No pre-suspension activity is replayed.
8. Destroy a subscription to unsubscribe. Destroyed managers/subscriptions leave
   child protocol objects inert until the client destroys them. Revocation and
   owner death clear pending input and retire authority.

All requests/events use the same connection as GTK. Use GTK/GDK's event-loop and
flush integration; do not start a competing socket reader or block GTK with
roundtrips. Different client event queues may invoke callbacks in different
orders, so local suspension and generation checks are mandatory. A server cannot
recall bytes already sent. Destroying activity resources must not disconnect GTK.

Availability is separate from a plugin grant. Pearl should return permission
denied to an ungranted plugin, unsupported when the extension/source is missing,
suspended during lifecycle inhibition, and available only when both local and
compositor gates allow delivery. Initial suspended state requires a readiness
request; it does not imply a permanent error.

## Suspension and authentication scope

Collection requires a live authorized owner, a ready subscription, an active
wlroots session, an unlocked compositor and no subscription inhibitors. Accepted
session-lock requests suspend from lock preparation onward, before lock surfaces
finish rendering. Backend session activity changes invalidate readiness. Every
input observation and emission rechecks the gate and owner lifetime.

Headless/nested backends without a wlroots session are unsupported in production;
no null-session-active fallback is used. The isolated diagnostic build provides
an explicit synthetic session source for tests only.

Authentication inhibition covers Pearl-managed polkit and lock preparation when
Pearl wires those flows to inhibitors. Arbitrary web/application password fields
cannot reliably be inferred by a compositor and are not automatically detected.
If inhibition acknowledgment fails, Pearl must disable local plugin dispatch,
clear queues and flush destruction of activity objects before proceeding with
authentication. It must not claim confirmed compositor suspension or close GTK's
display. Re-enablement requires a fresh successful lifecycle handshake.

## Pearl handoff and validation

The XML and this contract install under
`share/aqueous-protocols/stable/`. Discover the protocol root with
`pkg-config --variable=pkgdatadir aqueous-protocols`. Generate bindings with
`wayland-scanner client-header` and `wayland-scanner private-code`, or Pearl's
equivalent binding generator. The manager, subscription and inhibitor are all
version 1. XML SHA-256:
`a564fe42e852247fb7c7c2acb06702b0d35aad0444076beb30b09eded01f0cc4`.

Import this XML and pin its source revision and hash. Implement one shared broker
for granted/subscribed plugins and carry real availability/subscription intent
through the helper protocol. Coalesce busy helpers by category flags, not counts.
For the current guest API, `count = 1` can represent one notification, never a
physical press count; exposing categories requires a WIT compatibility decision.
The existing cat can consume the generic activity event.

Run `zig build test` and `scripts/test-input-activity.py` against a build made with
`-Dinput-activity-testing=true -Dvulkan-effects=false`. Diagnostic injection uses
an inherited private FD and real compositor input callbacks; it is absent from
production and does not add a public input-injection operation. The generated
build policy marks this option, and component packaging rejects test builds.
Add `--xwayland` to exercise normal input delivery with an X11 application focused.
`scripts/test-input-activity-systemd.py --compositor /path/to/aqueous` separately
tests the real bootstrap using a production pixman build configured with
`-Dinstance-name=aqueous-activity-fixture`, a private display and a temporary user
unit. It refuses to replace an existing unit of that name.

The validation record is in the repository's
`docs/input-activity-validation.md`. Hardware typing, VT switching and Pearl's
polkit/event-to-pose acceptance remain separate gates. A private simulated client
test does not certify those physical/consumer paths.
