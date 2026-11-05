| Property | Exact-property failing mutant configs |
| --- | --- |
| BootstrapExclusiveCreate | MutantReplace |
| BootstrapOnlyQuiescent | MutantLive |
| BootstrapOpenGenerationZero | MutantGeneration |
| BootstrapPreservesEvidence | MutantEvidence |
| EventuallyOpenAfterAbandonedLease | RecoveryOld |
| FreshInstallCompletes | OldNoBootstrap |
| HealthyQuitCompletes | QuitOld |
| LeasedUpdateReopensAdmission | CompleteOld, CompleteSlowOneShot |
| NeverProceedOnReusedOrCompetitor | QuitMutantReuse |
| NeverProceedWithoutHeldLease | QuitMutantHeld |
| NeverRecoverLiveController | RecoveryMutantLive |
| NeverReopenUnverified | CompleteMutantSha, CompleteMutantOwner |
| RecoveryOnlyVerified | RecoveryMutantTarget |
| UpgradeControllerOwnsStartup | MutantUpgradeController |
| VoiceBarRunningAfterUpgrade | UpgradeOld, MutantMissingTarget |
