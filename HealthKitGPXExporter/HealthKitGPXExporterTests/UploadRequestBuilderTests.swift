import Testing
import Foundation
@testable import HealthKitGPXExporter

@MainActor
struct UploadRequestBuilderTests {
    private let gpx = Data("<gpx>ride</gpx>".utf8)

    @Test(arguments: [
        ("https://spark.example.ts.net:8420", "https://spark.example.ts.net:8420/api/v1/rides/gpx"),
        ("https://spark.example.ts.net:8420/", "https://spark.example.ts.net:8420/api/v1/rides/gpx"),
        ("  https://spark.example.ts.net:8420//  ", "https://spark.example.ts.net:8420/api/v1/rides/gpx"),
        ("https://host.example/bike", "https://host.example/bike/api/v1/rides/gpx"),
        ("https://host.example/bike/?q=1#frag", "https://host.example/bike/api/v1/rides/gpx")
    ])
    func endpointURLAppendsTheRidesPath(serverURL: String, expected: String) throws {
        let url = try UploadRequestBuilder.endpointURL(serverURL: serverURL)
        #expect(url.absoluteString == expected)
    }

    @Test func plainHTTPIsRejected() {
        #expect(throws: UploadRequestError.insecureScheme) {
            try UploadRequestBuilder.endpointURL(serverURL: "http://spark.example.ts.net:8420")
        }
    }

    @Test(arguments: ["", "   ", "spark.example.ts.net", "https://"])
    func urlWithoutHostIsRejected(serverURL: String) {
        #expect(throws: UploadRequestError.invalidServerURL) {
            try UploadRequestBuilder.endpointURL(serverURL: serverURL)
        }
    }

    @Test func requestHasMethodHeadersAndBearerToken() throws {
        let upload = try UploadRequestBuilder.makeRequest(
            serverURL: "https://spark.example.ts.net:8420",
            bearerToken: " secret-token\n",
            filename: "workout_2026-09-30_120600.gpx",
            gpxData: gpx,
            boundary: "Boundary-TEST"
        )

        #expect(upload.request.httpMethod == "POST")
        #expect(upload.request.url?.absoluteString == "https://spark.example.ts.net:8420/api/v1/rides/gpx")
        #expect(upload.request.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=Boundary-TEST")
        #expect(upload.request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")
        #expect(upload.request.httpBody == nil)
    }

    @Test(arguments: [nil, "", "   "] as [String?])
    func missingOrBlankTokenSendsNoAuthorizationHeader(token: String?) throws {
        let upload = try UploadRequestBuilder.makeRequest(
            serverURL: "https://spark.example.ts.net:8420",
            bearerToken: token,
            filename: "a.gpx",
            gpxData: gpx,
            boundary: "B"
        )
        #expect(upload.request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func multipartBodyIsExact() throws {
        let upload = try UploadRequestBuilder.makeRequest(
            serverURL: "https://spark.example.ts.net:8420",
            bearerToken: nil,
            filename: "workout_2026-09-30_120600.gpx",
            gpxData: gpx,
            boundary: "Boundary-TEST"
        )

        let expected = "--Boundary-TEST\r\n"
            + "Content-Disposition: form-data; name=\"gpx\"; filename=\"workout_2026-09-30_120600.gpx\"\r\n"
            + "Content-Type: application/gpx+xml\r\n"
            + "\r\n"
            + "<gpx>ride</gpx>\r\n"
            + "--Boundary-TEST--\r\n"
        #expect(String(decoding: upload.body, as: UTF8.self) == expected)
    }

    @Test func filenameCannotBreakOutOfItsQuotedParameter() throws {
        let upload = try UploadRequestBuilder.makeRequest(
            serverURL: "https://spark.example.ts.net:8420",
            bearerToken: nil,
            filename: "evil\"\r\nX-Injected: 1.gpx",
            gpxData: gpx,
            boundary: "B"
        )
        let body = String(decoding: upload.body, as: UTF8.self)

        #expect(body.contains("filename=\"evil%22%0D%0AX-Injected: 1.gpx\"\r\n"))
        #expect(!body.contains("\r\nX-Injected"))
    }
}
