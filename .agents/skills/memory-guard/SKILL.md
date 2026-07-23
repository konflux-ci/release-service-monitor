---
name: memory-guard
description: >-
  Review check code for memory-efficient patterns. Audit new or modified monitors
  against known anti-patterns that cause OOMKills (leaked connections, unbounded
  allocations, missing timeouts, cardinality explosions). Use when adding a new
  check, modifying an existing one, or when the user mentions memory, OOM, or
  resource usage.
---

# Memory Guard — OOMKill Prevention Review

Audit new or changed check code against the memory-safe patterns required by
this exporter. The binary runs with a **512Mi memory limit** in Kubernetes
(`config/default/deployment.yaml`), so every check must be frugal.

## When to Apply

Run this review on any change that touches:
- `pkg/checks/*.go` (check implementations)
- `main.go` (check wiring, scheduling, HTTP server)
- `pkg/metrics/metrics.go` (metric registration or recording)
- `go.mod` (new dependencies)

## Review Checklist

Work through each section. For every violation found, explain the risk and
provide the corrected code.

### 1. HTTP Response Bodies — Drain Before Close

**Rule:** Every `http.Client.Do()` call must **drain** the response body before
closing it. Without draining, Go's HTTP transport cannot reuse the underlying
TCP connection, causing connection and goroutine accumulation over repeated
poll cycles.

**Required pattern:**
```go
resp, err := c.client.Do(req)
if err != nil {
    return CheckResult{1, "Failed", err.Error()}, fmt.Errorf("executing request: %w", err)
}
defer func() {
    io.Copy(io.Discard, resp.Body)
    resp.Body.Close()
}()
```

**Anti-pattern (leaks connections):**
```go
defer resp.Body.Close()  // body not drained — connection won't be reused
```

If the body is already consumed (e.g., `json.NewDecoder(resp.Body).Decode(&v)`),
draining is still safe — `io.Copy` on an already-read body is a no-op.

### 2. HTTP Client Timeouts

**Rule:** Every `*http.Client` must have an explicit `Timeout`. Without one,
a hung remote endpoint blocks the check goroutine indefinitely, and since checks
run sequentially, it stalls *all* subsequent checks for the entire poll cycle.

**Required pattern:**
```go
client := &http.Client{
    Timeout:   30 * time.Second,
    Transport: transport,
}
```

**Anti-pattern:**
```go
client := &http.Client{Transport: transport}  // no timeout — can hang forever
```

The Quay check already does this correctly (`Timeout: 30 * time.Second`). All
new checks must follow the same pattern.

### 3. HTTP Client Reuse

**Rule:** Create `*http.Client` (and `*http.Transport`) **once** in the
constructor (`New*Check`) and store it on the check struct. Never create a new
client per poll cycle — each `http.Transport` starts its own connection pool
and idle-connection reaper goroutine.

**Required pattern:**
```go
func NewFooCheck(...) *FooCheck {
    transport := &http.Transport{...}
    client := &http.Client{Timeout: 30 * time.Second, Transport: transport}
    return &FooCheck{client: client, ...}
}
```

**Anti-pattern (leaks goroutines and connections):**
```go
func (c *FooCheck) doWork(ctx context.Context) (CheckResult, error) {
    client := &http.Client{...}  // new pool every poll!
    // ...
}
```

### 4. Bounded Reads — Never `io.ReadAll` on Untrusted Input

**Rule:** When reading a response body (API responses, token endpoints, etc.),
always use a **bounded reader** to prevent a malicious or buggy server from
sending gigabytes of data.

**Required pattern:**
```go
limited := io.LimitReader(resp.Body, 1<<20) // 1 MiB max
body, err := io.ReadAll(limited)
```

Or use `json.NewDecoder` which reads incrementally (acceptable for small JSON).

**Anti-pattern (unbounded allocation):**
```go
body, err := io.ReadAll(resp.Body)  // server controls allocation size
```

### 5. Git In-Memory Storage

**Rule:** `go-git` with `memory.NewStorage()` clones the entire repo (even
shallow) into RAM. This is the single largest per-poll allocation in the
exporter. When adding or modifying git checks:

- **Always use `Depth: 1`** (shallow clone) — never a full clone.
- **Never clone into a package-level variable** — the old storage would be
  retained alongside the new one until GC runs.
- **Prefer hosting-provider REST APIs** (GitHub/GitLab file-content endpoints)
  for simple file-existence checks — they use kilobytes instead of megabytes.
- If `memory.NewStorage()` must be used, ensure the `*git.Repository` goes out
  of scope immediately after the check so GC can reclaim the storage.

**Acceptable (current) pattern:**
```go
func (c *GitCheck) cloneAndGetTree(ctx context.Context) (*object.Tree, error) {
    storer := memory.NewStorage()  // local var — eligible for GC after return
    repo, err := git.CloneContext(ctx, storer, nil, &git.CloneOptions{
        Depth: 1,
        // ...
    })
    // ... use repo, return tree
}
```

### 6. Prometheus Label Cardinality

**Rule:** Histogram labels must have **bounded cardinality**. The `reason`
label currently receives raw `err.Error()` strings, which can produce a
unique time series for every distinct error message. Each unique label
combination allocates a new Prometheus histogram bucket set (~500 bytes+).

**Required pattern — normalize error reasons:**
```go
// Map errors to a small fixed set of reasons
func normalizeReason(err error) string {
    if err == nil {
        return ""
    }
    if errors.Is(err, context.DeadlineExceeded) {
        return "timeout"
    }
    if errors.Is(err, context.Canceled) {
        return "canceled"
    }
    // ... other known categories
    return "error"  // catch-all, NOT err.Error()
}
```

**Anti-pattern (unbounded cardinality):**
```go
reason = err.Error()  // every unique error message = new time series
c.metric.Histogram.Record([]string{c.name, reason, res.status}, 1)
```

If raw error detail is needed for debugging, log it — don't put it in a label.

### 7. New Dependencies (`go.mod`)

**Rule:** Vet any new dependency for memory impact:

- **Avoid** libraries that use large internal caches or buffer pools (e.g.,
  `containers/image` was removed in #61 for exactly this reason — its pgzip
  buffer pools caused OOMs).
- **Prefer** the standard library (`net/http`, `crypto/tls`, `encoding/json`)
  over third-party HTTP/JSON libraries.
- **Check** transitive dependencies — a small wrapper can pull in heavyweight
  packages.
- Run `go mod graph | wc -l` before and after to gauge dependency tree growth.

## Output

After reviewing, produce:

1. **Findings table** — one row per violation, with file, line, rule number,
   severity (🔴 high / 🟡 medium / 🟢 low), and a one-line description.
2. **Corrected code** — for each finding, show the fix as a diff or replacement.
3. **Memory impact estimate** — qualitative assessment of whether the change
   is safe under the 512Mi limit, considering how many check instances will
   run concurrently.

If no violations are found, confirm the change is memory-safe and state why.
