# Status Page Aggregator

[中文文档](README.zh.md)

A lightweight dashboard that aggregates status pages from multiple services into a single view. Built with Ruby/Sinatra on the backend and plain JavaScript on the frontend — no heavy frameworks, no external CDN dependencies.

## Features

- **Multi-tier monitoring** — Primary services (must-watch) and secondary services displayed separately
- **Multiple API adapters** — Supports Atlassian Statuspage, Google Cloud, and AWS (RSS) out of the box
- **Active events breakdown** — Shows in-progress incidents and maintenances; scheduled maintenances shown as a count badge
- **Severity sorting** — Services with the worst status appear at the top automatically
- **Status legend** — Color-coded indicators on the page for quick reference
- **Manual refresh** — Refresh button with last-updated timestamp; also auto-refreshes every 60 seconds
- **Docker-first** — Runs as a single container with no external dependencies

## Status Indicators

| Indicator | Meaning |
|-----------|---------|
| ✓ Up | All systems operational |
| ⚠ Minor | Partial degradation |
| ✖ Major | Serious outage |
| ✖ Critical | Full outage |
| 🔧 Maintenance | Planned work in progress |
| ? Unknown | Status unavailable |

## Running with Docker

```bash
docker build -t status-page-aggregator .
docker run -d -p 9292:9292 --name status-page-aggregator status-page-aggregator
```

Open `http://localhost:9292` in your browser.

## Configuration

Edit `config/status_pages.yml` to add or remove services. Services are grouped into `primary` and `secondary` tiers.

```yaml
primary:
  MyService:
    url: https://status.myservice.com
    type: atlassian        # atlassian | google_cloud | aws

secondary:
  AnotherService:
    url: https://status.anotherservice.com
    type: atlassian
```

### Supported API types

| Type | Used for | How it works |
|------|----------|-------------|
| `atlassian` | Any Atlassian Statuspage | Calls `/api/v2/summary.json` |
| `google_cloud` | Google Cloud, Gemini | Calls `/incidents.json`; add `filter: gemini` to scope to Gemini/Vertex AI incidents only |
| `aws` | AWS | Parses the public RSS feed at `status.aws.amazon.com`; extracts affected region from each item |

### Known limitations

| Service | Status | Notes |
|---------|--------|-------|
| CrowdStrike | Not supported | No public status page exists as of 2026-03. Will be added once an official status API is available. |

### Adding a new service (Atlassian)

Find the root URL of the service's status page (e.g. `https://www.githubstatus.com`) and add it under the appropriate tier:

```yaml
secondary:
  GitHub:
    url: https://www.githubstatus.com
    type: atlassian
```

## Running locally (without Docker)

Requires Ruby 3.2+ and Bundler.

```bash
bundle install
bundle exec rackup -p 9292
```

## License

MIT
