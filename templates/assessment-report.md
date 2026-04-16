<Product> <Module> — Performance Assessment Report

Client: <Name>   Database: <Name> (SQL Server <version>, ~<size> TB)
Server: <hostname>— <RAM> GB RAM
Assessment period: <YYYY-MM-DD> to <YYYY-MM-DD>
Data source: DMV polling (<N> snapshots over <D> days, automated every 15 min); cumulative stats cover <U> days since server restart (<YYYY-MM-DD>)
Server uptime at assessment start: Since <YYYY-MM-DD> (~<U> days)

------------------------------------------------------------------------

1. Executive Summary

The <DB name> database has significant performance issues stemming from <N> categories:

1.  <Category 1 — 1-sentence summary>
2.  <Category 2>
3.  <Category 3>
4.  <Category 4>

We identified <N> actionable fixes (provided as ready-to-deploy SQL scripts) that address the most impactful issues. <Highest-priority quantified impact claim>. Daily workload improvements are estimated at <X%> reduction in I/O and <Y%> reduction in CPU. <Additional high-impact claim>.

Key findings from live-load monitoring on <date> (automated 15-minute polling):
- <specific numeric observation with timestamp>
- <specific numeric observation>
- <specific numeric observation>
- <specific numeric observation>
- <specific numeric observation>

------------------------------------------------------------------------

2. Server Configuration Issues

2.1 <First config issue> — <APPLIED / PENDING>

<Evidence block with actual values from sys.configurations / DMVs>

<Recommendation or applied-state note>

2.2 <Second config issue>

<Evidence>

<Recommendation>

...

------------------------------------------------------------------------

3. Database Statistics

3.1 Largest Tables

<Table of top 20 by size — from queries/table-sizes.sql>

3.2 Active Procedures

<proc count overview + dead-code percentage>

------------------------------------------------------------------------

4. Daily Workload — Top Bottlenecks

4.1 Top 10 CPU Consumers (<N>-day cumulative)

<Table: procedure | execution_count | total_cpu_sec | avg_cpu_ms | total_reads>

4.2 <Highest I/O Consumer>

<Procedure-level breakdown — link to fix script>

4.3 <Plan cache pollution / specific anti-pattern>

<Details>

4.4 <Server freeze / memory grant issue>

<Details>

4.5 <Live-load critical finding>

<Details with evidence from polling>

------------------------------------------------------------------------

5. <Long-running declarations / reports — if applicable>

5.1 Observed Impact

<Runtime, memory grant, freeze evidence>

5.2 Procedure Breakdown

<Which inner calls dominate>

5.3 Root Causes

<Per anti-pattern section>

------------------------------------------------------------------------

6. Missing Indexes

<Summary + link to verification methodology. List the fix script name.>

------------------------------------------------------------------------

7. Fix Scripts — Inventory

7.1 Server Configuration (manual — not scripted)
<list>

7.2 Missing Indexes
Fix #06 — <description>

7.3 Daily Workload Procedures
Fix #01 — <proc>   <description>
Fix #02 — <proc>   <description>
...

7.4 <Specialized report / batch fixes>
Fix #12 — <proc>   <description>
...

------------------------------------------------------------------------

8. Recommended Deployment Order

**Phase 1 — Server configuration**
1. <config change>
2. <config change>

**Phase 2 — Missing indexes**
3. Fix #06 — Missing indexes (CREATE INDEX only, no data changes)

**Phase 3 — <priority batch>**
4. Fix #<NN> — <proc>
5. Fix #<NN> — <proc>

**Phase 4 — <medium-risk batch>**
6. Fix #<NN> — <proc>
7. Fix #<NN> — <proc>

**Phase 5 — Low priority**
8. Remaining fixes

------------------------------------------------------------------------

9. Estimated Impact

<Per-category quantified impact table>

------------------------------------------------------------------------

10. Observations and Recommendations

10.1 Dead Code
<Unused procedures note>

10.2 <Anti-pattern observation>
<Details — NOT a fix, a vendor-level observation>

10.3 <Anti-pattern observation>
<Details>

...

------------------------------------------------------------------------

End of report.

Living document — update in place as fixes are applied. Mark APPLIED status
inline with dated measured-impact notes.
