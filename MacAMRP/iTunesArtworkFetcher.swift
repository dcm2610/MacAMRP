//
//  iTunesArtworkFetcher.swift
//  MacAMRP
//
//  Fetches album artwork URLs and track metadata from the iTunes Search API.
//

import Foundation

// MARK: - iTunesArtworkFetcher

final class iTunesArtworkFetcher {
    // Positive cache: key -> artwork URL
    private var urlCache: [String: String] = [:]
    // Negative cache: keys for which every search returned no usable result
    private var missedKeys: Set<String> = []

    // MARK: - Album Artwork

    /// Returns a 600×600 album artwork URL, or nil if nothing is found.
    ///
    /// Strategy (in priority order):
    ///  1. Direct iTunes lookup by Apple Music catalog album ID (from `storeURL`) — exact match
    ///  2. Album text search — good when album metadata is present
    ///  3. Song text search — fallback when album name is absent or album search returns nothing
    func fetchArtworkURL(track: String, artist: String, album: String, storeURL: String? = nil) async -> String? {
        let key = album.isEmpty
            ? "trk:\(artist.lowercased()) - \(track.lowercased())"
            : "alb:\(artist.lowercased()) - \(album.lowercased())"

        if let cached = urlCache[key] { return cached }
        if missedKeys.contains(key)   { return nil    }

        // 1. Direct catalog lookup by album ID — take the first result since the ID is exact.
        if let albumID = extractAlbumID(from: storeURL) {
            let results = await iTunesLookup(id: albumID, entity: "album")
            if let raw = results.first?["artworkUrl100"] as? String {
                let url = raw.replacingOccurrences(of: "100x100bb", with: "600x600bb")
                urlCache[key] = url
                return url
            }
        }

        // 2. Album text search — require a positive relevance score (no blind first-result fallback).
        if !album.isEmpty {
            let results = await iTunesSearch(query: "\(artist) \(album)", entity: "album")
            if let url = pickAlbumArtwork(from: results, artist: artist, album: album) {
                urlCache[key] = url
                return url
            }
        }

        // 3. Song text search — last resort (or primary when album name is unknown).
        let results = await iTunesSearch(query: "\(artist) \(track)", entity: "song")
        if let url = pickSongArtwork(from: results, artist: artist, track: track) {
            urlCache[key] = url
            return url
        }

        missedKeys.insert(key)
        return nil
    }

    // MARK: - Artist Image

    /// Returns a 300×300 artist image URL, or nil if nothing is found.
    func fetchArtistImageURL(artist: String) async -> String? {
        let results = await iTunesSearch(query: artist, entity: "musicArtist")
        let normArtist = artist.lowercased()
        let match = results.first { result in
            let name = (result["artistName"] as? String ?? "").lowercased()
            return name.contains(normArtist) || normArtist.contains(name)
        } ?? results.first

        guard let raw = match?["artworkUrl100"] as? String else { return nil }
        return raw.replacingOccurrences(of: "100x100bb", with: "300x300bb")
    }

    // MARK: - URL Helpers

    /// Extracts the numeric album ID from an Apple Music URL (the last non-query path component).
    /// e.g. "https://music.apple.com/us/album/typhoons/1530743318?i=1530743323" → "1530743318"
    private func extractAlbumID(from storeURL: String?) -> String? {
        guard let storeURL,
              let url = URL(string: storeURL),
              url.host?.hasSuffix("music.apple.com") == true else { return nil }
        let id = url.lastPathComponent
        guard !id.isEmpty, id.allSatisfy({ $0.isNumber }) else { return nil }
        return id
    }

    // MARK: - Network

    /// iTunes lookup API — fetches by ID. Pass `entity` to filter results, or nil for all.
    private func iTunesLookup(id: String, entity: String?) async -> [[String: Any]] {
        var urlString = "https://itunes.apple.com/lookup?id=\(id)&limit=5"
        if let entity { urlString += "&entity=\(entity)" }
        guard let url = URL(string: urlString) else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]] else { return [] }
            return results
        } catch { return [] }
    }

    private func iTunesSearch(query: String, entity: String) async -> [[String: Any]] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/search?term=\(encoded)&media=music&entity=\(entity)&limit=5")
        else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]] else { return [] }
            return results
        } catch { return [] }
    }

    // MARK: - Scoring / Picking

    /// Picks the best album artwork from `entity=album` results using relevance scoring.
    /// Returns nil if no result scores positively — callers should fall through to the next strategy.
    private func pickAlbumArtwork(from results: [[String: Any]], artist: String, album: String) -> String? {
        guard !results.isEmpty else { return nil }
        let normAlbum  = album.lowercased()
        let normArtist = artist.lowercased()

        let scored: [(url: String, score: Int)] = results.compactMap { result in
            guard let raw = result["artworkUrl100"] as? String else { return nil }
            let resAlbum  = (result["collectionName"] as? String ?? "").lowercased()
            let resArtist = (result["artistName"]     as? String ?? "").lowercased()

            var score = 0
            if !normAlbum.isEmpty && !resAlbum.isEmpty {
                if resAlbum == normAlbum                     { score += 4 }
                else if resAlbum.contains(normAlbum)         { score += 2 }
                else if normAlbum.contains(resAlbum)         { score += 1 }
            }
            if !normArtist.isEmpty && !resArtist.isEmpty {
                if resArtist.contains(normArtist) || normArtist.contains(resArtist) { score += 2 }
            }
            return score > 0 ? (raw, score) : nil
        }

        // No blind first-result fallback — require a positive match to avoid returning
        // completely unrelated artwork when the search misfires.
        guard let raw = scored.max(by: { $0.score < $1.score })?.url else { return nil }
        return raw.replacingOccurrences(of: "100x100bb", with: "600x600bb")
    }

    /// Picks the best artwork from `entity=song` results.
    /// Requires both track name and artist to match.
    private func pickSongArtwork(from results: [[String: Any]], artist: String, track: String) -> String? {
        guard !results.isEmpty else { return nil }
        let normTrack  = track.lowercased()
        let normArtist = artist.lowercased()

        let match = results.first { result in
            let resTrack  = (result["trackName"]  as? String ?? "").lowercased()
            let resArtist = (result["artistName"] as? String ?? "").lowercased()
            guard !resTrack.isEmpty, !resArtist.isEmpty else { return false }
            let trackOK  = resTrack.contains(normTrack) || normTrack.contains(resTrack)
            let artistOK = resArtist.contains(normArtist) || normArtist.contains(resArtist)
            return trackOK && artistOK
        }
        guard let raw = match?["artworkUrl100"] as? String else { return nil }
        return raw.replacingOccurrences(of: "100x100bb", with: "600x600bb")
    }
}
