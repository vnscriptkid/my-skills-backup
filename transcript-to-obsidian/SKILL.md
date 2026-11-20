---
name: transcript-to-obsidian
description: Convert course transcripts into an Obsidian knowledge graph using atomic notes and wiki-links. Use when user wants to process lecture transcripts, course notes, or video transcripts into Obsidian markdown files with [[wiki-links]] that form a knowledge graph.
---

# Transcript to Obsidian Knowledge Graph

## Pipeline

Transcripts → Clean → Chunk → Extract concepts → Atomic notes → Link → Hub notes → Graph

## Step 1 — Clean the transcript

Use this prompt to clean raw transcripts before note-taking:

```
You are an expert note-taker.

Convert this transcript into structured notes:
- Remove filler words (uh, um, basically, right?)
- Group into logical sections with headers
- Extract key concepts as bullet points
- Keep concise but meaningful
- Preserve technical accuracy

Transcript:
[PASTE HERE]
```

Output = clean structured notes (not yet a graph).

## Step 2 — Chunk into atomic notes

**Rule: 1 note = 1 concept.** This is where most people fail.

| Bad | Good |
|-----|------|
| `Kafka.md` (everything inside) | `Kafka.md`, `Kafka Partition.md`, `Kafka Consumer Group.md` |

Use this prompt to extract atomic concepts:

```
From these structured notes, list every distinct concept that deserves its own note.

Format as:
- Concept Name: one-sentence definition
- ...

Notes:
[PASTE CLEANED NOTES]
```

## Step 3 — Write atomic notes

Each concept becomes one `.md` file. Template:

```markdown
# {Concept Name}

## Definition
{One-sentence definition}

## Key Points
- {Point 1}
- {Point 2}
- {Point 3}

## Related
- [[Parent concept]]
- [[Related concept 1]]
- [[Related concept 2]]
```

Use this prompt to generate a batch:

```
Convert this concept list into Obsidian atomic notes.

Rules:
- Use the template: # Title, ## Definition, ## Key Points, ## Related
- Add [[wiki-links]] for every related concept
- Link to parent topic, siblings, and use cases
- Keep each note under 20 lines

Concepts:
[PASTE CONCEPT LIST]
```

## Step 4 — Link aggressively

Three link types to add in every note:

1. **Concept → Parent**: `[[Kafka]]`
2. **Concept → Sibling**: `[[Kafka Consumer Group]]`, `[[Kafka Offset]]`
3. **Concept → Use case**: `[[Real-time analytics]]`, `[[Event-driven architecture]]`

When in doubt, link. Links cost nothing and build the graph.

## Step 5 — Create hub notes

Hub notes are index files — the entry point in graph view.

```markdown
# {Topic}

## Core Concepts
- [[Concept A]]
- [[Concept B]]
- [[Concept C]]

## Use Cases
- [[Use Case 1]]
- [[Use Case 2]]

## Related Systems / Topics
- [[Related Topic 1]]
- [[Related Topic 2]]
```

Use this prompt:

```
Create a hub note for [{Topic}] based on these atomic notes.

Include sections: Core Concepts, Use Cases, Related Systems.
Use [[wiki-links]] for everything.

Notes:
[PASTE ATOMIC NOTES]
```

## Workflow checklist

- [ ] Clean transcript (remove filler, add structure)
- [ ] Extract concept list
- [ ] Generate atomic notes (1 per concept)
- [ ] Add [[wiki-links]] to each note (parent + siblings + use cases)
- [ ] Create hub note per major topic
- [ ] Drop all files into Obsidian vault
- [ ] Open Graph View — verify connections exist

## Output structure

```
vault/
├── Kafka.md                    ← hub note
├── Kafka Partition.md          ← atomic
├── Kafka Consumer Group.md     ← atomic
├── Kafka Offset.md             ← atomic
├── Kafka Broker.md             ← atomic
└── Event Streaming.md          ← use-case note (shared across topics)
```
