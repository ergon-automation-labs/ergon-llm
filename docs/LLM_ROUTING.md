# Local model routing: choosing a node, and not overloading it

Two separate questions, two separate mechanisms. Confusing them is how a bot ends
up hammering one machine with three copies of the same 17 GB model.

| Question | Module | Answers with |
|---|---|---|
| *Which* node can take this work? | `BotArmyLlm.OllamaHealthChecker` | a URL + model, or a refusal |
| *How much* work is that node already holding? | `BotArmyLlm.NodeQueue` | a slot, a wait, or a refusal |

Both are gated behind `BotArmyLlm.CircuitBreaker` at the provider level, and both
are inert for cloud providers: everything here is about the two local Ollama
nodes (`air`, `mini`).

## Asking for a node

`llm.request.chat` carries node targeting as a wire field, so no separate
subjects are needed — there is one llm bot:

```json
{
  "model_type": "uncensored",
  "ollama_node": "mini",
  "messages": [{ "role": "user", "content": "…" }]
}
```

`ollama_node` values:

| Value | Meaning |
|---|---|
| absent / `""` / `"auto"` | lowest-latency healthy node (explicit-only nodes excluded) |
| `"air"` / `"mini"` | that node, by name; bypasses latency ordering and the explicit-only filter |
| `"round-robin"` / `"rotate"` / `"rotation"` | the weighted rotation below |

An unknown name is inert: the rotator only ever returns a node the health
checker offered, so a typo'd weight cannot route work to nothing.

## Weighted round-robin

`BotArmyLlm.NodeRotator` alternates the healthy nodes on a schedule expanded from
`OLLAMA_ROUND_ROBIN_WEIGHTS` (default `air:2,mini:1` → `air, air, mini`). It is
opt-in per request; the *default* policy does not change.

```bash
# air's local 9B and mini's 27B, alternating
nats request llm.request.chat '{"payload": {"messages": [...], "model_type": "uncensored",
                                           "ollama_node": "round-robin", "async": true}}'
```

The model for `uncensored` comes from `OLLAMA_MODEL_UNCENSORED` per node
(`baytout3/qwen3.5-uncensored:9B` on air, `…:27B` on mini), so the rotation is
also a rotation of model sizes. `:uncensored` is **local-only and fail-closed**:
no local node, no answer, and emphatically no cloud fallback — that is what makes
it uncensored.

## One generation at a time per node

A node has one GPU. A second concurrent generation does not go faster; it makes
both slower, and on a machine that is also somebody's laptop it makes the machine
unusable. `BotArmyLlm.NodeQueue` therefore admits, per node URL:

* `OLLAMA_NODE_MAX_CONCURRENCY` (default `1`) generations at once;
* at most `OLLAMA_NODE_MAX_WAITING` (default `2`) more waiting behind them, FIFO;
* `OLLAMA_NODE_MAX_WAIT_MS` (default `600000` — ten minutes, deliberately inside
  the 900 s a caller will poll before giving up) for a waiter, after which it is
  told `:queue_timeout`;
* a job arriving when the node is saturated **and** the wait list is full is
  refused with `:queue_full`.

Waiting is *per node*, so a busy mini never holds up air.

A refusal is shaped like a provider error, and that is deliberate: for a cloud-
eligible request the chain falls through to a cloud provider (no worse than
before), and for a **local-only** request there is nothing to fall through to —
the job fails and says so. An unbounded queue would instead look exactly like a
hang, which is the failure this exists to remove. The cause is preserved in the
log as `{:ollama_node_busy, :queue_timeout}`, not a bare timeout.

Both failure modes open rather than closed: if the gate is not running the work
runs anyway, and a holder that dies without releasing has its slot freed by a
monitor.

## Inspecting it

```bash
# who holds each node, and who is waiting behind them
ssh air 'E=$(printf %s "<base64 of: BotArmyLlm.NodeQueue.status()>"); \
  /opt/ergon/releases/llm_proxy/current/bin/llm_proxy rpc "$E"'
```

`status/0` returns a label per job — the `job_id` the caller already has, taken
from the job process by
[`NodeQueue.queued_label/0`](../lib/bot_army_llm/node_queue.ex) — so "mini is
busy" becomes "job `e0a21859…` is why mini is busy".

Log lines worth knowing:

| Line | Means |
|---|---|
| `LLM node <key> was busy: job <id> waited <n>ms for its slot` | a real wait, with its duration |
| `LLM node <key> refused job <id> after waiting <n>ms` | the wait budget expired |
| `LLM node <key> is saturated and its wait list is full — refusing job <id>` | refused outright |
| `LLM job <id> is uncensored and local nodes are loaded: it waits…` | logged at submit, before any waiting |

## Node URLs and fallback names

Each node is probed at a list of URLs (`OLLAMA_URLS`, `OLLAMA_MINI_URLS`), tried
in order, so a tailnet address can be followed by a LAN name for the case where
Tailscale is the thing that is down. `mini.local` is **not** a LAN name: Tailscale
MagicDNS resolves it to the tailnet IP. The real off-tailnet name for mini is
`the-chosen-legend.local` (`192.168.1.15`).

## See also

* `docs/KNOWN_ISSUE_*` in the monorepo for the queueing incidents that motivated
  this (a three-word uncensored job sat `pending` for over ten minutes).
* `bot_army_infra/pillar/air.sls` — `llm:ollama` and `llm:ollama_mini`. Mini's
  node config deliberately lives *outside* `llm:ollama`, which the live-only
  `air-secrets.sls` shadows.
