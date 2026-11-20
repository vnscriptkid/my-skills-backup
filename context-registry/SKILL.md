---
name: context-registry
description: Consult Context Registry for relevant internal/company-specific knowledge when working on an organization's products, systems, data, processes, or decisions. Check for useful context even when the current session already contains information sufficient to begin the task. Skip general questions unrelated to an organization's specific context.
---

# Context Registry

Context Registry contains internal knowledge and source context for an organization or team. Retrieve only what the current task needs, and use it to ground answers or implementation decisions.

Use the Context Registry MCP connection available in the current environment.

## Tools

| Tool | Purpose |
|------|---------|
| `context_registry_list_domains` | Discover knowledge domains by id, name, and description. |
| `context_registry_get_domain_index` | Browse a domain's tree of nodes and source objects. |
| `context_registry_search` | Find relevant resources by keywords and optional scope. |
| `context_registry_get_resources` | Retrieve node or source-object content by resource id. |
| `context_registry_list_node_types` | Inspect node types, editable fields, options, and defaults. |
| `context_registry_get_node_meta` | Retrieve editable node configurations in batches by bare node ids. |
| `context_registry_propose_change` | Submit node or domain changes for human review. |

The first six tools are read-only. Proposing a change creates a review request; it does not apply the changes.

## Find and Retrieve Context

Choose a starting point based on what is already known:

- **Search** when the task provides useful keywords, such as a service, team, metric, or decision. Use `context_registry_search`, optionally scoped to known domain ids, node ids, or domain-rooted path patterns such as `Analytics/Checkout/**`. `must` terms all match; at least one `should` term must match when supplied; `must_not` excludes matches. Multiple scope entries are alternatives. Omit scope to search everywhere. `size` defaults to 10 results; the returned matches are not necessarily exhaustive. Increase it when broader coverage is needed.
- **Browse** when the relevant area is unclear or the task needs surrounding context. Use `context_registry_list_domains`, choose relevant domains by name and description, then call `context_registry_get_domain_index` with each selected `domain_id`. Skip domain discovery when a valid domain id is already known.
- **Fetch directly** when the relevant resource ids are already available in the session.

Search results and domain indexes provide discovery metadata. Select relevant resources by their names, descriptions, and paths, then call `context_registry_get_resources` with their `resourceId` values in `resource_ids` to read the actual content. Do not treat a search match as evidence of facts that require reading the resource.

Only fetch entries that expose a `resourceId`. Some nodes, such as topics and lists, have an `id` but no `resourceId`. Browse their `children` or `sourceObjects` in the domain index, or use the node `id` as search scope to find relevant resources. Do not construct a resource id from a bare node id.

Use returned ids exactly:

- `n:<node_id>` identifies a context node resource.
- `o:<node_id>/<natural_key>` identifies a source-object resource.
- Bare node ids from index nodes or search hits are used for node metadata and proposal targets, not as resource ids.

Fetch the most relevant resources first and expand only to fill a clear gap. Do not bulk-fetch entire domains. Domain trees, source types, and content vary; sample data is not a template for every domain.

## Propose Registry Changes

Use this workflow when the user asks to add, correct, or remove registry knowledge. Answering a question does not itself require a proposal.

1. Locate the target domain or node using discovery tools or ids already supplied in the session.
2. Prepare items for the requested operations:
   - **CREATE_NODE:** Call `context_registry_list_node_types` to choose the exact `@class` and supported editable fields for `proposed_config`. Supply `domain_id` and optionally `parent_node_id`; omit the parent to create at the domain root.
   - **UPDATE_NODE:** Call `context_registry_get_node_meta` with the bare node ids in `node_ids` immediately before preparing updates; multiple nodes can be fetched in one call. For each node, start from its returned configuration, remove `id` and `syncable`, edit the requested fields, and preserve every other editable field, including `@class`. Updates replace the full configuration; omitted editable fields are cleared. Supply `content_node_id`. Resource content from `context_registry_get_resources` is not editable node configuration.
   - **DELETE_NODE:** Supply `content_node_id` and omit `proposed_config`.
   - **CREATE_DOMAIN / UPDATE_DOMAIN:** Provide domain configuration with `name`, `description`, and `owner`; updates also require `domain_id`.
   - **DELETE_DOMAIN:** Supply `domain_id` and omit `proposed_config`. Call `context_registry_get_domain_index` and recursively traverse `children` to collect every node's `id`, including nodes without a `resourceId`. The domain must be empty, or the same proposal must include explicit `DELETE_NODE` items for every remaining node. Include those deletions only when they are within the user's requested scope.
3. Call `context_registry_propose_change` with a clear `title`, a `description` explaining why the change is needed, and the prepared `items`. Caller identity comes from the MCP request context.
4. Include the proposal id when returned, and report the result accurately: `UNDER_REVIEW` means queued for human review; `NO_CHANGE` means all items already match the current configuration. Changes apply atomically only after human acceptance. Do not report a submitted proposal as an applied change.

Unknown node ids are omitted from metadata responses. If a target is missing, resolve its identity before preparing an update; do not construct replacement configuration from guesses.

## Use the Retrieved Context

- Distinguish retrieved facts from inference, and identify relevant resource names or ids when grounding an answer.
- Preserve exact source, service, team, table, metric, policy, and document names. Do not invent missing ownership, definitions, decisions, or constraints.
- For code tasks, use registry knowledge to understand intent and verify implementation details in the relevant code when available.
- Treat sample content as examples, and account for warnings or limitations in a resource before relying on it.
- If relevant context is missing, state the gap and use another available source or explicit assumptions. Ask for clarification when ambiguity materially changes the answer.

## Retrieval Failures

- If the tools are unavailable, state that Context Registry is unavailable in this session. Continue with available context where possible; request access or missing context when needed to complete the task.
- If a resource fetch fails, re-check its id using the relevant domain index or search results before retrying. If it still fails, report the gap rather than repeatedly retrying.
