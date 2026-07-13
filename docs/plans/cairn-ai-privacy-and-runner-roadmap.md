# Cairn — AI-Privacy Flagship + cairn-AI Runner Roadmap

**Started:** 2026-07-13. **Owner:** Claude (tech lead). **Status:** PLAN / strategy
revision — no implementation without explicit operator go (standing scope rule:
plans only, cairn tree only).

This roadmap sits ABOVE the two existing plans
(`cairn-flutter-powersync-connection-redesign.md`, `cairn-cloud-trust-and-coverage.md`).
On ratification it should feed a `docs/STRATEGY.md` update.

## Why (verified, not asserted)

Operator directive: match PowerSync's feature surface so the Rust/throughput moat
comparison is clean, then differentiate hard on encryption/compliance PowerSync
lacks, aimed at AI apps. Three grounded findings reshaped the strategy:

1. **PowerSync already has basic E2EE + HIPAA** ([data-encryption](https://docs.powersync.com/client-sdks/advanced/data-encryption),
   [security](https://docs.powersync.com/resources/security)). So basic encryption
   is **table stakes, not a differentiator** — claiming otherwise is a credibility hit.
2. **The AI ↔ E2EE conflict is the real, unowned gap.** Putting an AI model in the
   path breaks E2EE (the model host sees plaintext) ([analysis](https://blog.cryptographyengineering.com/2025/01/17/lets-talk-about-ai-and-end-to-end-encryption/)).
   PowerSync has no AI-privacy story. That is the opening.
3. **The "Rust inference runner that beats Ollama on concurrency" already exists**
   under MIT: [Mistral.rs](https://github.com/ericlbuehler/mistral.rs) — pure Rust,
   continuous batching + PagedAttention, GGUF/GGML/SafeTensors, multimodal,
   natively agentic (MCP client), OpenAI-compatible server. Building one from
   scratch reinvents it.

## Two-product strategy

- **cairn-core** (today's engine, extended): the **model-agnostic privacy boundary** —
  zero-knowledge E2EE local-first sync + on-device plaintext + the WYSIWYS
  egress-integrity layer. The flagship differentiator.
- **cairn-AI** (NEW, decoupled): a separate crate/package that **uses cairn-core
  under the hood** + runs **any LLM** (cloud APIs + local models) via a fork of
  Mistral.rs, with cairn-powered memory/RAG/MCP + the WYSIWYS boundary. Self-contained,
  operates on its own, depends on `cairn-core` but ships independently.

## Decisions ratified (grill-with-docs, 2026-07-13)

1. **Flagship = AI-privacy local-first sync.** On-device AI over synced plaintext;
   ciphertext-only egress; WYSIWYS integrity.
2. **cairn-core scope = model-agnostic privacy boundary** (cairn-core does not run
   models; the app brings its AI).
3. **E2EE key model = zero-knowledge / client-derived.** cairn-cloud **cannot**
   decrypt synced data — "cloud sees ciphertext only" is a cryptographic fact, not
   a promise. (Key-recovery UX mitigated by an optional recovery-code /
   escrowed-shard scheme — NOT server-held keys.)
4. **WYSIWYS edge = SDK egress API + drop-in AI wrappers.** `cairn.send(model,
   authorizedManifest, payload)` MACs the manifest, enforces "payload ⊆ manifest"
   (strips un-authorized fields/stego/metadata); drop-in wrappers
   (`CairnAI(OpenAI(...))`, Anthropic, Gemini) for one-line adoption.
5. **cairn-AI = decoupled product** that rides cairn-core + runs any LLM (cloud +
   local downloadable) + "more features."
6. **cairn-AI architecture = orchestrator + Rust inference runner** (chase Ollama's
   concurrent-collapse gap).
7. **Inference foundation = fork + extend Mistral.rs** (MIT, Rust, continuous
   batching, GGUF, MCP) under cairn control — NOT from-scratch.

## cairn-core flagship — AI-privacy local-first sync

- **Zero-knowledge E2EE** over the existing sync: client-derived keys (passphrase→KDF /
  device-biometric / pairwise ECDH); cairn-server + cairn-cloud see ciphertext only.
  Composes with the Flutter redesign's materialized typed tables (encrypt the
  payloads; the local DB holds plaintext, the wire/cloud hold ciphertext).
- **WYSIWYS egress boundary** (the headline novelty): manifest+MAC at the data-egress
  point; drop-in wrappers around the popular AI SDKs. The model sees/sends only the
  user-authorized manifest — no hidden prompt-injection payloads, no steganographic
  exfil via embeddings, no metadata leak.
- **Enabling primitive — granular ("pixel") encryption**: per-field encryption with
  selective decrypt, so a model/server can be authorized for specific fields, never
  the whole row. Goes beyond PowerSync's all-or-nothing client-side E2EE.

## cairn-AI — decoupled AI layer (NEW)

A separate crate/package (`cairn-ai`) depending on `cairn-core`, shipping as its own
SDK + optional runtime binary. **v1 feature set (proposed, for ratification):**

- **Universal routing** — `cairn.ai.chat(model, …)` to cloud APIs (OpenAI/Anthropic/…)
  + local models via the forked Mistral.rs; per-task routing (cost / privacy / latency).
- **RAG over encrypted synced data** — the agent's knowledge base IS the user's
  cairn-synced tables, queried locally. This is the "cairn-powered" core: the AI
  reasons over the user's real data, on-device, privately.
- **Persistent agent memory** — conversations/decisions synced across devices via
  cairn (your AI's memory follows you, encrypted) — directly leverages cairn's
  throughput + offline-first.
- **MCP client** — standard tool/resource interop (Mistral.rs already ships this).
- **WYSIWYS egress** — inherited from cairn-core; every model call is manifest-bound.
- **Concurrent-agent orchestration** — many agents/sessions; cairn's Rust throughput
  lands HERE (the orchestration/memory layer), **not** in inference tok/s.

**Fast-follows:** MCP server (expose cairn data as MCP resources); tool-sandboxing
(agent tools gated by the boundary); on-device embeddings for local RAG; multimodal.

**The fork:** cairn-AI's runner = a fork of Mistral.rs, extended for the
concurrent-agent workload + hard cairn sync/memory/boundary integration at the
engine level. Trade-off accepted: ongoing upstream-merge burden in exchange for
owning the inference path.

## Parity track (match PowerSync — do NOT claim to beat)

Closes the "PowerSync offers X cairn doesn't" gaps so the moat comparison is clean:

- **HIPAA BAA** + **GDPR** (data residency + right-to-erasure) + **SOC 2 Type II**.
- **Dashboard** parity (PowerSync's is cloud-only / paid-self-host; cairn ships one
  free for self-host — itself a wedge).
- **Sync-Streams expressiveness** (parameterized queries, lazy `subscribe(name, params)`)
  — the deferred P5 from the parity plan.

## Sequencing (phases)

- **P0 — Parity close.** HIPAA/GDPR/SOC2 posture + dashboard + Sync Streams.
- **P1 — cairn-core flagship.** Zero-knowledge E2EE + WYSIWYS egress API + wrappers
  + granular encryption. (Composes with the Flutter redesign.)
- **P2 — cairn-AI orchestrator.** Universal routing + RAG-over-synced-data +
  persistent memory + MCP client + WYSIWYS, over cloud APIs + external runners.
- **P3 — cairn-AI runner.** Fork + extend Mistral.rs; integrate as the local backend.
- Existing plans proceed in parallel: Flutter PowerSync-style redesign (WS1–WS6),
  cloud-trust + coverage (license verify + cloud e2e).

## Honest risk register (verified vs. assumed)

- **Rust-runner competes with incumbents on inference** (llama.cpp/vLLM own
  GPU-inference tok/s). **Mitigation:** fork Mistral.rs (don't reinvent); compete on
  the cairn-specific layers + concurrent-agent orchestration, not kernel tok/s. The
  claim "cairn-AI out-runs Ollama on inference" is NOT made — the claim is
  concurrent-agent orchestration + privacy, where cairn's moat actually lives.
- **Throughput-moat scope.** cairn's 142k–833k ops/sec is **sync fan-out**; it does
  not auto-transfer to inference. Honest scoping above.
- **Zero-knowledge key recovery UX.** No server-held keys means no "forgot password"
  without a recovery scheme. **Mitigation:** optional recovery-code / escrowed-shard
  (still not server-readable).
- **Fork upstream-merge burden** (Mistral.rs moves fast). **Mitigation:** keep the
  fork's divergence narrow — cairn-specific layers as an outer crate, minimal engine
  patches upstreamed.
- **Pre-1.0 maturity** vs PowerSync's production miles. Not solvable by roadmap;
  named plainly.

## Preserve (moat — do NOT regress)

- Rust fan-out throughput; Apache-2.0 end-to-end; server-enforced tenancy; JSON wire.
- Open-core boundary (ADR-0006): features free in OSS; cloud = operational convenience,
  never a feature gate. cairn-AI's local-runner + core E2EE/WYSIWYS stay open; only
  managed-cloud operations + enterprise compliance wrap are paid.

## Explicit-go gate

This is a plan/strategy. Implementation begins on operator "go" + phase sequencing.
Per standing scope: plans only; cairn tree only; commit only when asked.
