package contract_test

// Mutation checks (T022). Each mutation was applied to the implementation by hand, the named test(s)
// were observed to FAIL, and the mutation was reverted (results recorded in the task report).
//
//	mutation                                                     caught by
//	---------------------------------------------------------    ------------------------------------------------
//	request.go: drop the `> HostedMaxOptions` (255) -> 400 cap   TestMoreThan255Options400, inventory EP-015b
//	prompt.go: remove the `===` -> `= = =` escaping               TestForgedOptionLinesNeutralised, TestNeutraliseStateCases
//	request.go: drop the allow-list of question/top-level keys    TestRejections422 (extra fields), inventory EP-018
//	request.go: duplicate-key rejection removed                   TestRejections400 (duplicate keys)
//	response.go: tolerance 1e-6 -> 1e-3                           TestBadProbabilitiesRejected
//	readout.go: `mass < threshold` -> `mass <= threshold`        readout TestExactThresholdPasses
//	readout.go: sum over spellings -> first spelling only        readout TestSumOverSpellings
//	readout.go: missing letter reported as 0 without flag        readout TestMissingLetterFlaggedWithUpperBound
