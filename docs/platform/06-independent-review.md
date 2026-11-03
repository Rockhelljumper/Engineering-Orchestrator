# 06 — Independent review of ADR-005..010 and reports 01..05

Review run 2026-11-03 ~19:20Z by a separate reviewer with no edit rights, against the code on `origin/claude/m2-phase-b`. Its verdict: **not fit to mark final yet.** ADR-005 and ADR-007 could be final after the nits; ADR-008 needed network and mapping fixes; ADR-006, ADR-009 and ADR-010 needed real changes. After that, the anchor channel needs one more focused review before implementation (F-5).

Every finding below has been applied in this revision. None of the ADRs is marked final.

## Blocking

| ID | Finding (verified against code) | Resolution |
|---|---|---|
| B1 | ADR-010's channel rule (`seq > prevSeq`) was weaker than the anchor service, which requires `seq == head+1`, `prev == head MAC`, same keyId (`eo_anchor.py:258-282`). A stolen client key could jump the head and force an attended rollback | ADR-010 §1a keeps the service's exact semantics; only the transport changes. Test 29 rewritten |
| B2 | "Retry the advance and keep going" contradicted the journal, which refuses every append after a failed anchor update (`journal.ts:122,131-135`). `execFileSync` with 30 s timeout (`anchorService.ts:91-96`) blocks the lease heartbeat | Frozen-journal mode specified, then one-ahead repair on reopen; channel timeout below `leaseMs/3` or async. Test 30 extended |
| B3 | Rollback-acceptance authority across VMs undefined; grants exist only on the anchor's root admin socket. Blank `adopt` grant for re-init lets a compromised `eo-control` choose the head (`eo_anchor.py:273-278`). Restore loses spend | Grants, clears and re-init only at the `eo-anchor` console; channel forwards hello/read/advance/forget only; new `set-head` from the external log, never below the shipped head; spend reconciliation before dispatch after any accepted rollback (T36). Tests 34–37 |
| B4 | ADR-009 relied on a non-existent `attempt.dispatch` record; resume step 5 synthesizes `interrupted` ends for started attempts (`controller.ts:545-557`), which would run a retry beside a live Job; journal seqs are reused after rollback | New record types defined; recovery confirms or adopts the Job before writing an end, and says it changes the M1-4/T10 protocol; identity uses a random dispatch nonce plus keyId. Tests 10–12 in ADR-009, test 38 |
| B5 | Audit policy logged Secret request bodies; K3s datastore holds Secrets in plaintext without `--secrets-encryption`; its backup holds the CA and server token | Secrets audited at Metadata only; secrets encryption on; datastore backup classified as a cluster-admin credential. Test 40 |
| B6 | Flux could deploy NetworkPolicy/RBAC on a merge; "recorded approval" undefined; controller could have read a Flux-managed Job template | Controller renders Job specs only from its own policy; NetworkPolicy/RBAC/admission promotion-gated by an owner-signed tag; branch protection incl. admins, CODEOWNERS, no AI write/bypass; Flux hardening flags; no image automation or receivers; unsigned commits fail closed; no AI console on eo-control/eo-anchor. Tests 18, 41 |

## Should-fix (all applied)

| ID | Finding | Resolution |
|---|---|---|
| S1 | Reply MAC unverifiable (symmetric key on the anchor; client ignores `mac`) | Ed25519 reply signatures with pinned public key; channel daemon its own sandboxed uid |
| S2 | `eo-anchor` had no path for log shipping or time | Proxy path to the evidence store and one time source only (ADR-008) |
| S3 | K3s defaults and admission gaps | traefik, servicelb, local-storage, metrics-server off; agent token; admission denies nodeName, control-plane tolerations, hostPort, ephemeral containers, non-emptyDir volumes. Test 39 |
| S4 | Network contradictions (test 20 vs ADR-008; missing receiver port; unnamed overlay; own-kubelet; IPv6 setting) | Ports named (7444 receiver, 51820/udp WireGuard); pods denied API and own kubelet; IPv6 dropped by firewall plus sysctl |
| S5 | RBAC lacked Secrets create/delete and `jobs` patch needed for owner references | Role amended; suspended-create then unsuspend flow |
| S6 | Evidence store lacked withholding detection, retention, WORM; checkpoints from eo-control untrustworthy | Heartbeats and gap alerts, WORM, retention proposal; re-init trusts only the anchor-signed log. Test 43 |
| S7 | Option B overstated: root on eo-control can forge forward history | Table corrected |
| S8 | Staging deploy key also in the state root; SSH push path unspecified | Key moves with `journal.key`; push path decided in M8-K2 |
| S9 | M8-4 snapshot scope, M8-3 tier definition, M8-7 unmapped, K6 needs M4–M7 | Mapping section in ADR-008; 04 graph and K6 row updated |
| S10 | "Not routinely on eo-control" weakened F-6 | Now "never on eo-control or any EO VM" |
| S11 | Phase C criteria inconsistent (M2-6) | Aligned |
| S12 | Platform pods on the trusted VM widen G-1 | Deny from eo-exec to platform namespace; Headlamp plugins off. Test 42 |
| S13 | Artifact receiver parses untrusted bundles on the trusted VM | Own uid, sandbox, hooks/config disabled |

## Nits (all applied)

Stale README entries; citation drift (`fsx.ts:36-49`, `eo-anchor.service:23,44`, fsGroup changes group not owner); "two-VM Phase B" wording; stale 02 anchor row and missing 7443; proxy-side key injection contradicting "no keys on eo-edge" (now an explicit owner decision); tests 1 and 33 merged; test 26 moved to integration at M8-K2; G-6 closed with WireGuard; "the adapter journals" → the controller journals.

## Still open

- A focused second review of the anchor channel (ADR-010 §1a) before any implementation (F-5).
- Owner sign-off to mark the ADRs final.
- The reviewer noted `roadmap/proxmox-staging-proposal.md`, cited by ADR-008 as the two-VM proposal, exists on no branch; ADR-008 now cites it as the earlier proposal discussed in the project rather than a file.
