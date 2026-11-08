import Foundation
import UIKit

extension StreamingService {

    // MARK: - Gallery

    /// Returns the absolute URL for a gallery image given its relative path.
    func galleryImageURL(_ relativePath: String, token: String) -> URL? {
        let base = bridgeURL.trimmingCharacters(in: .init(charactersIn: "/"))
        guard let url = URL(string: base + relativePath) else { return nil }
        return url
    }

    /// Fetches the list of cloud-synced gallery images.
    @discardableResult
    func fetchGalleryImages(token: String) async throws -> [GalleryImageInfo] {
        appLog("fetchGalleryImages", category: "network")
        isLoadingGallery = true
        defer { isLoadingGallery = false }

        guard var request = makeRequest("/user/gallery/images") else {
            throw StreamingError.invalidURL
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20

        let (data, response) = try await Core.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw StreamingError.httpError(http.statusCode)
        }

        let images = try JSONDecoder().decode([GalleryImageInfo].self, from: data)
        galleryImages = images
        appLog("fetchGalleryImages: \(images.count) images", category: "network")
        return images
    }

    /// Uploads a UIImage as JPEG to the user's cloud gallery.
    /// Returns the image ID assigned by the server.
    func uploadGalleryImage(_ image: UIImage, token: String, displayOrder: Int = 0) async throws -> String {
        appLog("uploadGalleryImage", category: "network")
        isUploadingGalleryImage = true
        defer { isUploadingGalleryImage = false }

        guard let jpeg = image.jpegData(compressionQuality: 0.85) else {
            throw StreamingError.invalidURL   // reuse invalidURL for encode failure
        }

        let base = bridgeURL.trimmingCharacters(in: .init(charactersIn: "/"))
        guard let url = URL(string: "\(base)/user/gallery/images?display_order=\(displayOrder)") else {
            throw StreamingError.invalidURL
        }

        // Build multipart/form-data body
        let boundary = UUID().uuidString
        var body = Data()
        let crlf = "\r\n"
        body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"gallery.jpg\"\(crlf)".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\(crlf)\(crlf)".data(using: .utf8)!)
        body.append(jpeg)
        body.append("\(crlf)--\(boundary)--\(crlf)".data(using: .utf8)!)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 120

        let (data, response) = try await Core.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw StreamingError.httpError(http.statusCode)
        }

        struct UploadResponse: Decodable { let id: String }
        let decoded = try JSONDecoder().decode(UploadResponse.self, from: data)
        appLog("uploadGalleryImage: uploaded, id=\(decoded.id)", category: "network")

        // Refresh the gallery list
        _ = try? await fetchGalleryImages(token: token)
        return decoded.id
    }

    /// Deletes a gallery image by ID.
    func deleteGalleryImage(id: String, token: String) async throws {
        guard var request = makeRequest("/user/gallery/images/\(id)") else {
            throw StreamingError.invalidURL
        }
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20

        let (_, response) = try await Core.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw StreamingError.httpError(http.statusCode)
        }
        galleryImages.removeAll { $0.id == id }
        appLog("deleteGalleryImage: deleted \(id)", category: "network")
    }

    /// Downloads the actual bytes for a cloud gallery entry. The file-serving endpoint
    /// requires the same per-user bearer token as the listing/upload/delete calls
    /// (it's not a public URL), so this can't be loaded via a plain AsyncImage.
    func fetchGalleryImageData(_ image: GalleryImageInfo, token: String) async -> UIImage? {
        guard var request = makeRequest(image.url) else { return nil }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        guard let (data, response) = try? await Core.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return UIImage(data: data)
    }

    /// The stored bytes of a cloud gallery photo, as uploaded (no decode and
    /// re-encode, so the same photo restores to the same bytes every time).
    /// Logs why a download failed instead of returning nil silently.
    func fetchGalleryImageBytes(_ image: GalleryImageInfo, token: String) async -> Data? {
        guard var request = makeRequest(image.url) else { return nil }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60
        do {
            let (data, response) = try await Core.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200, !data.isEmpty else {
                appWarn("Gallery: cloud photo \(image.id) download returned HTTP \(status)", category: "background")
                return nil
            }
            return data
        } catch {
            appWarn("Gallery: cloud photo \(image.id) download failed: \(error.localizedDescription)", category: "background")
            return nil
        }
    }
}
