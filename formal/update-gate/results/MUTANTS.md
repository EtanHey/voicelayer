| Property | Exact-property failing mutant configs |
| --- | --- |
| BootstrapExclusiveCreate | MutantReplace |
| BootstrapOnlyQuiescent | MutantLive |
| BootstrapOpenGenerationZero | MutantGeneration |
| BootstrapPreservesEvidence | MutantEvidence |
| DeadRegistrationsCanPrepare | ReapOld |
| EventuallyOpenAfterAbandonedLease | RecoveryOld |
| FreshInstallCompletes | OldNoBootstrap |
| HealthyQuitCompletes | QuitOld |
| LeasedUpdateReopensAdmission | CompleteOld, CompleteSlowOneShot |
| NeverProceedOnReusedOrCompetitor | QuitMutantReuse |
| NeverProceedWithoutHeldLease | QuitMutantHeld |
| NeverReapLiveOwner | ReapMutantAge, ReapMutantUnknown |
| NeverRecoverLiveController | RecoveryMutantLive |
| NeverReopenUnverified | CompleteMutantSha, CompleteMutantOwner |
| RecoveryOnlyVerified | RecoveryMutantTarget |
| UpgradeControllerOwnsStartup | MutantUpgradeController |
| VoiceBarRunningAfterUpgrade | UpgradeOld, MutantMissingTarget |
