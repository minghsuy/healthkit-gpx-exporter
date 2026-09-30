import Foundation

/// A ready-to-send GPX upload. `body` goes to `URLSession.upload(for:from:)`,
/// which ignores `request.httpBody`.
struct GPXUploadRequest {
    let request: URLRequest
    let body: Data
}

enum UploadRequestError: LocalizedError, Equatable {
    case invalidServerURL
    case insecureScheme

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            return "The server URL is not a valid URL with a host."
        case .insecureScheme:
            return "The server URL must start with https://."
        }
    }
}

/// Builds the multipart POST to `{serverURL}/api/v1/rides/gpx`. Pure Swift,
/// no networking, so it is unit-testable.
struct UploadRequestBuilder {
    static let endpointPath = "/api/v1/rides/gpx"
    static let formFieldName = "gpx"

    /// Only https is accepted: App Transport Security blocks plain http to a
    /// named host anyway, and a bearer token must not travel in the clear.
    static func endpointURL(serverURL: String) throws -> URL {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let host = components.host, !host.isEmpty else {
            throw UploadRequestError.invalidServerURL
        }
        guard components.scheme?.lowercased() == "https" else {
            throw UploadRequestError.insecureScheme
        }

        var path = components.path
        while path.hasSuffix("/") {
            path.removeLast()
        }
        components.path = path + endpointPath
        components.query = nil
        components.fragment = nil

        guard let url = components.url else {
            throw UploadRequestError.invalidServerURL
        }
        return url
    }

    static func makeRequest(
        serverURL: String,
        bearerToken: String?,
        filename: String,
        gpxData: Data,
        boundary: String
    ) throws -> GPXUploadRequest {
        var request = URLRequest(url: try endpointURL(serverURL: serverURL))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let token = bearerToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data(
            "Content-Disposition: form-data; name=\"\(formFieldName)\"; filename=\"\(quotedFilename(filename))\"\r\n".utf8
        ))
        body.append(Data("Content-Type: application/gpx+xml\r\n\r\n".utf8))
        body.append(gpxData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        return GPXUploadRequest(request: request, body: body)
    }

    /// Percent-encodes the characters that would break out of the quoted
    /// filename parameter (the HTML form-data encoding rule).
    static func quotedFilename(_ filename: String) -> String {
        filename
            .replacingOccurrences(of: "\"", with: "%22")
            .replacingOccurrences(of: "\r", with: "%0D")
            .replacingOccurrences(of: "\n", with: "%0A")
    }
}
