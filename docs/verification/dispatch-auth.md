# Dispatch authentication verification

Audience: maintainer verification.

This record supports the current selected-surface authentication guarantee in `bin/fm-auth-preflight.sh` and the dispatch rules in `.agents/skills/quota-array-dispatch/SKILL.md`.
It records only facts that must be re-established when a producer or vendor version changes.
Task chronology, incident transcripts, and credential metadata stay in private reports or PR evidence.

## Producer schema the surface resolution depends on

Verified 2026-07-30 against quota-axi 0.1.16.

`quota-axi auth --json` reports each provider's credential sources independently, which is what lets a candidate be scoped to the one surface it actually authenticates through:

```json
{
  "provider": "grok",
  "sources": [
    { "source": "auth-json", "path": "<home>/.grok/auth.json", "status": "available" },
    { "source": "pi:xai", "status": "available" }
  ]
}
```

Observed source statuses are `available`, `expired` (with an `error` slug), and `missing`.
`quota-axi --provider grok --json` carries `state.authStatus` with the values `usable`, `expired_refreshable`, and `unusable`, alongside `state.sourcesTried`.

Headroom attribution reads three further producer facts, verified 2026-08-03 against quota-axi 0.1.16 with `quota-axi --provider claude --json`:

```json
{
  "windows": [
    { "id": "five_hour", "kind": "session" },
    { "id": "seven_day", "kind": "weekly" },
    { "id": "model:fable", "kind": "model" }
  ],
  "quotaSemantics": {
    "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "boundedBy": ["five_hour", "seven_day"] },
      { "scope": "model:fable", "status": "known", "boundedBy": ["five_hour", "seven_day", "model:fable"] }
    ]
  }
}
```

- A model-specific window is marked `kind: "model"`, which is how a scope bound to one model is told apart from an account-wide one.
- A model scope is named `model:<id>`, where `<id>` is the vendor alias rather than the canonical model id, so `bin/fm-auth-preflight.sh` matches it as a run of identifier tokens against the requested model.
- Each model scope's `boundedBy` already includes the account windows, so its `effectivePercentRemaining` is the combined bound and the consumer must select one scope instead of taking a minimum across scopes.

The third fact is what makes single-scope selection safe. It holds for claude on 0.1.16 and is unverified for providers that gain model windows later; re-establish it here before trusting the same selection for them.
Neither field exists before 0.1.16, so a surface cannot be scoped on an older build.
`bin/fm-bootstrap.sh` enforces that floor and `bin/fm-auth-preflight.sh` refuses rather than emitting an unscoped verdict.

OpenCode is a verified harness, but this producer schema does not model the selected OpenCode credential surface.
When its model has a valid provider/model relationship, the preflight emits `authStatus=unknown`, `headroom=unknown`, `reason=no-auth-evidence`, and `eligible=yes` without selecting a quota provider or probing another harness.
Malformed OpenCode model relationships and unverified harnesses remain ineligible.

Grok also reports `credits.remaining: 0` alongside `percentRemaining: 42` on a healthy account.
That zero is a prepaid balance, not the subscription window, and is never headroom.

## Standalone Grok discovery probe

Verified 2026-07-30 on `grok 0.2.112 (9bbd559437aa) [stable]`.

```sh
grok --version
grok models   # stdin closed, single attempt, hard-bounded
```

Observed:

- `grok models` exits `0` and its first stdout line is `You are logged in with grok.com.` for an authenticated session.
- The documented unauthenticated first line is `You are not authenticated.`, also with exit status `0`.
- Because the status is `0` in both cases, the exit status is not a verdict; only the literal first stdout line is examined, and a blank first line does not authenticate.
- `~/.grok/auth.json` was byte-identical across the authenticated run (`mtime`, `size`, and mode `0600` unchanged), so the probe is a read in that path.

These discriminator strings are un-owned vendor UI text.
`bin/fm-auth-preflight.sh` pins the verified version, reports `probeVersionVerified=no` when the running CLI differs, and classifies any unrecognized first line as `indeterminate` rather than authenticated.
Re-run the two commands above and update this section when the pinned version changes.

## Regression coverage

`tests/fm-auth-preflight.test.sh` drives the real script against nonsecret fixtures shaped like the output above.
It asserts the emitted verdict and, separately, which vendor CLIs were launched, so a Pi/xAI candidate reaching the Grok CLI fails the suite.
It also asserts that an unknown or unplaceable applicable scope keeps headroom unknown, that each accepted spelling of a model resolves to the same scope, and that every resolved candidate receives exactly one post-preflight quota retry.
`tests/fm-bootstrap.test.sh` owns the quota-axi version-floor diagnostic.
