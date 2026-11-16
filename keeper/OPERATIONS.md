# Keeper operations runbook

This runbook covers the clean-room Keeper's **BNB-DESIGN** operating policy. It is not a claim
about 2Factor's private scheduler. The Keeper never accepts a private key, mnemonic, seed phrase or
keystore. A production signer must remain outside this process behind a restricted
`eth_sendTransaction` RPC.

## Roles and hard boundaries

| Component | Allowed capability |
|---|---|
| Read RPC pool | Chain/code/state reads, fixed-block simulations, receipts and gas estimates |
| Keeper process | Select one task, persist one single-flight record, request one external send |
| Managed signer RPC | Sign only the configured sender's allowlisted zero-value maintenance calls |
| Operator | Review alerts, reconcile ambiguous sends, approve staged activation and rollback |

`local-unlocked` is accepted only for a literal loopback IP and is rejected for Base chain IDs
`8453` and `84532`. Production uses `managed-rpc`, HTTPS, and a submit endpoint separate from all
read endpoints.

## Configuration acceptance

Before live mode, the configuration must:

- have filesystem mode `0600`;
- use a unique `deployment.id`;
- contain unique, nonzero Controller/Vault addresses;
- pin every active proxy's `proxyCodeHash`, EIP-1967 `implementation`, and
  `implementationCodeHash`;
- configure distinct state, health, metrics and alert files;
- use `submissionMode: managed-rpc`, a separate HTTPS submit endpoint and no URL userinfo/query;
- contain no private signing fields anywhere in the JSON tree.

Provider API tokens may be supplied in an RPC URL path when required, but event logs remove the
entire path and report only scheme/host/port. Protect the configuration as a secret-bearing
operational file even though it cannot contain signing keys.

## Staged activation

1. Generate the deployment manifest from the reviewed deployment pipeline. Never copy an address
   or codehash from an unreviewed terminal transcript.
2. Start with `live: false`, `submissionMode: disabled`, and `submitRpcUrl: null`.
3. Run one fixed-block dry cycle and inspect every `simulation` result:

   ```sh
   python3 -m keeper --config keeper/config.dry.json
   ```

4. Configure the external signer endpoint, keep broadcasting disabled, set the config to mode
   `0600`, and run the non-broadcasting preflight:

   ```sh
   chmod 600 keeper/config.preflight.json
   python3 -m keeper --config keeper/config.preflight.json --preflight-only
   ```

   This validates the read deployment, fixed-block simulations, submit chain ID and pending nonce.
   It cannot prove signing authority without an actual send; validate that authority in the signer
   control plane and a controlled non-production drill.

5. Set `live: true` only after health/metrics/alerts are collected. Execute one canary cycle, not a
   loop:

   ```sh
   python3 -m keeper --config keeper/config.live.json --allow-broadcast
   ```

6. Confirm the receipt and a fresh dry-run before enabling the loop:

   ```sh
   python3 -m keeper --config keeper/config.live.json --loop --allow-broadcast
   ```

## Health, metrics and alerts

- `healthFile` is an atomic JSON snapshot with `healthy`, `degraded` or `critical` status.
- `metricsFile` is a Prometheus textfile containing status, pending state, last success, latest hard
  error count, event counters and alert counters.
- `alertsFile` is an append-only mode-`0600` JSONL stream. It contains no RPC paths, calldata,
  balances or signing data.

`degraded` means reads/submissions may still succeed but an operator must investigate, for example
an RPC failover or lower-priority unknown simulation error. `critical` means live operation should
stop until reconciled.

| Alert | Required response |
|---|---|
| `RPC_FAILOVER` | Check the failed provider; keep the backup capacity available |
| `SIMULATION_ERROR` | Identify the task and selector; do not declare the deployment healthy |
| `TASK_BLOCKED` | Resolve the higher-priority deterministic error before sending anything |
| `RECEIPT_STALE_*` | Check propagation/nonce; preserve the single-flight lock |
| `SUBMISSION_AMBIGUOUS` | Do not retry; follow the reconciliation procedure below |
| `SUBMISSION_BLOCKED` | Keep the service stopped until the ambiguous record is resolved |
| `RECEIPT_REVERTED` | Stop live mode and inspect the confirmed dependency/state change |
| `CYCLE_ERROR` | Return to `--preflight-only`; resume only after a clean result |

## Ambiguous submission reconciliation

1. Stop the Keeper loop. Do not delete or edit the state file.
2. Record the state entry's task, target, `submittedAt` and `submittedBlock`.
3. In the managed signer audit log, locate the request for the configured sender around that time.
4. Query the sender's pending/mined transaction by nonce through an independent read RPC.
5. If a hash exists, insert it only through a reviewed reconciliation tool or code review; do not
   resend the maintenance call.
6. If no transaction exists, obtain explicit operator approval before clearing the ambiguous lock
   and returning to a dry-run. The current Keeper intentionally has no automatic clear/retry path.

## Stop and rollback

- Stop the process first; an on-chain maintenance call already confirmed cannot be rolled back.
- Preserve the state, health, metrics, alerts and signer audit trail.
- Change the next configuration to `live: false` and `submissionMode: disabled`; do not reuse a
  submission-enabled config with relaxed file permissions.
- Run `--preflight-only` after any proxy upgrade, signer change, RPC change or deployment-address
  change. Updated implementation attestations require deployment review, not an automatic refresh.

## Local staged drill

The repository's no-key rehearsal remains:

```sh
RUN_KEEPER_ANVIL_E2E=1 python3 -m unittest \
  keeper_tests.test_local_anvil.LocalAnvilIntegrationTest.test_complete_local_keeper_lifecycle -v
```

It uses only ephemeral loopback Anvil, validates proxy/implementation attestations, submits four
maintenance transactions one at a time, confirms each receipt, exercises RPC failover and checks
health/metrics/alerts. It must not be repointed at a public network.

