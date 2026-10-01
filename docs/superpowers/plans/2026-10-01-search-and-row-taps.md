# EvanTube search and full-row taps

Approved scope: fix unusable search and make song/playlist rows tappable across their full content area. No Android work.

Confirmed causes: InnerTube rejects empty source keys before HTTP; library plain NavigationLinks omit the empty Spacer from their hit shape. Songs already have a rectangular hit shape, but their width and playlist row padding need consistent treatment.

1. Reproduce the missing-key library search and blank-space playlist tap with native regression tests before changing behavior.
2. Search the persisted library without credentials, explicitly label library versus online results, and retain valid song IDs. Support public video search through the owner's YouTube Data API v3 key, stored in the iOS Keychain. Do not use that key as an InnerTube key or playback authorization. Show clear errors for absent/invalid/exhausted keys.
3. Add a Traditional Chinese settings page to enter/remove the key and link official setup instructions. Limit the official search scope to videos; preserve existing source support when configured.
4. Add full-width rectangular label hit shapes to library and song rows; preserve menus, selection and download controls. Validate real blank-space taps and control isolation.
5. Run the existing regression suite and native UI checks, inspect screenshots, and deliver the next unsigned IPA with explicit online configuration limits.
