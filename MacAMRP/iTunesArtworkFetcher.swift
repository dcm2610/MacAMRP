//
//  iTunesArtworkFetcher.swift
//  MacAMRP
//
//  Fetches album artwork URLs from the iTunes Search API.
//  Uses in-memory caching to avoid redundant network requests.
//

import Foundation

final class iTunesArtworkFetcher {
    // Cache: "artist - album" -> artwork URL string
    private var cache: [String: String] = [:]
    private var inFlight: [String: [(String?) -> Void]] = [:]

    // Returns a high-res 600x600 artwork URL (iTunes default is 100x100)
    func fetchArtworkURL(track: String, artist: String, album: String) async -> String? {
        let cacheKey = "\(artist) - \(album)".lowercased()

        if let cached = cache[cacheKey] {
            return cached
        }

        // Build search query - prefer "artist album" for accuracy
        let query = album.isEmpty ? "\(artist) \(track)" : "\(artist) \(album)"
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }

        let urlString = "https://itunes.apple.com/search?term=\(encoded)&media=music&entity=album&limit=5"
        guard let url = URL(string: urlString) else { return nil }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]] else {
                return nil
            }

            // Find the best matching result
            let artworkURL = findBestMatch(results: results, artist: artist, album: album)
            if let url = artworkURL {
                cache[cacheKey] = url
            }
            return artworkURL
        } catch {
            return nil
        }
    }

    private func findBestMatch(results: [[String: Any]], artist: String, album: String) -> String? {
        // Try exact album match first, then fall back to first result
        let normalizedAlbum = album.lowercased()
        let normalizedArtist = artist.lowercased()

        let exactMatch = results.first { result in
            let resultAlbum = (result["collectionName"] as? String ?? "").lowercased()
            let resultArtist = (result["artistName"] as? String ?? "").lowercased()
            return resultAlbum.contains(normalizedAlbum) || resultArtist.contains(normalizedArtist)
        }

        let result = exactMatch ?? results.first
        guard let artworkURL = result?["artworkUrl100"] as? String else { return nil }

        // Replace 100x100 thumbnail with higher-res version (600x600)
        return artworkURL.replacingOccurrences(of: "100x100bb", with: "600x600bb")
    }
}
