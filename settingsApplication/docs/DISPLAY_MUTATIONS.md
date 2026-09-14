**Structured display declarations (helper 0.8.2, protocol 1)**

Negotiate `display_declaration_mutations_v1` before sending
`display_declaration_changes`. The helper remains the only TOML editor. This
capability permits candidate construction; native backend capabilities and a
protected preview lease still determine which display changes can be saved.
It does not enable physical previews, HDR, VRR or unsupported mirroring.

Snapshots expose `id`, `kind` and `parent_id` on each `display_declarations`
entry (also under `display_model.declarations`). IDs are opaque and bind the
snapshot generation, source, selected path, existence, exact source bytes and
table occurrence. Duplicate names/declarations have distinct IDs. A profile
member's `parent_id` identifies its exact profile occurrence. Offline and disabled
outputs have the same editing contract as connected outputs. Never derive an ID
from a connector name, array index, profile name or live output observation.
The snapshot also supplies `display_source_ids`. Copy exactly the touched
sources into the request's `sources` map. These opaque tokens bind creation to
the same source baseline even when no declaration exists yet; an absent file
and an empty file cannot reuse that authorization.

This example changes one declaration and removes its local scale override:

```json
{
  "protocol": 1,
  "expected_generation": "0123456789abcdef",
  "protected_apply": true,
  "display_declaration_changes": {
    "version": 1,
    "sources": {"outputs":"display-v1:0000000000000000000000000000000000000000000000000000000000000000"},
    "operations": [
      {
        "op": "update",
        "source": "outputs",
        "id": "display-v1:0000000000000000000000000000000000000000000000000000000000000000",
        "set": {"enabled": false, "primary": false, "auto_hdr_boost": 0},
        "unset": ["scale"]
      }
    ]
  }
}
```

Replace the generation, source token and declaration ID with actual snapshot values. `source` is always
required and is either `wm` or `outputs`. Editing `wm` edits that declaration in
place; it does not migrate it into `outputs`. System sources retain the existing
explicit `create_user_override:true` requirement. Multi-file saves require
`backup_dir`.

**Operations and batch ordering**

The helper resolves existing IDs against the original snapshot, retaining that
identity throughout the batch even as table indices change. Operations execute
in request order. Each existing node can be targeted by at most one operation;
combine field changes into one `update`. Moving a profile carries its members
without changing their identities, so individual member updates can accompany
a profile move. A later reference to a deleted node is an error.

| Operation | Required fields beyond `op` and `source` | Optional fields |
| --- | --- | --- |
| `add` output | `kind:"output"`, `parent`, `set` | `ref`, `before` |
| `add` profile | `kind:"profile"`, `set:{"name":"..."}` | `ref`, `before` |
| `add` policy | `kind:"policy"`, `set` | `ref` |
| `update` | `id`, at least one of `set` or `unset` | The other patch field |
| `move` output/member | `id`, `parent` | `before` |
| `move` profile | `id` | `before` |
| `delete` output/member/policy | `id` | None |
| `delete` profile and its members | `id`, `members:"delete"` | None |
| `delete` profile and reassign its members | `id`, `members:"move"`, `parent` | None |

`parent:null` selects top-level `[[output]]`; a profile ID selects
`[[display.profile.output]]`. Membership moves remain within one source. `before`
selects a sibling in the destination group; omit it to append. A profile move
always moves the complete profile/member block. Policy order is not editable.
Profile deletion requires an explicit member disposition even for an empty
profile. Deleting/reassigning members conflicts with other operations targeting
those same members in the batch. There is no implicit orphaning.

An add may declare `ref:"desk"`. Subsequent operations can use `"new:desk"` as
an ID, parent or sibling reference. References contain 1–64 ASCII letters,
digits, underscores or hyphens and must be unique across the batch. Forward
references and cross-source references are rejected. A newly added node may
receive one subsequent explicit operation. The limit is 256 operations.

For example, these operations create a profile and its first member:

```json
[
  {"op":"add","source":"outputs","kind":"profile","ref":"desk","set":{"name":"desk"}},
  {"op":"add","source":"outputs","kind":"output","parent":"new:desk","set":{"edid":"monitor-edid","enabled":false}}
]
```

Rename a profile with `update` and `set.name`. If policy refers to its old name,
update/unset `fallback_profile` in the same batch unless that name still resolves
to another profile. Profile ordering and duplicate names preserve the native
parser's first-match and cross-source precedence rules; IDs do not conflate them.
The helper validates that nonempty fallback references resolve in the final
candidate. It never silently renames a reference or activates a different profile.

**Fields and inheritance**

Outputs and members accept the canonical parser's fields:

| Fields | Structured value |
| --- | --- |
| `name`, `edid` | Native identity matcher strings; at least one must remain nonempty |
| `enabled`, `primary`, `adaptive_sync`, `hdr`, `auto_hdr` | Boolean |
| `mode` | Native mode string, e.g. `1920x1080@59.94` |
| `scale` | Number 0.5–3, normalized by the compositor to increments of 1/120 |
| `position` | Two signed 32-bit integers |
| `transform` | `normal`, `90`, `180`, `270`, `flipped`, `flipped-90`, `flipped-180`, `flipped-270` |
| `mirror_of` | Exact source name, or `""` to restore extended mode; no wildcard |
| `hdr_level` | String `auto`, `100`, `400` or `1000` |
| `sdr_white_level` | Number 80–1000 cd/m² |
| `auto_hdr_boost` | Number 0–1 |

Policy accepts `apply_on_start`, `apply_on_reload`, `fallback_profile`,
`identify_by` and `rollback_seconds` (integer 0–65535). The last two retain their
existing compatibility-only runtime behavior; `rollback_seconds` does not replace
the native lease timeout. Profiles accept only `name`.

Omitted fields are unchanged. False, zero and permitted empty strings are explicit
values. `unset:["key"]` removes the local assignment, letting the canonical
source/profile fold apply inheritance. `set` does not accept null. Unknown keys,
duplicate unset keys and set/unset overlap are errors. There is no separate
profile-inheritance language: editing uses only semantics supported by the native
parser. The response's parsed sources, configured fold, effective policy and
revision-bound native projection expose the resulting configuration.

Strings are limited to the native 256 UTF-8 bytes and cannot contain controls.
The helper uses literal TOML strings when possible because the native display
parser does not decode escapes. Values requiring an unsupported escape encoding
are rejected. Structured surgery also rejects ambiguous original display syntax,
unknown display extensions, duplicate keys/policy tables and multiline source.
Those sources remain observable and can be repaired through protected raw edits.
Comments and unrelated blocks are retained; changed membership headers and field
assignments are emitted by the shared helper document editor.

**Review and protected apply**

1. Snapshot and copy its generation, source tokens and declaration IDs.
2. Validate the structured request with `protected_apply:true`. Review canonical
   `raw_files`, `candidate_impact`, the existing native display projection and
   `candidate_review.candidate_digest`. Validation's top-level generation and
   declaration IDs/source tokens describe the candidate, not the baseline for apply.
3. Use the original request/generation/IDs to begin the native display preview
   with the returned canonical `wm`/`outputs` sources and full candidate digest.
   Include the current display revision and follow the existing native lease
   contract. Unsupported operations remain unavailable.
4. Apply the original structured request with `candidate_digest`, `preview_token`
   and `--result v1 --operation-id ID`. Inspect save, display and reload results;
   a lost reply is recovered through `operation-status`.

Apply always recomputes and compares the full candidate digest, including no-op
requests. It cannot skip native preview authorization when display effects
require it. `store:true` is not supported by this mutation request and cannot
authorize an unprotected save. Both validate and apply recheck baseline paths,
existence and exact bytes before returning/persisting the candidate.

The contract requires a fresh global generation; collection preconditions cannot
rebase display IDs. Raw edits, legacy `monitor_changes` or other structured edits
to a touched source conflict. Different-source raw/collection/scalar edits may
share the request, but the full mixed candidate remains on the native display
path and its digest binds every source. Legacy `monitor_changes` now rejects
unknown fields rather than ignoring settings such as `enabled` or `primary`.

Errors include `invalid_display_mutation`, `invalid_display_id`,
`invalid_display_field`, `invalid_display_value`, `invalid_display_source`,
`invalid_display_reference`, `conflicting_edits`, `external_change` and the
existing protected digest/preview errors. Rejected operations do not save
configuration, write backups or reload.

Schemas: [display_declaration_changes](aqueous-config-additions-v1.schema.json#/$defs/display_declaration_changes),
[validate request](aqueous-config-additions-v1.schema.json#/$defs/display_mutation_request),
[apply request](aqueous-config-additions-v1.schema.json#/$defs/display_mutation_apply_request).
Run `tests/backend/test-display-mutations.py HELPER DRIVER` for isolated helper
regressions, adding `--schema` with jsonschema installed to validate wire schemas.
The private headless `compositor/scripts/test-display-preview.py` suite exercises
native structured profile equivalence and mixed display/collection Keep/recovery;
it requires a compositor built with `-Doutput-retry-testing=true`. Headless results
are not physical display acceptance.
