## Messaging service

An internal message broker for async, decoupled communication between services. Two features run over it: **pub/sub messages** and **async calls** (detailed below).

Key libraries:
- `github.com/carousell/go-messaging-client/publisher` -- publishing pub/sub messages.
- `github.com/carousell/go-messaging-client/asynccall` -- immediate + scheduled async calls.
- `github.com/carousell/grp-proto-gen-go/messaging/client/public` -- messaging proto types (`MessageRequest`, `MessageMeta`, `MessageResponse`, etc.) used by the `ReceiveMessage` endpoint.
- Many services write a wrapper around these libraries instead of using them directly (eg. `service/messaging/`)

Both features are delivered the same way: the broker calls back into your service over gRPC (`ReceiveMessage` for messages; the target method itself for async calls). So retries, ordering, and the sideline queue behave the same for both.

### Pub/sub messages

Publish a message under a `msgType`; the broker fans it out to all services subscribed to that type. Senders and receivers are decoupled -- the publisher doesn't know who consumes.

- **Publish:** call the `publisher` library, passing `msgType`, a payload `proto.Message`, and (optionally) `msgId` + `orderKey`.
- **Receive:** the broker delivers each message by calling the `ReceiveMessage(ctx, *MessageRequest)` gRPC endpoint on the subscribing service. The service routes by `msgType` to one or more handlers and returns `{Accepted: true}` on success.
  - `ReceiveMessage` is the conventional name and most services use it, but the name is arbitrary -- the method path is a parameter given when registering the subscription, so a service can name it anything. Only the request/response protos (`MessageRequest`, `MessageResponse`) are fixed.
- **Subscriptions must be registered manually by a human.** Each (publisher service, `msgType`) -> (consumer service, endpoint) subscription is a manual registration step in messaging service; it cannot be done from your service code. Flag this when a task needs the service to start consuming a new message type.

### Async calls

Invoke a gRPC method (your own service's or another's) indirectly through the broker instead of calling it directly. The broker delivers by calling that method on the target service. Use this to offload slower work that needs to succeed (broker will handle retries), or needs to run at a future time.

- **Method** is the gRPC method path, e.g. `/listingquota_proto.ListingQuotaAdminService/ExpireListingQuota`. **Payload** is that method's request proto.
- **Immediate:** call the `asynccall` library's immediate-call function. Runs as soon as the broker delivers it. (It can optionally call a callback method back on completion.)
- **Scheduled (delayed/future):** call the `asynccall` library's schedule function with one or more future times. Runs at the given time(s).
- The target method is a normal gRPC handler -- it has no idea it was invoked via the broker vs. called directly.

### Conventions & pitfalls

- **At-least-once delivery -> handlers MUST be idempotent.** The same message or async call can be delivered more than once. Processing it twice must not double-count or corrupt state. Applies to `ReceiveMessage` handlers and any gRPC method reachable via async call.
- **Order key (`orderKey`) gives best-effort in-order processing.** Messages/async calls sharing the same `orderKey` are processed in order; different keys may interleave. Use it for a stream that must stay ordered (e.g. all events for one user/listing). Best-effort, not guaranteed: if an earlier item fails too many times it moves to the sideline queue, so a later item can be processed before it.
- **Publish can fail.** A publish call does not guarantee delivery; it can return an error. There are 2 ways to handle this:
  - Option 1: Retry the publish a few times. Decide per use case whether a publish failure should fail the caller or just be logged -- a dropped message means downstream consumers never see the event.
  - Option 2 (preferred where applicable): CDC + datareplicator. See [CDC / datareplicator](#cdc--datareplicator) below.
- **Skipping stuck messages relies on message ID -> keep message IDs low-cardinality but specific.** To unblock prod, a human can skip a stuck message or async call (immediate or scheduled) **by message ID**. No code needed in your service for this. Implications for the `msgId` you set when publishing / making an async call:
  - Skipping by ID skips every message sharing that ID. Don't make the ID so broad that one skip drops unrelated messages: `<eventType>_<userId>` is bad -- skipping one bad event for a user would skip all of them.
  - IDs need not be unique -- multiple distinct messages may share an ID (subject to the caveat above).
  - The ID is optional -- if unset, messaging service generates a random unique one. Omitting it is fine: such messages can still be skipped, since message IDs are always logged in the broker.
- **Sideline queue (dead-letter) for poison messages.** If an item fails repeatedly, the broker stops blocking the main queue on it and moves it to a sideline queue. The sideline queue delivers via the same `ReceiveMessage` / target-method API.
- Returning an error triggers a retry; acking marks it done.

### CDC / datareplicator

CDC (change data capture) solves the Postgres + message publish dual-write problem via the **transactional outbox pattern**. Instead of publishing directly, the service writes a row to a `cdc_event` table (with the message details) in the same write that persists the entity to Postgres. A sidecar pod (`datareplicator-<service>`, deployed per service) tails `cdc_event` and publishes each row to messaging service. So if the DB write commits, the event is eventually published.

**Two modes**:
- **Direct** -- the entity write is ALREADY a multi-statement transaction. Add the `cdc_event` insert to that same txn. Use whenever a txn already exists.
- **Indirect** -- the entity write is a single statement. Add a `cdc_write_id text` column to the entity table; the DAL generates one `cdc_write_id` and writes it on both the `cdc_event` row and the entity row, and datareplicator only publishes events whose `cdc_write_id` also exists on the entity table (confirming both writes landed).
- Rule of thumb: already in a txn -> Direct. Otherwise -> Indirect (preferred on hot paths to avoid the txn bottleneck).

**Libraries & key types** (`github.com/carousell/go-utils/dalutils`):
- `dalutils.PGClient` -- the DAL. Its CDC write methods take the entity plus `events ...CdcEventable`:
  - single insert -> `InsertWithChangeDataCapture(ctx, record, events...)`
  - CAS update -> `CasUpdateWithChangeDataCapture(ctx, record, events...)`
  - existing transaction -> `TransactionalCDC(ctx, statements, events)`
- `CdcEventable` -- one per event to emit. Build with `WithEntityId(id)` + `WithMessageRequest(msg)`, where `msg` is a `messaging_proto.MessageRequest` built via `NewMessageRequest` in `go-messaging-client/publisher`.

For onboarding a service to CDC/datareplicator, view [How to migrate to CDC](https://carousell.atlassian.net/wiki/spaces/INFRA/pages/1953759646/How+to+migrate+to+CDC) -- it includes the `cdc_event` table schema and provisioning steps.
