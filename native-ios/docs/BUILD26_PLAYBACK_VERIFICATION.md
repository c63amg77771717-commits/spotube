# EvanTube iOS Build 26 playback verification

## Scope

Commit `861d81b2abe3dede7d824d290a1497524ea7eb89` preserves YouTube player response status alongside the response reason. The presentation model now treats `verificationRequired` / `LOGIN_REQUIRED` as authentication or verification failures rather than assuming a single song is invalid. It also recognizes `sourceNotConfigured` explicitly.

## Required gates

1. Run the existing `EvanTubeSourceReplacementTests` synthetic suite: exactly **17** XCTest cases, no live provider queries.
2. Run the existing `EvanTubePublicTests` lyric regression suite: exactly **16** XCTest cases.
3. Keep the synthetic input-lock and privacy checks passing.
4. Only after all validation gates pass, attempt the gated credential-free **unsigned** arm64 Build 26 IPA.
5. Verify the unsigned IPA manifest and archive integrity. A produced IPA does not imply signing, device installation or real YouTube playback success.

## Device validation remaining

Re-test Build 24 diagnostic examples after a correctly configured Build 26 installation:
- `s-ANFN9yJ1s`: `LOGIN_REQUIRED` / `verificationRequired`.
- `04cHqPMD4So`: source rejected after repeat attempts.
- Validate that these service-wide failures halt unintended song retries and automatic queue advancement.

An HTTP 200 response with `LOGIN_REQUIRED` and zero stream formats is **not** a successful audio stream. Do not bypass YouTube verification, fabricate credentials, or convert a global authentication issue into a per-song source replacement.
