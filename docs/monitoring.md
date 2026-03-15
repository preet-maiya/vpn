# Monitoring & Debugging

## Log Analytics Sample Queries

- VM boot/eviction events
```
AzureActivity
| where ResourceProviderValue == "MICROSOFT.COMPUTE"
| where OperationNameValue has "evict" or OperationNameValue has "deallocate"
| project TimeGenerated, OperationNameValue, Resource, ResultType, Caller
```

- Function failures
```
AppTraces
| where _ResourceId has "ts-exit" and SeverityLevel >= 3
| project TimeGenerated, Message, CustomDimensions
```

- Activity endpoint reachability
```
AppRequests
| where Name contains "shutdown-vm"
| summarize count() by bin(TimeGenerated, 1h), tostring(ResultCode)
```

## Alerts
- Budget: $10/month (subscription scope)
- Add optional action groups for email/SMS if desired.

## Dashboards
- Use Azure Monitor VM Insights for CPU/memory.
- Add workbook showing idle duration: `now() - todatetime(last_activity_timestamp)` from custom logs if ingested.
