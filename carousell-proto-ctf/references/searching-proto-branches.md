# Searching protos on any branch

To search a branch of `cs-proto` or `grp-proto`, clone the repo, check out a fresh worktree at the target branch, then grep/glob the worktree. This flow works for any branch.

Do **not**:
- use the GitHub MCP/CLI -- it silently misses feature branches.
- search a local cs-proto checkout -- it may be out of date. Use the fresh clone+worktree below.

The same flow applies to both repos. Substitute the repo name throughout.

## 1. Clone the base repo (once)

Clone to `/tmp/repos/<repo>` if it isn't already there. Never search this base checkout or any existing worktree directly -- other agents may be using them.

```bash
mkdir -p /tmp/repos
test -d /tmp/repos/cs-proto || git clone https://github.com/carousell/cs-proto /tmp/repos/cs-proto
```

## 2. Fetch, then check out a fresh worktree

Fetch first so new/updated branches are pulled. Create a **new** local branch (`-b`) off the `origin/` ref -- never check out `origin/<branch>` or the bare branch directly, as that blocks other agents from updating origin. Make a fresh worktree per session (never reuse), naming the branch and dir with the same `<session-id>`.

```bash
mkdir -p /tmp/worktrees
cd /tmp/repos/cs-proto
git fetch origin
git worktree add -b claude-<session-id> /tmp/worktrees/cs-proto-claude-<session-id> origin/<target-branch>
```

For the master branch, use `origin/master` as the last argument.

## 3. Search the worktree

Use normal grep/glob over `/tmp/worktrees/cs-proto-claude-<session-id>`. Search `.proto` files -- they are more compact than generated Go.

## 4. Delete the worktree when done

```bash
cd /tmp/repos/cs-proto
git worktree remove /tmp/worktrees/cs-proto-claude-<session-id> --force
git branch -D claude-<session-id>
```

Crashed agents may leave behind stale worktrees and branches under `/tmp/worktrees` and `/tmp/repos/<repo>`. This is expected; don't try to clean up others' worktrees. Just always make a fresh one for yourself.
