import Foundation
import XCTest
@testable import LovelyMusic

final class Build20LyricsTests: XCTestCase {
    func testOrdinaryGet404FallsBackToSearchWithOriginalIdentity() async throws {
        let f = Build20Transport { request in
            request.url!.lastPathComponent == "search" ? .json([Self.primary()]) : .status(404)
        }
        defer { f.close() }
        let result = try await LrcLibService(session: f.session, defaults: f.defaults).getLyrics(context: context())
        XCTAssertEqual(result?.lines.first?.text, "Fixture lyric")
        XCTAssertEqual(result?.selectionKey, "song:video000001")
        XCTAssertEqual(f.requests.map { $0.url!.lastPathComponent }, ["get", "get", "search"])
    }

    func testGetIdentityMismatchSearchesAndNeverDisplaysWrongSinger() async throws {
        let f = Build20Transport { request in
            if request.url!.lastPathComponent == "search" { return .json([Self.primary()]) }
            var wrong = Self.primary(); wrong["artistName"] = "Different performer"
            return .json(wrong)
        }
        defer { f.close() }
        let result = try await LrcLibService(session: f.session, defaults: f.defaults).getLyrics(context: context())
        XCTAssertEqual(result?.candidates.map(\.artist), ["Fixture performer"])
        XCTAssertEqual(result?.lines.first?.text, "Fixture lyric")
        XCTAssertEqual(f.requests.last?.url?.lastPathComponent, "search")
    }

    func testSecondaryUsesCommonAliasAndScriptScoringWithoutExactStringPrefilter() async throws {
        let f = Build20Transport { _ in .json([
            ["id": "jay-1", "title": "晴天", "artist": "Jay Chou", "duration": 200, "lrc": "[00:01.00]晴天歌詞"],
            ["id": "wrong", "title": "晴天", "artist": "Different performer", "duration": 200, "lyrics": "Wrong singer"]
        ]) }
        defer { f.close() }
        let c = context(title: "晴天", artist: "周杰倫")
        let result = try await LrcApiService(session: f.session, defaults: f.defaults).getLyrics(context: c)
        XCTAssertEqual(result?.candidates.map(\.recordID), ["jay-1"])
        XCTAssertEqual(result?.lines.first?.text, "晴天歌詞")
        XCTAssertEqual(f.requests.count, 1)
    }

    func testCollaborationsNormalizeFeatSeparatorsAndRetainPrimaryPerformer() throws {
        let metadata = try XCTUnwrap(LyricsCanonicalMetadata(context(artist: "Artist A feat. Artist B")))
        XCTAssertNotNil(LyricsCandidateScorer.score(candidate(artist: "Artist A & Artist B"), metadata: metadata))
        XCTAssertNil(LyricsCandidateScorer.score(candidate(artist: "Artist B & Artist A"), metadata: metadata))
        XCTAssertNil(LyricsCandidateScorer.score(candidate(artist: "Artist A & Artist C"), metadata: metadata))
        let incomplete = try XCTUnwrap(LyricsCandidateScorer.choose([candidate(artist: "Artist A")], metadata: metadata, defaults: isolatedDefaults()))
        XCTAssertTrue(incomplete.lines.isEmpty)
        XCTAssertEqual(incomplete.candidates.count, 1)
    }

    func testEveryVersionTagSurvivesNoiseRemovalAndRejectsStudioRecording() throws {
        for version in ["Live", "Remix", "Acoustic", "Cover", "Instrumental", "Karaoke", "Demo", "Remastered",
                        "Sped Up", "Slowed", "Nightcore", "Radio Edit", "Extended", "Original Mix", "Edit", "Version", "Live Session", "Concert"] {
            let metadata = try XCTUnwrap(LyricsCanonicalMetadata(context(title: "Fixture song (\(version)) (Official Video) [4K]", video: true)))
            XCTAssertTrue(metadata.pair.title.contains(version))
            XCTAssertFalse(metadata.versionTags.isEmpty, version)
            XCTAssertNil(LyricsCandidateScorer.score(candidate(), metadata: metadata), version)
            XCTAssertNotNil(LyricsCandidateScorer.score(candidate(title: "Fixture song (\(version))"), metadata: metadata), version)
        }
    }

    func testOnlyPurePresentationLabelsAreRemoved() {
        XCTAssertEqual(LyricsCanonicalMetadata.presentationTitle("Song (Official Video) [HD] Visualizer"), "Song")
        for title in ["Song (Live Official MV)", "Song [Remix Lyric Video]", "Song Unofficial Music Video", "Song HD Remix"] {
            XCTAssertEqual(LyricsCanonicalMetadata.presentationTitle(title), title)
        }
    }

    func testDurationMismatchRetainsIdentityButDowngradesAllTimestampsToPlain() async throws {
        let f = Build20Transport { request in
            var record = Self.primary(); record["duration"] = 230
            return .json(request.url!.lastPathComponent == "search" ? [record] : record)
        }
        defer { f.close() }
        let result = try await LrcLibService(session: f.session, defaults: f.defaults).getLyrics(context: context())
        XCTAssertEqual(result?.lines.map(\.text), ["Fixture lyric"])
        XCTAssertEqual(result?.isTimeSynced, false)
        XCTAssertTrue(result?.lines.allSatisfy { $0.time == 0 } ?? false)
    }

    func testCloseScoresRequireManualChoiceAndAlbumCanIdentifyUniqueHighCandidate() throws {
        let defaults = isolatedDefaults()
        let metadata = try XCTUnwrap(LyricsCanonicalMetadata(context(album: "Original Album")))
        let first = candidate(id: "1", duration: 200)
        let close = candidate(id: "2", duration: 205)
        let manual = try XCTUnwrap(LyricsCandidateScorer.choose([first, close], metadata: metadata, defaults: defaults))
        XCTAssertTrue(manual.lines.isEmpty)
        XCTAssertEqual(manual.candidates.count, 2)
        let album = candidate(id: "2", duration: 200, album: "Original Album")
        let unique = try XCTUnwrap(LyricsCandidateScorer.choose([first, album], metadata: metadata, defaults: defaults))
        XCTAssertEqual(unique.lines.first?.text, "Record 2")
    }

    func testSelectionsBelongToSongIDAcrossMetadataChangesAndDoNotLeakToAnotherVideo() throws {
        let defaults = isolatedDefaults()
        let a = context(id: "video000001")
        let b = context(id: "video000002")
        let records = [candidate(id: "1"), candidate(id: "2")]
        LyricsSelectionStore.select(records[1].id, for: a.selectionKey, defaults: defaults)
        let changed = context(id: a.songID!, duration: 205)
        let restored = try XCTUnwrap(LyricsCandidateScorer.choose(records, metadata: XCTUnwrap(LyricsCanonicalMetadata(changed)), defaults: defaults))
        XCTAssertEqual(restored.lines.first?.text, "Record 2")
        let other = try XCTUnwrap(LyricsCandidateScorer.choose(records, metadata: XCTUnwrap(LyricsCanonicalMetadata(b)), defaults: defaults))
        XCTAssertTrue(other.lines.isEmpty)
        XCTAssertNil(LyricsSelectionStore.selectedRecord(for: b.selectionKey, defaults: defaults))
    }

    func testLegacyChoiceMigratesOnlyAfterRecordPassesIdentityValidation() throws {
        let defaults = isolatedDefaults()
        let c = context()
        let selected = candidate(id: "2")
        LyricsSelectionStore.select(selected.id, for: c.legacySelectionKey, defaults: defaults)
        let metadata = try XCTUnwrap(LyricsCanonicalMetadata(c))
        XCTAssertNil(LyricsCandidateScorer.choose([candidate(id: "2", artist: "Wrong singer")], metadata: metadata, defaults: defaults))
        XCTAssertNil(LyricsSelectionStore.selectedRecord(for: c.selectionKey, defaults: defaults))
        _ = LyricsCandidateScorer.choose([selected], metadata: metadata, defaults: defaults)
        XCTAssertEqual(LyricsSelectionStore.selectedRecord(for: c.selectionKey, defaults: defaults), selected.id)
    }

    func testRememberedLRCLibRecordIsRevalidatedByIDBeforeAnyMetadataSearch() async throws {
        let f = Build20Transport { _ in .json(Self.primary()) }
        defer { f.close() }
        let c = context()
        LyricsSelectionStore.select(.init(providerID: .lrclib, recordID: "1"), for: c.selectionKey, defaults: f.defaults)
        let result = try await LrcLibService(session: f.session, defaults: f.defaults).getLyrics(context: c)
        XCTAssertEqual(result?.lines.first?.text, "Fixture lyric")
        XCTAssertEqual(f.requests.count, 1)
        XCTAssertEqual(f.requests.first?.url?.path, "/api/get/1")
    }

    func testInvalidRememberedRecordFallsBackToBoundedMetadataLookup() async throws {
        let f = Build20Transport { request in
            var record = Self.primary()
            if request.url!.lastPathComponent == "9" { record["id"] = 9; record["artistName"] = "Wrong singer" }
            return .json(record)
        }
        defer { f.close() }
        let c = context()
        LyricsSelectionStore.select(.init(providerID: .lrclib, recordID: "9"), for: c.selectionKey, defaults: f.defaults)
        let result = try await LrcLibService(session: f.session, defaults: f.defaults).getLyrics(context: c)
        XCTAssertEqual(result?.candidates.first?.recordID, "1")
        XCTAssertEqual(f.requests.count, 2)
    }

    func testSecondaryDisabledMakesNoSecondaryRequestAndRetainsStoredChoice() async throws {
        let f = Build20Transport { _ in .status(404) }
        defer { f.close() }
        f.defaults.set(false, forKey: LyricsSecondarySettings.enabledKey)
        let c = context()
        let saved = LyricsRecordID(providerID: .lrcapi, recordID: "saved")
        LyricsSelectionStore.select(saved, for: c.selectionKey, defaults: f.defaults)
        let repository = CompositeLyricsRepository(primary: LrcLibService(session: f.session, defaults: f.defaults),
            secondary: LrcApiService(session: f.session, defaults: f.defaults), defaults: f.defaults)
        let result = try await repository.getLyrics(context: c)
        XCTAssertNil(result)
        XCTAssertFalse(f.requests.contains { $0.url?.host == "api.lrc.cx" })
        XCTAssertEqual(LyricsSelectionStore.selectedRecord(for: c.selectionKey, defaults: f.defaults), saved)
    }

    func testSongContextCarriesAlbumIDsOriginAndVideoTypeWithoutMutatingSong() async throws {
        var song = Song(id: "video000001", title: "Original title", artistName: "Original artist", artistId: "artistID",
                        albumName: "Original album", albumId: "albumID", duration: 200, thumbnailURL: nil)
        song.musicVideoType = "MUSIC_VIDEO_TYPE_OMV"
        let spy = Build20ContextSpy()
        _ = try await GetLyricsUseCase(repository: spy).execute(song: song)
        XCTAssertEqual(spy.context?.songID, song.id)
        XCTAssertEqual(spy.context?.album, song.albumName)
        XCTAssertEqual(spy.context?.artistID, song.artistId)
        XCTAssertEqual(spy.context?.albumID, song.albumId)
        XCTAssertEqual(spy.context?.musicVideoType, song.musicVideoType)
        XCTAssertEqual(spy.context?.hasYouTubeOrigin, true)
        XCTAssertEqual(song.title, "Original title")
    }

    func testMissingPerformerRequiresManualChoiceAndAmbiguousCreditsNeverGuess() throws {
        let metadata = try XCTUnwrap(LyricsCanonicalMetadata(context(artist: "", video: true)))
        let result = try XCTUnwrap(LyricsCandidateScorer.choose([candidate()], metadata: metadata, defaults: isolatedDefaults()))
        XCTAssertTrue(result.lines.isEmpty)
        XCTAssertEqual(result.candidates.count, 1)
        XCTAssertNil(LyricsCanonicalMetadata(context(artist: "", video: false)))
        XCTAssertNil(LyricsCanonicalMetadata(context(title: "A & B - Song", artist: "", video: true)))
    }

    func testPlannerAndNoResultTransportStayWithinSixMetadataRequests() async throws {
        let c = context(title: "周杰倫 - 晴天 (Official Video)", artist: "周杰倫", video: true)
        let metadata = try XCTUnwrap(LyricsCanonicalMetadata(c))
        let queries = LyricsQueryPlanner.queries(metadata)
        XCTAssertLessThanOrEqual(queries.count, 6)
        XCTAssertTrue(queries.contains { $0.endpoint == "search" })
        XCTAssertTrue(queries.contains { $0.pair.artist == "Jay Chou" })
        let f = Build20Transport { _ in .status(404) }
        defer { f.close() }
        let result = try await LrcLibService(session: f.session, defaults: f.defaults).getLyrics(context: c)
        XCTAssertNil(result)
        XCTAssertEqual(f.requests.count, queries.count)
    }

    func testCancellationStopsFurtherQueriesAndCannotBecomeMissingLyrics() async throws {
        let f = Build20Transport { _ in .failure(.cancelled) }
        defer { f.close() }
        do {
            _ = try await LrcLibService(session: f.session, defaults: f.defaults).getLyrics(context: context())
            XCTFail("Cancellation must propagate")
        } catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        XCTAssertEqual(f.requests.count, 1)
    }

    func testProviderNamespacesRemainDistinctForIdenticalRecordIDs() throws {
        let first = candidate(id: "1")
        let second = candidate(id: "1", provider: .lrcapi)
        let metadata = try XCTUnwrap(LyricsCanonicalMetadata(context()))
        let result = try XCTUnwrap(LyricsCandidateScorer.choose([first, second], metadata: metadata, defaults: isolatedDefaults()))
        XCTAssertEqual(result.candidates.count, 2)
        XCTAssertTrue(result.lines.isEmpty)
    }

    func testVerifiedEmptyArtistUsesExtractedCreditForSecondaryRequest() async throws {
        let f = Build20Transport { _ in .json([
            ["id": "1", "title": "Fixture song", "artist": "Fixture performer", "duration": 200,
             "lrc": "[00:01.00]Extracted credit lyric"]
        ]) }
        defer { f.close() }
        let c = context(title: "Fixture performer - Fixture song (Official Video)", artist: "", video: true)
        let result = try await LrcApiService(session: f.session, defaults: f.defaults).getLyrics(context: c)
        XCTAssertEqual(result?.lines.first?.text, "Extracted credit lyric")
        XCTAssertEqual(f.requests.count, 1)
        let query = try XCTUnwrap(URLComponents(url: XCTUnwrap(f.requests.first?.url), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "title" }?.value, "Fixture song")
        XCTAssertEqual(query.first { $0.name == "artist" }?.value, "Fixture performer")
    }

    func testTraditionalTitleAndPerformerMatchSimplifiedCandidateWithoutChangingOriginalMetadata() async throws {
        let f = Build20Transport { _ in .json([
            ["id": "chinese-1", "title": "后来", "artist": "刘若英", "duration": 200,
             "lrc": "[00:01.00]繁簡相同歌曲"]
        ]) }
        defer { f.close() }
        let c = context(title: "後來", artist: "劉若英")
        let result = try await LrcApiService(session: f.session, defaults: f.defaults).getLyrics(context: c)
        XCTAssertEqual(result?.lines.first?.text, "繁簡相同歌曲")
        XCTAssertEqual(result?.isTimeSynced, true)
        XCTAssertEqual(c.title, "後來")
        XCTAssertEqual(c.artist, "劉若英")
    }

    func testSearchAvailabilityFailurePreservesValidPlainGetWithFailureProvenance() async throws {
        let f = Build20Transport { request in
            if request.url!.lastPathComponent == "search" { return .status(503) }
            var record = Self.primary(); record["duration"] = 230
            return .json(record)
        }
        defer { f.close() }
        let result = try await LrcLibService(session: f.session, defaults: f.defaults).getLyrics(context: context())
        XCTAssertEqual(result?.lines.first?.text, "Fixture lyric")
        XCTAssertEqual(result?.isTimeSynced, false)
        XCTAssertEqual(result?.sourceFailures.first?.providerID, .lrclib)
        XCTAssertEqual(f.requests.count, 4)
    }

    func testTemporaryGetFailureStopsSpellingVariantsAfterBoundedTransportRetry() async throws {
        let f = Build20Transport { _ in .status(503) }
        defer { f.close() }
        do {
            _ = try await LrcLibService(session: f.session, defaults: f.defaults).getLyrics(context: context())
            XCTFail("Temporary availability failure must remain retryable")
        } catch LyricsLookupError.unavailable(let failures) {
            XCTAssertEqual(failures.count, 1)
        }
        XCTAssertEqual(f.requests.count, 2)
        XCTAssertTrue(f.requests.allSatisfy { $0.url?.lastPathComponent == "get" })
    }

    // Full imported title/duration/YouTube context, through the production entry point.
    // Fixture content validates dispatch/identity only; it does not prove public lyrics availability.
    func testEightImportedSongsUseCanonicalQueriesThroughFormalPrimaryContext() async throws {
        for c in importedContexts() {
            let f = Build20Transport { request in
                let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let title = items.first { $0.name == "track_name" }?.value
                let artist = items.first { $0.name == "artist_name" }?.value
                if request.url!.lastPathComponent != "search" { return .status(404) }
                guard title == self.expectedTitle(c), artist == self.expectedArtist(c) else { return .json([]) }
                return .json([self.importedPrimary(c)])
            }
            defer { f.close() }
            let result = try await LrcLibService(session: f.session, defaults: f.defaults).getLyrics(context: c)
            if LyricsCanonicalMetadata(c)?.requiresManualIdentityConfirmation == true {
                XCTAssertTrue(result?.lines.isEmpty ?? false)
                XCTAssertEqual(result?.candidates.first?.lyrics.lines.first?.text, "Context fixture")
            } else { XCTAssertEqual(result?.lines.first?.text, "Context fixture") }
            XCTAssertEqual(result?.selectionKey, "song:" + c.songID!)
            XCTAssertEqual(result?.candidates.first?.lyrics.isTimeSynced, true)
            XCTAssertLessThanOrEqual(f.requests.count, 6)
            XCTAssertEqual(c.title, importedContexts().first { $0.songID == c.songID }?.title)
            XCTAssertEqual(c.artist, "")
        }
    }

    func testEightImportedSongsUseFormalSecondaryContextAndExplicitBilingualCredits() async throws {
        for c in importedContexts() {
            let f = Build20Transport { request in
                let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                guard items.first(where: { $0.name == "title" })?.value == self.expectedTitle(c),
                      items.first(where: { $0.name == "artist" })?.value == self.expectedArtist(c) else { return .json([]) }
                return .json([["id": "7", "title": self.expectedTitle(c), "artist": self.expectedArtist(c),
                    "duration": c.duration!, "lrc": "[00:01.00]Context fixture"]])
            }
            defer { f.close() }
            let result = try await LrcApiService(session: f.session, defaults: f.defaults).getLyrics(context: c)
            if LyricsCanonicalMetadata(c)?.requiresManualIdentityConfirmation == true {
                XCTAssertTrue(result?.lines.isEmpty ?? false)
                XCTAssertEqual(result?.candidates.first?.lyrics.lines.first?.text, "Context fixture")
            } else { XCTAssertEqual(result?.lines.first?.text, "Context fixture") }
            XCTAssertTrue(result?.candidates.allSatisfy { $0.providerID == .lrcapi } ?? false)
            XCTAssertEqual(result?.selectionKey, c.selectionKey)
            XCTAssertLessThanOrEqual(f.requests.count, 6)
        }
    }

    func testImportedDuetRejectsWrongPrimaryGuestExtraGuestAndOtherVersions() async throws {
        let c = importedContexts()[0]
        let f = Build20Transport { request in
            guard request.url!.lastPathComponent == "search" else { return .status(404) }
            var records: [[String: Any]] = []
            for (index, artist) in ["不同主唱 & 陳忻玥", "李杰明 & 不同歌手", "陳忻玥 & 李杰明", "李杰明 & 陳忻玥 & 其他歌手"].enumerated() {
                var record = self.importedPrimary(c, id: index + 10); record["artistName"] = artist; records.append(record)
            }
            for (index, version) in ["Live", "Cover"].enumerated() {
                var record = self.importedPrimary(c, id: index + 20); record["trackName"] = "I'm Alive (\(version))"; records.append(record)
            }
            records.append(self.importedPrimary(c))
            return .json(records)
        }
        defer { f.close() }
        let result = try await LrcLibService(session: f.session, defaults: f.defaults).getLyrics(context: c)
        XCTAssertEqual(result?.candidates.map(\.recordID), ["7"])
        XCTAssertEqual(result?.lines.first?.text, "Context fixture")
    }

    func testImportedDuetIncompleteCreditsRemainManualAndAsciiXDoesNotSplitNames() async throws {
        let c = importedContexts()[0]
        let f = Build20Transport { request in
            var record = self.importedPrimary(c); record["artistName"] = "李杰明"
            return request.url!.lastPathComponent == "search" ? .json([record]) : .status(404)
        }
        defer { f.close() }
        let response = try await LrcLibService(session: f.session, defaults: f.defaults).getLyrics(context: c)
        let result = try XCTUnwrap(response)
        XCTAssertTrue(result.lines.isEmpty)
        XCTAssertEqual(result.candidates.count, 1)
        for artist in ["Alex", "X Japan", "Lil Nas X", "Space X Agency"] { XCTAssertEqual(LyricsCanonicalMetadata.tokens(artist).count, 1) }
        XCTAssertEqual(LyricsCanonicalMetadata.tokens("Artist A x Artist B").count, 2)
        let verified = try XCTUnwrap(LyricsCanonicalMetadata(c))
        XCTAssertNotNil(LyricsCandidateScorer.score(candidate(title: "I'm Alive", artist: "W.M.L & Vicky Chen", duration: 185), metadata: verified))
        XCTAssertNil(LyricsCandidateScorer.score(candidate(title: "I'm Alive", artist: "W.M.L & Other Guest", duration: 185), metadata: verified))
        let ordinary = LyricsLookupContext(title: "I'm Alive", artist: "李杰明 W.M.L x 陳忻玥 Vicky Chen", duration: 185)
        let metadata = try XCTUnwrap(LyricsCanonicalMetadata(ordinary))
        XCTAssertNil(LyricsCandidateScorer.score(candidate(title: "I'm Alive", artist: "李杰明 & 陳忻玥", duration: 185), metadata: metadata))
    }

    func testEightImportedDurationMismatchesBecomePlainAndCuojiScriptMatches() async throws {
        for c in importedContexts() {
            let f = Build20Transport { request in
                var record = self.importedPrimary(c)
                if c.songID == "zZmtt5g4tHs" { record["trackName"] = "错季" }
                record["duration"] = c.duration! + 56
                return request.url!.lastPathComponent == "search" ? .json([record]) : .status(404)
            }
            defer { f.close() }
            let result = try await LrcLibService(session: f.session, defaults: f.defaults).getLyrics(context: c)
            XCTAssertEqual(result?.candidates.first?.lyrics.lines.first?.text, "Context fixture")
            XCTAssertEqual(result?.isTimeSynced, false)
            XCTAssertTrue(result?.candidates.allSatisfy { $0.lyrics.lines.allSatisfy { $0.time == 0 } } ?? false)
        }
        for title in ["秋原依 - 錯季【Live 動態歌詞】「片段」♪", "秋原依 - 錯季 (Cover)【動態歌詞】「片段」♪",
                      "秋原依 - 錯季「片段」♪"] {
            let version = LyricsLookupContext(title: title, artist: "", duration: 274, hasYouTubeOrigin: true)
            if let metadata = LyricsCanonicalMetadata(version) {
                XCTAssertNil(LyricsCandidateScorer.score(candidate(title: "錯季", artist: "秋原依", duration: 274), metadata: metadata))
            }
        }
    }

    func testEightImportedContextsPropagateCancellationWithoutFurtherQueries() async throws {
        for c in importedContexts() {
            let f = Build20Transport { _ in .failure(.cancelled) }
            defer { f.close() }
            do {
                _ = try await CompositeLyricsRepository(primary: LrcLibService(session: f.session, defaults: f.defaults),
                    secondary: LrcApiService(session: f.session, defaults: f.defaults), defaults: f.defaults).getLyrics(context: c)
                XCTFail("Cancellation must propagate")
            } catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
            XCTAssertEqual(f.requests.count, 1)
        }
    }

    func testImportedManualMappingIsRevalidatedBySongIDAndProviderAfterDurationChange() async throws {
        for c in importedContexts() {
            for provider in [LyricsProviderID.lrclib, .lrcapi] {
                let f = Build20Transport { request in
                    if provider == .lrclib {
                        if request.url!.lastPathComponent == "8" { return .json(self.importedPrimary(c, id: 8)) }
                        return request.url!.lastPathComponent == "search" ? .json([self.importedPrimary(c), self.importedPrimary(c, id: 8)]) : .status(404)
                    }
                    return .json([7, 8].map { ["id": String($0), "title": self.expectedTitle(c), "artist": self.expectedArtist(c),
                        "duration": c.duration!, "lrc": "[00:01.00]Context fixture"] as [String: Any] })
                }
                defer { f.close() }
                let repository: LyricsRepositoryProtocol = provider == .lrclib
                    ? LrcLibService(session: f.session, defaults: f.defaults)
                    : LrcApiService(session: f.session, defaults: f.defaults)
                let response = try await repository.getLyrics(context: c)
                let initial = try XCTUnwrap(response)
                XCTAssertTrue(initial.lines.isEmpty)
                XCTAssertEqual(initial.candidates.count, 2)
                LyricsSelectionStore.select(.init(providerID: provider, recordID: "8"), for: c.selectionKey, defaults: f.defaults)
                let changed = LyricsLookupContext(songID: c.songID, title: c.title, artist: c.artist,
                    duration: c.duration! - 1, hasYouTubeOrigin: true, musicVideoType: c.musicVideoType)
                let result = try await repository.getLyrics(context: changed)
                XCTAssertEqual(result?.lines.first?.text, "Context fixture")
                XCTAssertEqual(result?.providerID, provider)
                XCTAssertEqual(result?.selectionKey, c.selectionKey)
                XCTAssertEqual(LyricsSelectionStore.selectedRecord(for: c.selectionKey, defaults: f.defaults)?.recordID, "8")
                XCTAssertNil(LyricsSelectionStore.selectedRecord(for: "song:another-video", defaults: f.defaults))
            }
        }
    }

    func testImportedSongTitleAndArtistRemainUnchangedThroughUseCase() async throws {
        for c in importedContexts() {
            let f = Build20Transport { request in
                request.url!.lastPathComponent == "search" ? .json([self.importedPrimary(c)]) : .status(404)
            }
            defer { f.close() }
            let song = Song(id: c.songID!, title: c.title, artistName: "原始匯入藝人", artistId: "original-artist-id",
                albumName: "原始專輯", albumId: "original-album-id", duration: c.duration!, thumbnailURL: nil)
            let repository = LrcLibService(session: f.session, defaults: f.defaults)
            let result = try await GetLyricsUseCase(repository: repository).execute(song: song)
            XCTAssertEqual(result?.candidates.first?.lyrics.lines.first?.text, "Context fixture")
            XCTAssertEqual(song.title, c.title)
            XCTAssertEqual(song.artistName, "原始匯入藝人")
            XCTAssertEqual(song.artistId, "original-artist-id")
            XCTAssertEqual(song.albumName, "原始專輯")
            XCTAssertEqual(song.albumId, "original-album-id")
            XCTAssertEqual(song.duration, c.duration)
        }
    }

    func testFormalQuotedSongTitleSurvivesRecognizedPresentationLabel() throws {
        let c = LyricsLookupContext(songID: "quoted00001", title: "秋原依 - 「正式歌名」【動態歌詞】", artist: "原始艺人",
                                    duration: 274, hasYouTubeOrigin: true)
        let metadata = try XCTUnwrap(LyricsCanonicalMetadata(c))
        XCTAssertEqual(metadata.pair.title, "「正式歌名」")
        XCTAssertEqual(c.title, "秋原依 - 「正式歌名」【動態歌詞】")
        XCTAssertEqual(c.artist, "原始艺人")
    }

    func testThirdImportedTitleFirstOrderUsesSuppliedPerformerAndRejectsSwappedIdentity() throws {
        let original = importedContexts()[2]
        let c = LyricsLookupContext(songID: original.songID, title: original.title, artist: "程響",
                                    duration: 242, hasYouTubeOrigin: true)
        let metadata = try XCTUnwrap(LyricsCanonicalMetadata(c))
        XCTAssertEqual(metadata.pair.title, "故事終章")
        XCTAssertEqual(metadata.pair.artist, "程響")
        XCTAssertNil(metadata.alternateVideoPair)
        XCTAssertNotNil(LyricsCandidateScorer.score(candidate(title: "故事终章", artist: "程响", duration: 243), metadata: metadata))
        XCTAssertNil(LyricsCandidateScorer.score(candidate(title: "程響", artist: "故事終章", duration: 243), metadata: metadata))
        XCTAssertNil(LyricsCandidateScorer.score(candidate(title: "故事終章", artist: "其他主唱", duration: 243), metadata: metadata))
        XCTAssertNil(LyricsCandidateScorer.score(candidate(title: "故事終章 (Live)", artist: "程響", duration: 243), metadata: metadata))
        XCTAssertEqual(c.title, original.title)
        XCTAssertEqual(c.artist, "程響")
    }

    func testThirdImportedAmbiguousOrdersRequireManualChoiceWhenBothAreSupported() async throws {
        let c = importedContexts()[2]
        let f = Build20Transport { request in
            guard request.url!.lastPathComponent == "search" else { return .status(404) }
            var swapped = self.importedPrimary(c, id: 8)
            swapped["trackName"] = "程響"; swapped["artistName"] = "故事終章"
            return .json([self.importedPrimary(c), swapped])
        }
        defer { f.close() }
        let result = try await LrcLibService(session: f.session, defaults: f.defaults).getLyrics(context: c)
        XCTAssertTrue(result?.lines.isEmpty ?? false)
        XCTAssertEqual(result?.candidates.count, 2)
        XCTAssertEqual(result?.selectionKey, c.selectionKey)
    }

    func testThirdImportedWrongSingerSavedRecordCannotOverrideContextIdentity() async throws {
        let original = importedContexts()[2]
        let c = LyricsLookupContext(songID: original.songID, title: original.title, artist: "程響",
                                    duration: 243, hasYouTubeOrigin: true)
        let f = Build20Transport { request in
            if request.url!.lastPathComponent == "8" {
                var wrong = self.importedPrimary(c, id: 8); wrong["artistName"] = "其他主唱"; return .json(wrong)
            }
            return request.url!.lastPathComponent == "search" ? .json([self.importedPrimary(c)]) : .status(404)
        }
        defer { f.close() }
        LyricsSelectionStore.select(.init(providerID: .lrclib, recordID: "8"), for: c.selectionKey, defaults: f.defaults)
        let result = try await LrcLibService(session: f.session, defaults: f.defaults).getLyrics(context: c)
        XCTAssertEqual(result?.candidates.map(\.recordID), ["7"])
        XCTAssertEqual(result?.lines.first?.text, "Context fixture")
        XCTAssertEqual(c.title, original.title)
        XCTAssertEqual(c.artist, "程響")
    }

    func testEightImportedMatrixReportsQueriesAcceptedRejectedAndSelection() async throws {
        for c in importedContexts() {
            let f = Build20Transport { request in
                guard request.url!.lastPathComponent == "search" else { return .status(404) }
                var wrong = self.importedPrimary(c, id: 9); wrong["artistName"] = "Unrelated performer"
                return .json([wrong, self.importedPrimary(c)])
            }
            defer { f.close() }
            let result = try await LrcLibService(session: f.session, defaults: f.defaults).getLyrics(context: c)
            XCTAssertEqual(result?.candidates.first?.lyrics.lines.first?.text, "Context fixture")
            let events = LyricsLookupDiagnostics.shared.events.filter { $0.lookupID == c.diagnosticLookupID }
            XCTAssertTrue(events.contains { $0.phase == .query && $0.endpoint == "search" })
            XCTAssertTrue(events.contains { $0.phase == .candidateDropped && $0.reason == .primaryPerformerMismatch })
            XCTAssertTrue(events.contains { $0.phase == .candidateAccepted && $0.recordID == "7" })
            let expected: LyricsLookupDiagnostics.Reason = LyricsCanonicalMetadata(c)?.requiresManualIdentityConfirmation != true ? .autoSelected : .manualRequired
            XCTAssertTrue(events.contains { $0.phase == .selection && $0.reason == expected })
            XCTAssertEqual(events.filter { $0.phase == .transportAttempt }.count, f.requests.count)
            XCTAssertEqual(c.title, importedContexts().first { $0.songID == c.songID }?.title)
            XCTAssertEqual(c.artist, "")
        }
    }

    func testFormalTraceSeparatesNetworkSchemaCancellationAndRateLimit() async throws {
        for (reply, reason) in [(Build20Reply.failure(.cannotConnectToHost), LyricsLookupDiagnostics.Reason.network),
                               (.json(["unexpected": "shape"]), .schema), (.failure(.cancelled), .cancelled),
                               (.status(429), .rateLimited)] {
            let c = importedContexts()[0]
            let f = Build20Transport { _ in reply }
            defer { f.close() }
            do { _ = try await LrcApiService(session: f.session, defaults: f.defaults).getLyrics(context: c) }
            catch { }
            let events = LyricsLookupDiagnostics.shared.events.filter { $0.lookupID == c.diagnosticLookupID }
            XCTAssertTrue(events.contains { $0.phase == .failure && $0.reason == reason }, String(describing: reason))
            XCTAssertEqual(events.filter { $0.phase == .transportAttempt }.count, f.requests.count)
            XCTAssertFalse(events.contains { $0.reason == .providerEmpty })
        }
    }

    func testFormalTraceSeparatesDecodedEmptyFromHTTP404WithoutClaimingLyricsAbsent() async throws {
        for missingHTTP in [false, true] {
            let c = importedContexts()[0]
            let f = Build20Transport { _ in missingHTTP ? .status(404) : .json([]) }
            defer { f.close() }
            _ = try await LrcApiService(session: f.session, defaults: f.defaults).getLyrics(context: c)
            let events = LyricsLookupDiagnostics.shared.events.filter { $0.lookupID == c.diagnosticLookupID }
            if missingHTTP {
                XCTAssertTrue(events.contains { $0.phase == .response && $0.httpStatus == 404 && $0.reason == .http })
                XCTAssertFalse(events.contains { $0.reason == .providerEmpty })
            } else { XCTAssertTrue(events.contains { $0.phase == .providerEmpty }) }
        }
    }

    func testTraceIsBoundedSanitizedAndExportsNoLyricsBody() throws {
        let ledger = LyricsLookupDiagnostics(capacity: 8)
        let c = importedContexts()[0]
        for _ in 0..<12 {
            ledger.record(.init(context: c, provider: .lrclib, phase: .query, title: String(repeating: "a", count: 500),
                artist: "https://private.example/credential", duration: .nan, recordID: "https://private.example/token"))
        }
        XCTAssertEqual(ledger.events.count, 8)
        XCTAssertEqual(ledger.events.first?.title?.count, 256)
        XCTAssertNil(ledger.events.first?.artist)
        XCTAssertNil(ledger.events.first?.duration)
        XCTAssertNil(ledger.events.first?.recordID)
        XCTAssertTrue(ledger.events.allSatisfy { $0.cacheSource.contains("not-observed") })
        let exported = try JSONEncoder().encode(ledger.events)
        XCTAssertFalse(String(decoding: exported, as: UTF8.self).contains("credential"))
        XCTAssertFalse(String(decoding: exported, as: UTF8.self).contains("Context fixture"))
    }

    func testQuotedSubtitleHypothesisIsRetainedAndShortenedVariantCannotAutoSelect() throws {
        let c = LyricsLookupContext(title: "藝人 - 歌名「正式副標」【動態歌詞】", artist: "藝人", duration: 200, hasYouTubeOrigin: true)
        let metadata = try XCTUnwrap(LyricsCanonicalMetadata(c))
        XCTAssertEqual(metadata.pair.title, "歌名")
        XCTAssertEqual(metadata.quotedVideoPair?.title, "歌名「正式副標」")
        let shortened = try XCTUnwrap(LyricsCandidateScorer.score(candidate(title: "歌名", artist: "藝人"), metadata: metadata))
        XCTAssertLessThan(shortened, 85)
        XCTAssertNotNil(LyricsCandidateScorer.score(candidate(title: "歌名「正式副標」", artist: "藝人"), metadata: metadata))
        XCTAssertEqual(c.title, "藝人 - 歌名「正式副標」【動態歌詞】")
    }

    func testStrongIdentityWithoutAlbumOrDurationIsPlainInsteadOfRejected() throws {
        let source = importedContexts()[0]
        let c = LyricsLookupContext(songID: source.songID, title: source.title, artist: source.artist,
                                    album: nil, duration: nil, hasYouTubeOrigin: true)
        let metadata = try XCTUnwrap(LyricsCanonicalMetadata(c))
        let record = LyricsCandidate(id: .init(providerID: .lrclib, recordID: "known"),
            title: "I'm Alive", artist: "李杰明 & 陳忻玥", duration: nil,
            lyrics: SyncedLyrics(lines: [.init(time: 0, text: "Plain fixture")], source: "LRCLib (plain)",
                                  isTimeSynced: false, providerID: .lrclib))
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(LyricsCandidateScorer.score(record, metadata: metadata)), 85)
        let result = try XCTUnwrap(LyricsCandidateScorer.choose([record], metadata: metadata, defaults: isolatedDefaults()))
        XCTAssertEqual(result.lines.first?.text, "Plain fixture")
        XCTAssertFalse(result.isTimeSynced)
    }

    func testMVLengthCannotChooseBetweenOtherwiseEqualRecordingIdentities() throws {
        let c = importedContexts()[0]
        let metadata = try XCTUnwrap(LyricsCanonicalMetadata(c))
        let a = candidate(id: "1", title: "I'm Alive", artist: "李杰明 & 陳忻玥", duration: 185)
        let b = candidate(id: "2", title: "I'm Alive", artist: "李杰明 & 陳忻玥", duration: 240)
        XCTAssertEqual(LyricsCandidateScorer.score(a, metadata: metadata), LyricsCandidateScorer.score(b, metadata: metadata))
        let result = try XCTUnwrap(LyricsCandidateScorer.choose([a, b], metadata: metadata, defaults: isolatedDefaults()))
        XCTAssertTrue(result.lines.isEmpty)
        XCTAssertEqual(result.candidates.count, 2)
    }

    func testNestedMovieAnnotationRetainsWildAmbitionIdentity() throws {
        let c = importedContexts().first { $0.songID == "oJFEOqekQ7Y" }!
        let metadata = try XCTUnwrap(LyricsCanonicalMetadata(c))
        XCTAssertEqual(metadata.pair.title, "野心")
        XCTAssertEqual(metadata.pair.artist, "薛之謙 Joker Xue")
        XCTAssertEqual(metadata.performerIdentity(LyricsLookupMetadata.identityKey("薛之謙")),
                       metadata.performerIdentity(LyricsLookupMetadata.identityKey(metadata.pair.artist)))
    }

    func testWhitespacePublisherCreditRetainsOriginalEvidenceAndManualConfirmation() throws {
        let c = importedContexts().first { $0.songID == "4RVl7b0X88Y" }!
        let metadata = try XCTUnwrap(LyricsCanonicalMetadata(c))
        XCTAssertEqual(metadata.pair.title, "會痛的石頭")
        XCTAssertEqual(metadata.pair.artist, "蕭敬騰")
        XCTAssertTrue(metadata.requiresManualIdentityConfirmation)
        XCTAssertEqual(c.artist, "")
        XCTAssertEqual(c.title, "蕭敬騰 會痛的石頭-華納official HQ官方版MV")
    }

    private func importedContexts() -> [LyricsLookupContext] {
        [
         .init(songID: "dtVR0oi_N4U", title: "李杰明 W.M.L x 陳忻玥 Vicky Chen【I'm Alive】Official MV", artist: "", album: nil, duration: 185, artistID: nil, albumID: nil, hasYouTubeOrigin: true, musicVideoType: nil),
         .init(songID: "zZmtt5g4tHs", title: "秋原依 - 錯季【動態歌詞】「春的顏色不走進秋季 有些愛情就經不起季節輪替」♪", artist: "", album: nil, duration: 274, artistID: nil, albumID: nil, hasYouTubeOrigin: true, musicVideoType: nil),
         .init(songID: "YghlJ-2nvZU", title: "故事終章 - 程響【動態歌詞】= 有些事我們終生難忘，有些愛深藏於心。只有故事終章，溫暖我們一生。 = Chinese music ~", artist: "", album: nil, duration: 243, artistID: nil, albumID: nil, hasYouTubeOrigin: true, musicVideoType: nil),
         .init(songID: "4RVl7b0X88Y", title: "蕭敬騰 會痛的石頭-華納official HQ官方版MV", artist: "", album: nil, duration: 288, artistID: nil, albumID: nil, hasYouTubeOrigin: true, musicVideoType: nil),
         .init(songID: "VVVVRl_lG1o", title: "張靚穎 - 一生一次心一動【《斛珠夫人》電視劇情感主題曲】【動態歌詞】 = 那幾年沉浮 分離如必經之路 =Chinese music ~", artist: "", album: nil, duration: 305, artistID: nil, albumID: nil, hasYouTubeOrigin: true, musicVideoType: nil),
         .init(songID: "3hw92j4SqrI", title: "ycccc - 不期而遇的美好「你是我不期而遇的美好 是素未謀面時的魂牽夢繞」【動態歌詞/PinyinLyrics】♪", artist: "", album: nil, duration: 203, artistID: nil, albumID: nil, hasYouTubeOrigin: true, musicVideoType: nil),
         .init(songID: "gGLp7ht_2bk", title: "王傑 Dave Wong《我是真的愛上你》[Lyrics MV]", artist: "", album: nil, duration: 315, artistID: nil, albumID: nil, hasYouTubeOrigin: true, musicVideoType: nil),
         .init(songID: "oJFEOqekQ7Y", title: "薛之謙 Joker Xue《野心（電影《緝魂》推廣曲）》Official Music Video", artist: "", album: nil, duration: 217, artistID: nil, albumID: nil, hasYouTubeOrigin: true, musicVideoType: nil)
        ]
    }
    private func expectedTitle(_ c: LyricsLookupContext) -> String {
        switch c.songID {
        case "dtVR0oi_N4U": return "I'm Alive"
        case "zZmtt5g4tHs": return "錯季"
        case "YghlJ-2nvZU": return "故事終章"
        case "4RVl7b0X88Y": return "會痛的石頭"
        case "VVVVRl_lG1o": return "一生一次心一動"
        case "3hw92j4SqrI": return "不期而遇的美好"
        case "gGLp7ht_2bk": return "我是真的愛上你"
        case "oJFEOqekQ7Y": return "野心"
        default: return ""
        }
    }
    private func expectedArtist(_ c: LyricsLookupContext) -> String {
        switch c.songID {
        case "dtVR0oi_N4U": return "李杰明 & 陳忻玥"
        case "zZmtt5g4tHs": return "秋原依"
        case "YghlJ-2nvZU": return "程響"
        case "4RVl7b0X88Y": return "蕭敬騰"
        case "VVVVRl_lG1o": return "張靚穎"
        case "3hw92j4SqrI": return "ycccc"
        case "gGLp7ht_2bk": return "王傑"
        case "oJFEOqekQ7Y": return "薛之謙"
        default: return ""
        }
    }
    private func importedPrimary(_ c: LyricsLookupContext, id: Int = 7) -> [String: Any] {
        ["id": id, "trackName": expectedTitle(c), "artistName": expectedArtist(c), "duration": c.duration!,
         "syncedLyrics": "[00:01.00]Context fixture"]
    }

    private func context(id: String = "video000001", title: String = "Fixture song", artist: String = "Fixture performer",
                         album: String? = nil, duration: Int = 200, video: Bool = false) -> LyricsLookupContext {
        .init(songID: id, title: title, artist: artist, album: album, duration: duration, hasYouTubeOrigin: video)
    }
    private func candidate(id: String = "1", title: String = "Fixture song", artist: String = "Fixture performer",
                           duration: Double = 200, album: String? = nil, provider: LyricsProviderID = .lrclib) -> LyricsCandidate {
        .init(id: .init(providerID: provider, recordID: id), title: title, artist: artist, duration: duration,
              lyrics: SyncedLyrics(lines: [.init(time: 1, text: "Record " + id)], source: provider.displayName, providerID: provider), album: album)
    }
    private func isolatedDefaults() -> UserDefaults {
        let suite = "Build20Lyrics-" + UUID().uuidString
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return UserDefaults(suiteName: suite)!
    }
    private static func primary() -> [String: Any] {
        ["id": 1, "trackName": "Fixture song", "artistName": "Fixture performer", "duration": 200,
         "syncedLyrics": "[00:01.00]Fixture lyric"]
    }
}

private final class Build20ContextSpy: LyricsRepositoryProtocol {
    var context: LyricsLookupContext?
    func getLyrics(context: LyricsLookupContext) async throws -> SyncedLyrics? { self.context = context; return nil }
    func getLyrics(title: String, artist: String, duration: Int?) async throws -> SyncedLyrics? {
        XCTFail("Song lookup must retain context"); return nil
    }
}

private enum Build20Reply { case status(Int), json(Any), failure(URLError.Code) }
private final class Build20Transport {
    let session: URLSession
    let defaults: UserDefaults
    let token = UUID().uuidString
    private let suite = "Build20Transport-" + UUID().uuidString
    var requests: [URLRequest] { Build20URLProtocol.lock.withLock { Build20URLProtocol.requests[token] ?? [] } }
    init(_ handler: @escaping (URLRequest) -> Build20Reply) {
        defaults = UserDefaults(suiteName: suite)!
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Build20URLProtocol.self]
        config.httpAdditionalHeaders = ["X-Build20-Fixture": token]
        session = URLSession(configuration: config)
        Build20URLProtocol.lock.withLock { Build20URLProtocol.handlers[token] = handler }
    }
    func close() {
        session.invalidateAndCancel()
        defaults.removePersistentDomain(forName: suite)
        Build20URLProtocol.lock.withLock {
            Build20URLProtocol.handlers.removeValue(forKey: token)
            Build20URLProtocol.requests.removeValue(forKey: token)
        }
    }
}
private final class Build20URLProtocol: URLProtocol {
    static let lock = NSLock()
    static var handlers: [String: (URLRequest) -> Build20Reply] = [:]
    static var requests: [String: [URLRequest]] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let token = request.value(forHTTPHeaderField: "X-Build20-Fixture") ?? ""
        let handler = Self.lock.withLock { () -> ((URLRequest) -> Build20Reply)? in
            Self.requests[token, default: []].append(request)
            return Self.handlers[token]
        }
        guard let handler else { client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
        let reply = handler(request)
        if case .failure(let code) = reply { client?.urlProtocol(self, didFailWithError: URLError(code)); return }
        let status: Int
        let data: Data
        switch reply {
        case .status(let value): status = value; data = Data()
        case .json(let object): status = 200; data = try! JSONSerialization.data(withJSONObject: object)
        case .failure: return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
