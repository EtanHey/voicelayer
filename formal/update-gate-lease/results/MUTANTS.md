| Property | Exact-property failing mutant configs |
| --- | --- |
| AbortedUpdateReleases | LeaseMutantNoCancel |
| LeaseExclusive | LeaseMutantSteal |
| MutationExclusive | LeaseMutantRollback, LeaseMutantCrashReopens |
| NoHealthyExitHoldingLease | LeaseOldExit |
| ReleaseByOwnerOnly | LeaseMutantForeignComplete |
| ReopenOnlyVerified | LeaseMutantNoRecheck |
| VerifiedUpdateReleases | LeaseOld |
