# AGENTS.md

Release Service Monitor -- a Go Prometheus exporter for the Konflux Release Service.
Probes external services (Git repos, HTTP endpoints, Quay registries) on a timer and
exposes availability as Prometheus gauge/histogram metrics at `/metrics`.

## Conventions

- **Commits**: conventional commits with Jira ticket scope: `type(JIRA-ID): message`
  Types: `feat`, `fix`, `chore`. Example: `fix(RELEASE-2110): memory leaks in git and http checks (#84)`
- **Error handling**: wrap errors with context -- `fmt.Errorf("doing X: %w", err)`; never discard errors
- **Logging**: use standard `log.Logger` (not `slog` or third-party); pass instance via constructor
- **HTTP**: always `http.NewRequestWithContext`, never `http.NewRequest`
- **Resource cleanup**: `defer resp.Body.Close()` immediately after the error check on the response
- **Context**: `context.Context` as first parameter to any function that does I/O or may block
- **Naming**: Go conventions -- `MixedCaps`, acronyms all caps (`HTTP`, `URL`, `ID`)
- **Tests**: table-driven tests; `httptest.NewServer` for HTTP mocking; `context.WithTimeout` to avoid hangs
- **Formatting**: Format the code using `gofmt -s`

## Build

```bash
make all              # gofmt + build (binary: build/metrics-server)
make fmt              # gofmt -s -w .
make build            # compile to build/metrics-server
make container IMG=x  # podman/docker build
make clean            # rm -rf build/
./build/metrics-server [config.yaml]  # run locally (defaults to server-config.yaml)
```

## Environment Variable Overrides

Credentials in the config YAML can be overridden via env vars. The naming pattern (constructed in `main.go`):
- Git: `<NAME>_GIT_TOKEN`
- HTTP: `<NAME>_HTTP_USERNAME`, `<NAME>_HTTP_PASSWORD`, `<NAME>_HTTP_CERT`, `<NAME>_HTTP_KEY`
- Quay: `<NAME>_QUAY_USERNAME`, `<NAME>_QUAY_PASSWORD`
`<NAME>` is the check's `name` field uppercased. Env vars take precedence over config file values.

## Adding a New Check Type

Follow the pattern in `pkg/checks/` (use `git.go` as the simplest reference):
1. Exported struct with private fields, `*log.Logger`, and `metrics.CompositeMetric`
2. `New*Check(...)` constructor
3. Private method doing the actual work, returning `(CheckResult, error)`
4. Public `Check(ctx context.Context) float64` -- calls work method, records both gauge and histogram, returns code
5. Add config struct to `pkg/config/config.go` and wire instantiation + env var overrides in `main.go`

## Metrics Semantics

- **Gauge** `<prefix>_check_gauge`: `1` = up, `0` = down. Note: `CheckResult.code` uses `0` = success,
  `1` = failure -- values are **flipped** via `metrics.FlipValue()` before gauge recording.
- **Histogram** `<prefix>_check_histogram`: always records value `1`; uses labels `check`, `reason`, `status`
  where `status` is `"Succeeded"` or `"Failed"` and `reason` is the error message (empty on success).
