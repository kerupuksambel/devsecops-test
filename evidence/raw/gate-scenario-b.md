### Trivy policy: `trivy-scenario-b.json`
| Critical | High | Medium | Low | Secrets |
|---|---|---|---|---|
| 0 | 2 | 3 | 1 | 0 |

| Finding | Severity | Target | Exception allowed? |
|---|---|---|---|
| AWS-0080 | HIGH | aws_db_instance.main | No: must be fixed (fix available, actively exploited, or misconfiguration) |
| AWS-0180 | HIGH | aws_db_instance.main | No: must be fixed (fix available, actively exploited, or misconfiguration) |
::error::Blocked by policy: 0 critical, 2 high, 0 secret finding(s). See the job summary.
