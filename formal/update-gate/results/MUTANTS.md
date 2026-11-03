| Property | Exact-property failing mutant configs |
| --- | --- |
| BootstrapExclusiveCreate | MutantReplace |
| BootstrapOnlyQuiescent | MutantLive |
| BootstrapOpenGenerationZero | MutantGeneration |
| BootstrapPreservesEvidence | MutantEvidence |
| FreshInstallCompletes | OldNoBootstrap |
| HealthyQuitCompletes | QuitOld |
| LeasedUpdateReopensAdmission | CompleteOld |
| NeverProceedOnReusedOrCompetitor | QuitMutantReuse |
| NeverProceedWithoutHeldLease | QuitMutantHeld |
| NeverReopenUnverified | CompleteMutantSha, CompleteMutantOwner |
| UpgradeControllerOwnsStartup | MutantUpgradeController |
| VoiceBarRunningAfterUpgrade | UpgradeOld, MutantMissingTarget |
