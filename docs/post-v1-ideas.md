# Post-v1 ideas

**Important:** This is a lose collection of ideas, **not** an actual Roadmap I've commited to.

## 1. Clustering

Allow multiple engine nodes to run as one system. v1 is single-node: timers, PI supervision, and message/signal subscriptions live in that node’s memory. Planning starts after a successful v1 release (`docs/poc/ImplementationPhases.md` Post v1).

**Build:**

1. Swap `Phoenix.PubSub` to a `:pg`-based cluster adapter (or equivalent) so `EngineEventBus` and Phoenix Channels fan out across nodes.
2. Leader election for timer ownership (`Horde.Registry` or `:global`) so cycle Timer Starts and the Scheduler do not double-fire.
3. Cluster-wide PI registry (`Horde.DynamicSupervisor`) so a PI runs on exactly one node and can migrate when a node leaves.
4. Distributed locks for Service Task idempotency (`finish_async` / `fail_async` must not complete the same FNI twice).
5. Multi-node message and signal routing (today a publish reaches only same-node subscriptions — §16.4).
6. `docker-compose.cluster.yml` for local N-node development.

**Exit criterion (from the phase doc):** an N-node engine runs the full conformance corpus, with nodes entering and leaving mid-run without data loss.

Related, not a substitute: a durable `message_subscriptions` table so subscriptions survive a node death without waiting for every PI to resume on another node.

See [event-system.md](architecture/event-system.md), [routing.md](architecture/routing.md), [timers.md](architecture/timers.md).

---

## 2. Engine-level multi-tenant isolation

v1: one engine process = one tenant boundary. Isolation is “run another engine.” In-engine tenancy (catalog, PI, and subscription partitions keyed by tenant) is a product change, not a deploy trick.

Not required for clustering (idea 1). A shared-cluster SaaS that also needs in-engine tenancy is a later product decision on top of this idea.

---

## 3. Durable message subscriptions

Persist catch/boundary/ESP-start subscriptions so drain and rematch do not depend solely on in-memory ETS rebuilt at resume. Useful on its own; almost required for clustering.

---

## 4. Stronger EventSink delivery

At-least-once (or explicit ACK/DLQ) in `EngineEventBus`, plus `Event.SinkFailed` auto-retry / auto-disable / health escalation. v1 is at-most-once, crash-isolated, no retry.

See [event-system.md](architecture/event-system.md).

---

## 5. Per-process / per-endpoint payload-cap overrides

`<evil:tokenMaxBytes>` or per-route caps. v1 `TDE_TOKEN_MAX_BYTES` is engine-global.

---

## 6. Full SPA admin UI

v1 `/admin/` is Swagger + an empty HTML shell. A real operations SPA (PI browser, deploy, metrics) is a separate product, not a docs gap.

---

## 7. DMN FEEL TCK + property-based tests

Import the DMN FEEL TCK into the quality gate. `stream_data` / PropCheck / Concuerror were specified and never added. Expression coverage and race proofs, not BPMN semantics.

See [testing.md](architecture/testing.md) and [expressions.md](architecture/expressions.md).
