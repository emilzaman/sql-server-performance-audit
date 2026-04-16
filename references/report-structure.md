# Assessment Report Structure

A good performance assessment report is not a dump of every finding — it's
a prioritized document the client can act on. Follow this structure.

## Header block

```
<Product> <Module> — Performance Assessment Report
Client: <Name>   Database: <Name> (SQL Server <version>, ~<size>)
Server: <hostname>— <RAM> GB RAM
Assessment period: <start> to <end>
Data source: <DMV polling / cumulative / capture tool>
Server uptime at assessment start: <when>
```

## Section 1 — Executive Summary

**One page.** Non-technical stakeholders read only this.

Include:
- 3-5 bullet points naming the top problem categories (not specific fixes)
- Total number of actionable fixes found
- Quantified expected impact ("SAF-T declaration drops from 4h to < 1h";
  "40-60% I/O reduction on daily workload")
- 3-5 key evidence data points from live monitoring (specific numbers with
  timestamps, e.g., "15-session blocking chain on 2026-04-15 at 14:23")

What NOT to include in section 1:
- Fix script details
- Index names
- Code snippets

## Section 2 — Server Configuration Issues

Covered items:
- Max Server Memory (leave 8-16 GB for OS)
- Plan cache composition (link to `references/plan-cache-analysis.md`)
- Database compatibility level
- Buffer pool composition / cache hit ratio
- MAXDOP / Cost Threshold for Parallelism
- TempDB files and sizing
- Instant File Initialization
- Accelerated Database Recovery (2019+)

Each sub-section: status (APPLIED / PENDING / INFO), evidence, recommendation.

## Section 3 — Database Statistics

- Largest tables (top 20 by size, top 20 by row count)
- Procedure count vs active procedure count (dead-code audit)
- Fragmentation summary (only if > 30% on > 10 GB indexes)

## Section 4 — Daily Workload / Top Bottlenecks

Per top-procedure:
- Name and execution count over the window
- Total CPU / total reads / avg duration
- Peak-load evidence from live polling (if captured)
- Root cause in 1-3 sentences
- Reference to the fix script number

## Section 5-N — Targeted Deep Dives

Large, complex slowdowns get their own section:
- Long-running reports (SAF-T, month-end, year-end)
- Document-save blocking under load
- Batch job scope concerns

Each deep dive:
- Observed impact (numbers + timestamps)
- Procedure breakdown (which inner calls dominate)
- Root cause analysis
- Remediation plan (linked to fix script)

## Section N+1 — Missing Indexes

Summary of DMV recommendations + verification status. Link to
`references/missing-index-verification.md`. List the fix script.

## Section N+2 — Fix Scripts — Inventory

Table format:

| # | Script | Affects | Risk | Expected impact |
|---|---|---|---|---|
| 01 | `01-ProcName-optimized.sql` | \<proc name\> | Low / Med / High | "I/O -90%" or "CPU -40s/call" |

## Section N+3 — Recommended Deployment Order

Phased plan. Example structure:

**Phase 1 — Server configuration** (during maintenance window)
- Memory adjustments
- Parameterization changes (tested first)

**Phase 2 — Missing indexes** (off-peak, ONLINE builds)
- Fix #06

**Phase 3 — SAF-T / batch optimization** (low-risk proc rewrites)
- Fix #12-15

**Phase 4 — Document-save optimization** (medium-risk, needs monitoring)
- Fix #18, #19

**Phase 5 — Low-priority / cosmetic**
- Fix #01-05, #07, #08

## Section N+4 — Estimated Impact

Quantified per category:
- CPU reduction (%) — baseline: 21-day cumulative cpu_sec → estimated after fixes
- I/O reduction (%) — baseline: total logical reads → estimated after fixes
- Specific long-runners: "Declaration X goes from Y hours to Z hours"

## Section N+5 — Observations and Recommendations

Everything that doesn't fit in fix scripts:
- Dead code (unused procedures)
- Anti-patterns requiring vendor attention (OUTER APPLY, FORCE ORDER)
- View indirection issues
- Batch-job scope concerns
- Specific anti-pattern occurrences with references

These are **observations**, not prescriptions — they need vendor involvement
or deeper investigation before fixes are produced.

## Section N+6 — Unused Index Analysis

Only if you've run `queries/unused-indexes.sql` against 30+ days of
uptime. Include size totals — "43 GB of dead index weight" is a powerful
number that gets attention.

## Language rules

- **No hedging language.** "Consider" and "may want to" dilute impact.
- **Cite specific numbers.** "Slow" is vague; "6.2s CPU per call × 299 calls
  in 15 minutes = 1,843 CPU-seconds" is actionable.
- **Name the fix script** every time you discuss a remediation.
- **Mark status inline**: APPLIED / PENDING / INFO / OBSERVATION.
- **Use tables for lists longer than 3 items** — prose lists become noise.

## Update discipline

A living document during the engagement. When a fix is applied:
- Move from "PENDING" to "APPLIED" in place
- Add a dated note with the live impact (if measured)
- Do not delete — the history is valuable for the post-mortem

When new findings emerge during live monitoring:
- Add to the relevant section with `(NEW — <date>)` marker
- Re-run the impact estimates if material
