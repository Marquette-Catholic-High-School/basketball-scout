import Foundation
import Testing
@testable import BasketballScout

/// The roster import body (05 §4.4; 09 D1 #7: `mode` must be a form field, the filename carries the
/// extension).
nonisolated struct MultipartFormDataTests {
    @Test func exactBytes() {
        var form = MultipartFormData(boundary: "XyZ")
        form.addFile(name: "file", filename: "roster_other.csv", contentType: "text/csv", data: Data("Jersey,Name\r\n5,Test Player 5\r\n".utf8))
        form.addField(name: "mode", value: "replace")
        let expected = "--XyZ\r\n"
            + "Content-Disposition: form-data; name=\"file\"; filename=\"roster_other.csv\"\r\n"
            + "Content-Type: text/csv\r\n"
            + "\r\n"
            + "Jersey,Name\r\n5,Test Player 5\r\n"
            + "\r\n"
            + "--XyZ\r\n"
            + "Content-Disposition: form-data; name=\"mode\"\r\n"
            + "\r\n"
            + "replace\r\n"
            + "--XyZ--\r\n"
        #expect(String(decoding: form.body, as: UTF8.self) == expected)
        #expect(form.contentType == "multipart/form-data; boundary=XyZ")
    }

    @Test func binaryFilesAreKeptByteForByte() {
        let bytes = Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0xFF, 0x0D, 0x0A])
        var form = MultipartFormData(boundary: "b")
        form.addFile(name: "file", filename: "roster.xlsx", contentType: "application/octet-stream", data: bytes)
        #expect(form.body.range(of: bytes) != nil)
    }

    @Test func filenamesAreMadeSafe() {
        #expect(MultipartFormData.quotedParameter(#"a"b.csv"#) == "a%22b.csv")
        #expect(MultipartFormData.quotedParameter("a\r\nb.csv") == "a%0D%0Ab.csv")
        #expect(MultipartFormData.lastPathComponent(#"C:\fakepath\roster.csv"#) == "roster.csv")
        #expect(MultipartFormData.lastPathComponent("dir/sub/roster.tsv") == "roster.tsv")
    }

    @Test func partTypesByExtension() {
        #expect(MultipartFormData.contentType(forFilename: "Roster.CSV") == "text/csv")
        #expect(MultipartFormData.contentType(forFilename: "r.tsv") == "text/tab-separated-values")
        #expect(MultipartFormData.contentType(forFilename: "r.txt") == "text/plain")
        #expect(MultipartFormData.contentType(forFilename: "r.xlsx") == "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
        #expect(MultipartFormData.contentType(forFilename: "r.numbers") == "application/octet-stream")
    }

    /// 09 D1 #7: the server picks the parser by the extension; a name without one would be a 415.
    @Test func rosterFilenamesAlwaysHaveAnExtension() {
        #expect(APIClient.rosterUploadFilename("roster_other.csv") == "roster_other.csv")
        #expect(APIClient.rosterUploadFilename("Team Roster.XLSX") == "Team Roster.XLSX")
        #expect(APIClient.rosterUploadFilename(#"C:\fakepath\roster.tsv"#) == "roster.tsv")
        #expect(APIClient.rosterUploadFilename("roster") == "roster.csv")
        #expect(APIClient.rosterUploadFilename(".csv") == ".csv.csv")
        #expect(APIClient.rosterUploadFilename("") == "roster.csv")
        #expect(APIClient.rosterUploadFilename("  ") == "roster.csv")
        #expect(APIClient.rosterUploadFilename("dir/") == "dir.csv")
    }

    @Test func boundariesAreUnique() {
        #expect(MultipartFormData().boundary != MultipartFormData().boundary)
    }
}
