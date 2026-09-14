**Protected collection transactions (helper 0.8.1, protocol 1)**

Negotiate `protected_collection_apply_v1` and `collection_preconditions_v2`
before using this contract. Legacy requests and the old
`collection_preconditions` digest map retain their existing behavior.

A snapshot now includes `collection_preconditions_v2`, with `version:2` and a
`sources` map for `wm`, `rules` and `layout`. Each source describes its selected
`path`, `exists` flag and opaque SHA-256 `digest`. The digest binds a versioned
domain, selected path, existence and exact source bytes. Clients copy these
descriptors; they do not generate or edit TOML.

Validate a collection request with the following shape. Substitute actual
generation, IDs and descriptors from the snapshot:

```json
{
  "protocol": 1,
  "collection_apply_version": 1,
  "protected_apply": true,
  "expected_generation": "0123456789abcdef",
  "collection_preconditions_v2": {
    "version": 2,
    "sources": {
      "rules": {
        "path": "/home/example/.config/aqueous/rules.toml",
        "exists": true,
        "digest": "0000000000000000000000000000000000000000000000000000000000000000"
      }
    }
  },
  "window_rule_changes": [
    {"id": "rule:1", "values": {"floating": false, "opacity": 0.8}}
  ]
}
```

Supply exactly the touched sources: `rules` for window rules, `wm` for custom
bindings, and `layout` for named layouts or legacy snap zones. Multiple
collection operations can share a source descriptor. Empty arrays still require
their source descriptor. `default_snap_layout` accompanies `snap_layouts` and
requires the layout precondition; standalone use is rejected. Multi-file saves
still require `backup_dir`. `create_user_override` retains its existing meaning.

The helper checks all supplied descriptors under its writer lock, even when
`expected_generation` matches. This distinguishes missing files from empty files
and detects changed source selection. A stale global generation is accepted only
if every touched source is unchanged. A touched-source edit, reorder or path
change returns `external_change`; take a new snapshot and resolve IDs again.

Validation returns the existing canonical `raw_files`, `candidate_review` and
`candidate_impact`, plus `collection_transaction`:

| Field | Meaning |
| --- | --- |
| `version` | `1` |
| `requested_generation` | The generation supplied by the caller |
| `effective_generation` | The fresh baseline used for candidate validation |
| `rebased` | Whether the requested generation differed from that baseline |
| `candidate_digest` | The existing full canonical candidate SHA-256 |
| `base_preconditions` | Verified input source descriptors to use for apply |

The top-level `generation` in a validation snapshot describes the candidate,
not its on-disk baseline. After reviewing `raw_files` and complete impact, apply
the same mutations with `expected_generation` set to `effective_generation`,
`collection_preconditions_v2` set to `base_preconditions`, and `candidate_digest`
set to the returned digest. Do not use the candidate snapshot's source
descriptors as baseline preconditions. The helper alone performs the edit.

Protected apply always recalculates candidate semantics and compares the full
digest, including when no preview token or file change is present. Missing,
malformed or mismatched digests return `candidate_mismatch` before configuration
writes, backup writes, toolkit synchronization or reload. Validation permits an
omitted digest, and does not compare an optional well-formed supplied digest:
its purpose is to return the fresh candidate for review.

Unrelated source changes may permit ID reuse while changing the full candidate
digest. In that case apply rejects the previously reviewed digest. Validate and
review again; do not substitute a new digest without reviewing the candidate.
Both validate and apply recheck selected paths, existence and exact source bytes
before returning/persisting a candidate. Writers using the helper are serialized;
external editors that ignore its lock remain subject to these conflict checks.

This contract accepts only collection mutations and its documented transaction
metadata. Unknown keys, raw edits, scalar/display mutations, preview tokens,
toolkit sync requests, legacy preconditions and unsupported contract versions
return `invalid_collection_contract`. Invalid/missing/extra source descriptors
return `invalid_collection_preconditions`; malformed generations return
`invalid_generation`. Unclassified candidates still return
`unclassified_candidate` on apply. There is no filename-based or caller-supplied
classification override.

Mixed display/collection requests use the existing fresh-generation native
preview/commit contract, including its digest, revision, session and lease
checks. They cannot use the collection-only stale-generation exception.

Use `apply --result v1 --operation-id ID` for recoverable results. The existing
journal and receipts preserve the effective generations, candidate digest and
save decision; use `operation-status` after a lost reply. A receipt with unknown
reload completion does not authorize repeating the reload. Reusing an operation
ID with a different request remains an error. Rejected recorded operations may
leave diagnostic receipt metadata, but do not modify configuration or reload.

Schemas: [request/response definitions](aqueous-config-additions-v1.schema.json),
`$defs/protected_collection_request` for validate and
`$defs/protected_collection_apply_request` for apply. The existing collection
schema defines each collection's operations and values.

Regression command (both binaries built from this revision):

```sh
python3 tests/backend/test-protected-collections.py \
  zig-out/bin/aqueous-config zig-out/bin/aqueous-backend-test
```
