//
//  ESignCloneApp.swift
//  ESignClone
//
//  ملف واحد يحتوي كل كود التطبيق (النماذج + الخدمات + الشاشات) لتسهيل الرفع.
//  للتفاصيل الكاملة راجع الشرح المرفق في الرد.
//

import SwiftUI

@main
struct ESignCloneApp: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(store)
        }
    }
}
import Foundation

/// شهادة توقيع (ملف .p12 + كلمة المرور)
struct SigningCertificate: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var p12FileName: String       // اسم الملف داخل مجلد Documents/Certificates
    var provisioningFileName: String // اسم ملف .mobileprovision المرتبط
    var passwordKeychainKey: String  // مفتاح كلمة المرور في Keychain (لا تُخزَّن كنص صريح)
    var dateAdded: Date = Date()
    var teamID: String?
    var expirationDate: Date?
}

/// خيارات التعديل التي يوفرها eSign عادة قبل التوقيع
struct SigningOptions: Codable {
    var newBundleID: String? = nil
    var newDisplayName: String? = nil
    var newVersion: String? = nil
    var newBuildNumber: String? = nil
    var removeWatchApp: Bool = false
    var removeUIRequiredDeviceCapabilities: Bool = false
    var forceFileSharing: Bool = false
    var forceItunesFileSharing: Bool = false
    var removeSupportedDevices: Bool = false
    var replaceIconFileName: String? = nil // اسم صورة أيقونة بديلة في مجلد مؤقت
}

/// تمثيل مشروع/ملف IPA أثناء المعالجة
struct IPAProject: Identifiable {
    let id: UUID = UUID()
    var originalURL: URL
    var displayName: String
    var bundleID: String?
    var version: String?
    var extractedFolderURL: URL?
    var appFolderURL: URL? // مسار Payload/App.app بعد الاستخراج
    var sizeBytes: Int64 = 0
}

enum LogLevel: String {
    case info, warning, error, success
}

struct LogEntry: Identifiable {
    let id = UUID()
    let date: Date = Date()
    let level: LogLevel
    let message: String
}

@MainActor
final class AppStore: ObservableObject {
    @Published var certificates: [SigningCertificate] = []
    @Published var logs: [LogEntry] = []
    @Published var currentProject: IPAProject?
    @Published var isBusy: Bool = false
    @Published var progress: Double = 0

    private let certsFileURL: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        certsFileURL = docs.appendingPathComponent("certificates.json")
        loadCertificates()
    }

    func log(_ message: String, level: LogLevel = .info) {
        logs.append(LogEntry(level: level, message: message))
        if logs.count > 500 { logs.removeFirst(logs.count - 500) }
    }

    func loadCertificates() {
        guard let data = try? Data(contentsOf: certsFileURL),
              let list = try? JSONDecoder().decode([SigningCertificate].self, from: data) else { return }
        certificates = list
    }

    func saveCertificates() {
        guard let data = try? JSONEncoder().encode(certificates) else { return }
        try? data.write(to: certsFileURL, options: .atomic)
    }

    func addCertificate(_ cert: SigningCertificate) {
        certificates.append(cert)
        saveCertificates()
        log("تمت إضافة الشهادة: \(cert.name)", level: .success)
    }

    func removeCertificate(_ cert: SigningCertificate) {
        certificates.removeAll { $0.id == cert.id }
        saveCertificates()
        log("تم حذف الشهادة: \(cert.name)", level: .warning)
    }
}
import Compression

/// أداة ZIP خفيفة الوزن مبنية من الصفر (بدون اعتماد على SPM خارجي)
/// تدعم: فك ضغط ملفات IPA (Deflate/Store) وإعادة ضغطها بصيغة متوافقة مع iOS.
enum ZipArchiver {

    enum ZipError: Error, LocalizedError {
        case invalidArchive(String)
        case ioError(String)

        var errorDescription: String? {
            switch self {
            case .invalidArchive(let m): return "أرشيف غير صالح: \(m)"
            case .ioError(let m): return "خطأ إدخال/إخراج: \(m)"
            }
        }
    }

    // MARK: - Unzip

    static func unzip(fileAt sourceURL: URL, to destinationDir: URL, progress: ((Double) -> Void)? = nil) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destinationDir, withIntermediateDirectories: true)

        let data = try Data(contentsOf: sourceURL, options: .alwaysMapped)
        let entries = try parseCentralDirectory(data: data)

        for (index, entry) in entries.enumerated() {
            let outURL = destinationDir.appendingPathComponent(entry.fileName)
            if entry.fileName.hasSuffix("/") {
                try fm.createDirectory(at: outURL, withIntermediateDirectories: true)
            } else {
                try fm.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let content = try extractContent(data: data, entry: entry)
                try content.write(to: outURL, options: .atomic)
            }
            progress?(Double(index + 1) / Double(entries.count))
        }
    }

    // MARK: - Zip

    static func zip(directory sourceDir: URL, to destinationURL: URL, progress: ((Double) -> Void)? = nil) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destinationURL.path) {
            try fm.removeItem(at: destinationURL)
        }

        guard let enumerator = fm.enumerator(at: sourceDir, includingPropertiesForKeys: [.isDirectoryKey]) else {
            throw ZipError.ioError("تعذر قراءة المجلد المصدر")
        }

        var allFiles: [URL] = []
        for case let url as URL in enumerator {
            allFiles.append(url)
        }

        var centralDirectoryRecords: [Data] = []
        var offset: UInt32 = 0
        let outputStream = OutputStream(url: destinationURL, append: false)
        outputStream?.open()
        defer { outputStream?.close() }

        guard let stream = outputStream else {
            throw ZipError.ioError("تعذر إنشاء الملف الناتج")
        }

        func write(_ data: Data) {
            data.withUnsafeBytes { raw in
                _ = stream.write(raw.bindMemory(to: UInt8.self).baseAddress!, maxLength: data.count)
            }
        }

        for (index, fileURL) in allFiles.enumerated() {
            var isDir: ObjCBool = false
            fm.fileExists(atPath: fileURL.path, isDirectory: &isDir)
            let relativePath = fileURL.path.replacingOccurrences(of: sourceDir.path + "/", with: "")

            if isDir.boolValue { continue } // نخزن الملفات فقط، المجلدات تُستنتج من المسارات

            let fileData = try Data(contentsOf: fileURL)
            let crc = crc32(data: fileData)
            let compressed = deflate(data: fileData)
            let useCompression = compressed.count < fileData.count
            let payload = useCompression ? compressed : fileData
            let method: UInt16 = useCompression ? 8 : 0

            let nameData = Array(relativePath.utf8)
            var localHeader = Data()
            localHeader.append(contentsOf: [0x50, 0x4b, 0x03, 0x04]) // local file header sig
            localHeader.appendLE(UInt16(20))          // version needed
            localHeader.appendLE(UInt16(0))            // flags
            localHeader.appendLE(method)                // compression method
            localHeader.appendLE(UInt16(0))            // mod time
            localHeader.appendLE(UInt16(0))            // mod date
            localHeader.appendLE(crc)                   // crc32
            localHeader.appendLE(UInt32(payload.count)) // compressed size
            localHeader.appendLE(UInt32(fileData.count))// uncompressed size
            localHeader.appendLE(UInt16(nameData.count))// filename length
            localHeader.appendLE(UInt16(0))             // extra length
            localHeader.append(contentsOf: nameData)

            write(localHeader)
            write(payload)

            var central = Data()
            central.append(contentsOf: [0x50, 0x4b, 0x01, 0x02]) // central dir sig
            central.appendLE(UInt16(20))  // version made by
            central.appendLE(UInt16(20))  // version needed
            central.appendLE(UInt16(0))   // flags
            central.appendLE(method)
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(crc)
            central.appendLE(UInt32(payload.count))
            central.appendLE(UInt32(fileData.count))
            central.appendLE(UInt16(nameData.count))
            central.appendLE(UInt16(0)) // extra len
            central.appendLE(UInt16(0)) // comment len
            central.appendLE(UInt16(0)) // disk number
            central.appendLE(UInt16(0)) // internal attrs
            central.appendLE(UInt32(0o100644 << 16)) // external attrs (unix perms)
            central.appendLE(offset)    // local header offset
            central.append(contentsOf: nameData)

            centralDirectoryRecords.append(central)
            offset += UInt32(localHeader.count + payload.count)
            progress?(Double(index + 1) / Double(allFiles.count))
        }

        let centralStart = offset
        var centralSize: UInt32 = 0
        for record in centralDirectoryRecords {
            write(record)
            centralSize += UInt32(record.count)
        }

        var eocd = Data()
        eocd.append(contentsOf: [0x50, 0x4b, 0x05, 0x06])
        eocd.appendLE(UInt16(0)) // disk number
        eocd.appendLE(UInt16(0)) // disk with central dir
        eocd.appendLE(UInt16(centralDirectoryRecords.count)) // entries this disk
        eocd.appendLE(UInt16(centralDirectoryRecords.count)) // total entries
        eocd.appendLE(centralSize)
        eocd.appendLE(centralStart)
        eocd.appendLE(UInt16(0)) // comment length
        write(eocd)
    }

    // MARK: - Central directory parsing

    private struct Entry {
        let fileName: String
        let method: UInt16
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let localHeaderOffset: UInt32
    }

    private static func parseCentralDirectory(data: Data) throws -> [Entry] {
        // ابحث عن نهاية الدليل المركزي (EOCD) من آخر الملف
        guard let eocdRange = findSignature([0x50, 0x4b, 0x05, 0x06], in: data, fromEnd: true) else {
            throw ZipError.invalidArchive("لم يتم العثور على EOCD")
        }
        let entryCount = Int(data.readLE(UInt16.self, at: eocdRange.lowerBound + 10))
        let centralOffset = Int(data.readLE(UInt32.self, at: eocdRange.lowerBound + 16))

        var entries: [Entry] = []
        var cursor = centralOffset
        for _ in 0..<entryCount {
            guard data.count > cursor + 46 else { break }
            let method = data.readLE(UInt16.self, at: cursor + 10)
            let compSize = data.readLE(UInt32.self, at: cursor + 20)
            let uncompSize = data.readLE(UInt32.self, at: cursor + 24)
            let nameLen = Int(data.readLE(UInt16.self, at: cursor + 28))
            let extraLen = Int(data.readLE(UInt16.self, at: cursor + 30))
            let commentLen = Int(data.readLE(UInt16.self, at: cursor + 32))
            let localOffset = data.readLE(UInt32.self, at: cursor + 42)
            let nameStart = cursor + 46
            let nameData = data.subdata(in: nameStart..<(nameStart + nameLen))
            let name = String(data: nameData, encoding: .utf8) ?? ""

            entries.append(Entry(fileName: name, method: method, compressedSize: compSize,
                                  uncompressedSize: uncompSize, localHeaderOffset: localOffset))
            cursor = nameStart + nameLen + extraLen + commentLen
        }
        return entries
    }

    private static func extractContent(data: Data, entry: Entry) throws -> Data {
        let base = Int(entry.localHeaderOffset)
        let nameLen = Int(data.readLE(UInt16.self, at: base + 26))
        let extraLen = Int(data.readLE(UInt16.self, at: base + 28))
        let dataStart = base + 30 + nameLen + extraLen
        let dataEnd = dataStart + Int(entry.compressedSize)
        guard dataEnd <= data.count else { throw ZipError.invalidArchive("بيانات تالفة: \(entry.fileName)") }
        let compressed = data.subdata(in: dataStart..<dataEnd)

        if entry.method == 0 {
            return compressed
        } else if entry.method == 8 {
            return inflate(data: compressed, expectedSize: Int(entry.uncompressedSize))
        } else {
            throw ZipError.invalidArchive("طريقة ضغط غير مدعومة: \(entry.method)")
        }
    }

    private static func findSignature(_ sig: [UInt8], in data: Data, fromEnd: Bool) -> Range<Int>? {
        let bytes = [UInt8](data)
        let n = bytes.count
        if fromEnd {
            var i = n - sig.count
            while i >= 0 {
                if Array(bytes[i..<i+sig.count]) == sig { return i..<(i+sig.count) }
                i -= 1
            }
        }
        return nil
    }

    // MARK: - Compression helpers (zlib raw deflate via Apple's Compression framework)

    private static func deflate(data: Data) -> Data {
        return compress(data: data, operation: COMPRESSION_STREAM_ENCODE)
    }

    private static func inflate(data: Data, expectedSize: Int) -> Data {
        let result = compress(data: data, operation: COMPRESSION_STREAM_DECODE)
        return result
    }

    private static func compress(data: Data, operation: compression_stream_operation) -> Data {
        var output = Data()
        let bufferSize = 64 * 1024
        var streamPtr = compression_stream()
        var status = compression_stream_init(&streamPtr, operation, COMPRESSION_ZLIB_RAW)
        guard status != COMPRESSION_STATUS_ERROR else { return Data() }
        defer { compression_stream_destroy(&streamPtr) }

        let dstBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { dstBuffer.deallocate() }

        data.withUnsafeBytes { (srcRaw: UnsafeRawBufferPointer) in
            let srcPtr = srcRaw.bindMemory(to: UInt8.self).baseAddress
            streamPtr.src_ptr = srcPtr
            streamPtr.src_size = data.count
            streamPtr.dst_ptr = dstBuffer
            streamPtr.dst_size = bufferSize

            repeat {
                status = compression_stream_process(&streamPtr, streamPtr.src_size == 0 ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
                switch status {
                case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
                    let produced = bufferSize - streamPtr.dst_size
                    if produced > 0 {
                        output.append(dstBuffer, count: produced)
                        streamPtr.dst_ptr = dstBuffer
                        streamPtr.dst_size = bufferSize
                    }
                default:
                    break
                }
            } while status == COMPRESSION_STATUS_OK
        }
        return output
    }

    private static func crc32(data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                if crc & 1 != 0 {
                    crc = (crc >> 1) ^ 0xEDB88320
                } else {
                    crc >>= 1
                }
            }
        }
        return crc ^ 0xFFFFFFFF
    }
}

// MARK: - Data helpers (little endian read/write)

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
    }
    mutating func appendLE(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }
    mutating func appendLE(_ value: Int) { appendLE(UInt16(value)) }

    func readLE<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        var value: T = 0
        let size = MemoryLayout<T>.size
        for i in 0..<size {
            value |= T(self[self.startIndex + offset + i]) << (8 * i)
        }
        return value
    }
}

enum PlistTool {

    enum PlistError: Error, LocalizedError {
        case notFound
        case invalidFormat

        var errorDescription: String? {
            switch self {
            case .notFound: return "لم يتم العثور على ملف Info.plist داخل التطبيق"
            case .invalidFormat: return "صيغة Info.plist غير صالحة"
            }
        }
    }

    /// يبحث عن مجلد App.app داخل Payload بعد فك الضغط
    static func findAppBundle(inside payloadDir: URL) throws -> URL {
        let fm = FileManager.default
        let payload = payloadDir.appendingPathComponent("Payload")
        let items = try fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)
        guard let appDir = items.first(where: { $0.pathExtension == "app" }) else {
            throw PlistError.notFound
        }
        return appDir
    }

    static func readInfoPlist(appBundle: URL) throws -> [String: Any] {
        let plistURL = appBundle.appendingPathComponent("Info.plist")
        let data = try Data(contentsOf: plistURL)
        guard let dict = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw PlistError.invalidFormat
        }
        return dict
    }

    /// يطبّق خيارات التوقيع (Bundle ID، الاسم، الإصدار...) على Info.plist
    @discardableResult
    static func applyOptions(_ options: SigningOptions, appBundle: URL) throws -> [String: Any] {
        var dict = try readInfoPlist(appBundle: appBundle)

        if let bundleID = options.newBundleID, !bundleID.isEmpty {
            dict["CFBundleIdentifier"] = bundleID
        }
        if let name = options.newDisplayName, !name.isEmpty {
            dict["CFBundleDisplayName"] = name
            dict["CFBundleName"] = name
        }
        if let version = options.newVersion, !version.isEmpty {
            dict["CFBundleShortVersionString"] = version
        }
        if let build = options.newBuildNumber, !build.isEmpty {
            dict["CFBundleVersion"] = build
        }
        if options.removeUIRequiredDeviceCapabilities {
            dict.removeValue(forKey: "UIRequiredDeviceCapabilities")
        }
        if options.removeSupportedDevices {
            dict.removeValue(forKey: "UISupportedDevices")
        }
        if options.forceFileSharing {
            dict["UIFileSharingEnabled"] = true
        }
        if options.forceItunesFileSharing {
            dict["LSSupportsOpeningDocumentsInPlace"] = true
        }

        let plistURL = appBundle.appendingPathComponent("Info.plist")
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
        try data.write(to: plistURL, options: .atomic)

        if options.removeWatchApp {
            let watchDir = appBundle.appendingPathComponent("Watch")
            if FileManager.default.fileExists(atPath: watchDir.path) {
                try? FileManager.default.removeItem(at: watchDir)
            }
        }

        return dict
    }

    /// يستخرج bundle-id الحالي بدون تعديل، لعرضه في الواجهة
    static func currentBundleID(appBundle: URL) -> String? {
        (try? readInfoPlist(appBundle: appBundle))?["CFBundleIdentifier"] as? String
    }

    static func currentVersion(appBundle: URL) -> String? {
        (try? readInfoPlist(appBundle: appBundle))?["CFBundleShortVersionString"] as? String
    }

    static func currentDisplayName(appBundle: URL) -> String? {
        let dict = try? readInfoPlist(appBundle: appBundle)
        return (dict?["CFBundleDisplayName"] as? String) ?? (dict?["CFBundleName"] as? String)
    }

    /// يبني entitlements جديدة اعتمادًا على ملف provisioning profile (Application Identifier, Team ID...)
    static func buildEntitlements(from mobileProvisionDict: [String: Any], newBundleID: String?) -> [String: Any] {
        var entitlements = (mobileProvisionDict["Entitlements"] as? [String: Any]) ?? [:]
        if let bundleID = newBundleID,
           let teamID = mobileProvisionDict["TeamIdentifier"] as? [String], let team = teamID.first {
            entitlements["application-identifier"] = "\(team).\(bundleID)"
        }
        return entitlements
    }
}

/// يقرأ محتوى ملف .mobileprovision (وهو حاوية CMS/PKCS7 تحتوي plist بصيغة نصية)
/// نستخرج القسم الخاص بالـ plist مباشرة بالبحث عن وسوم XML، وهي طريقة شائعة وآمنة
/// لعرض المعلومات (لا تتطلب فك تشفير CMS الكامل).
enum ProvisioningProfileReader {

    enum ReaderError: Error, LocalizedError {
        case plistNotFound
        var errorDescription: String? { "تعذر قراءة محتوى ملف الـ Provisioning Profile" }
    }

    static func readDictionary(from fileURL: URL) throws -> [String: Any] {
        let raw = try Data(contentsOf: fileURL)
        guard let startRange = raw.range(of: Data("<?xml".utf8)),
              let endRange = raw.range(of: Data("</plist>".utf8)) else {
            throw ReaderError.plistNotFound
        }
        let plistData = raw.subdata(in: startRange.lowerBound..<endRange.upperBound)
        guard let dict = try PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] else {
            throw ReaderError.plistNotFound
        }
        return dict
    }

    static func summary(from dict: [String: Any]) -> (name: String, teamID: String?, expiry: Date?, appID: String?) {
        let name = dict["Name"] as? String ?? "بدون اسم"
        let teamID = (dict["TeamIdentifier"] as? [String])?.first
        let expiry = dict["ExpirationDate"] as? Date
        let appID = (dict["Entitlements"] as? [String: Any])?["application-identifier"] as? String
        return (name, teamID, expiry, appID)
    }
}

/// بروتوكول عام لأي "محرك توقيع" — يسمح باستبدال المحرك دون تعديل بقية التطبيق
protocol CodeSigningEngine {
    /// يوقّع كل الملفات القابلة للتنفيذ (Executables/Frameworks/PlugIns) داخل appBundle
    /// باستخدام شهادة p12 وملف provisioning profile، ثم يكتب CodeResources الجديد.
    func sign(appBundle: URL,
              p12URL: URL,
              p12Password: String,
              mobileProvisionURL: URL,
              entitlements: [String: Any]) throws
}

enum SigningServiceError: Error, LocalizedError {
    case engineNotConfigured
    case missingExecutable
    case certificateInvalid

    var errorDescription: String? {
        switch self {
        case .engineNotConfigured:
            return """
            محرك التوقيع (zsign) غير مُفعّل في هذا المشروع بعد.
            أضف zsign كـ git submodule واربطه هنا كما هو موضّح في README.md.
            """
        case .missingExecutable: return "لم يتم العثور على الملف التنفيذي الرئيسي داخل التطبيق"
        case .certificateInvalid: return "الشهادة أو كلمة المرور غير صحيحة"
        }
    }
}

/// المنسّق الرئيسي لعملية التوقيع الكاملة: استخراج -> تعديل -> توقيع -> إعادة ضغط
@MainActor
final class SigningPipeline {

    private let engine: CodeSigningEngine?

    /// مرّر هنا تنفيذًا حقيقيًا لـ CodeSigningEngine (مثل ZSignEngine) بعد ربط zsign.
    init(engine: CodeSigningEngine? = nil) {
        self.engine = engine
    }

    func run(project: IPAProject,
             certificate: SigningCertificate,
             p12Password: String,
             options: SigningOptions,
             log: (String, LogLevel) -> Void,
             progress: (Double) -> Void) throws -> URL {

        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        log("جارٍ فك ضغط ملف IPA...", .info)
        try ZipArchiver.unzip(fileAt: project.originalURL, to: workDir) { p in progress(p * 0.35) }

        let appBundle = try PlistTool.findAppBundle(inside: workDir)
        log("تم العثور على حزمة التطبيق: \(appBundle.lastPathComponent)", .success)

        log("جارٍ تعديل Info.plist حسب الخيارات المحددة...", .info)
        try PlistTool.applyOptions(options, appBundle: appBundle)

        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let certsDir = docs.appendingPathComponent("Certificates")
        let p12URL = certsDir.appendingPathComponent(certificate.p12FileName)
        let provURL = certsDir.appendingPathComponent(certificate.provisioningFileName)

        let provDict = try ProvisioningProfileReader.readDictionary(from: provURL)
        let entitlements = PlistTool.buildEntitlements(from: provDict, newBundleID: options.newBundleID)

        // انسخ ملف الـ provisioning الجديد إلى داخل التطبيق (شرط أساسي لأي تطبيق موقّع)
        try? fm.removeItem(at: appBundle.appendingPathComponent("embedded.mobileprovision"))
        try fm.copyItem(at: provURL, to: appBundle.appendingPathComponent("embedded.mobileprovision"))

        log("جارٍ التوقيع...", .info)
        guard let engine = engine else {
            throw SigningServiceError.engineNotConfigured
        }
        try engine.sign(appBundle: appBundle,
                         p12URL: p12URL,
                         p12Password: p12Password,
                         mobileProvisionURL: provURL,
                         entitlements: entitlements)
        progress(0.85)
        log("تم التوقيع بنجاح", .success)

        log("جارٍ إعادة ضغط ملف IPA...", .info)
        let outputName = (options.newDisplayName ?? project.displayName)
            .replacingOccurrences(of: " ", with: "_")
        let outputURL = docs.appendingPathComponent("Signed_\(outputName)_\(Int(Date().timeIntervalSince1970)).ipa")
        try ZipArchiver.zip(directory: workDir, to: outputURL) { p in progress(0.85 + p * 0.15) }

        log("اكتملت العملية: \(outputURL.lastPathComponent)", .success)
        return outputURL
    }
}

// MARK: - نقطة ربط zsign (اختيارية)
//
// بعد إضافة zsign كـ submodule (راجع README.md، قسم "تفعيل التوقيع الحقيقي")
// أنشئ ملف Objective-C++ باسم ZSignBridge.mm بداخله استدعاء لدالة zsign الأساسية،
// ثم نفّذ CodeSigningEngine هنا كالتالي:
//
// final class ZSignEngine: CodeSigningEngine {
//     func sign(appBundle: URL, p12URL: URL, p12Password: String,
//               mobileProvisionURL: URL, entitlements: [String: Any]) throws {
//         let entData = try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0)
//         let entPath = appBundle.appendingPathComponent(".entitlements.plist")
//         try entData.write(to: entPath)
//         let result = ZSignBridge.sign(appBundle.path, p12URL.path, p12Password,
//                                        mobileProvisionURL.path, entPath.path)
//         if result != 0 { throw SigningServiceError.certificateInvalid }
//     }
// }
//
// ثم في ESignCloneApp.swift أو HomeView استبدل:
//   SigningPipeline(engine: nil)
// بـ:
//   SigningPipeline(engine: ZSignEngine())
import UniformTypeIdentifiers

struct DocumentPicker: UIViewControllerRepresentable {
    let contentTypes: [UTType]
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}

extension UTType {
    static var ipa: UTType {
        UTType(filenameExtension: "ipa") ?? .data
    }
    static var p12: UTType {
        UTType(filenameExtension: "p12") ?? .data
    }
    static var mobileProvision: UTType {
        UTType(filenameExtension: "mobileprovision") ?? .data
    }
}

struct HomeView: View {
    @EnvironmentObject var store: AppStore
    @State private var showIPAPicker = false
    @State private var showCertificates = false
    @State private var showSignSheet = false
    @State private var showLogs = false
    @State private var pickedIPAURL: URL?

    var body: some View {
        NavigationView {
            List {
                Section("الملف") {
                    Button {
                        showIPAPicker = true
                    } label: {
                        Label("استيراد ملف IPA", systemImage: "square.and.arrow.down")
                    }

                    if let project = store.currentProject {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(project.displayName).font(.headline)
                            if let bid = project.bundleID {
                                Text(bid).font(.caption).foregroundColor(.secondary)
                            }
                        }
                        Button {
                            showSignSheet = true
                        } label: {
                            Label("تعديل وتوقيع", systemImage: "signature")
                        }
                        .disabled(store.certificates.isEmpty)
                    }
                }

                Section("الشهادات") {
                    NavigationLink {
                        CertificatesView()
                    } label: {
                        Label("إدارة الشهادات (\(store.certificates.count))", systemImage: "checkmark.seal")
                    }
                }

                Section("السجل") {
                    NavigationLink {
                        LogConsoleView()
                    } label: {
                        Label("عرض السجل", systemImage: "terminal")
                    }
                }

                if store.isBusy {
                    Section {
                        ProgressView(value: store.progress)
                        Text("جارٍ المعالجة...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("eSign Clone")
            .sheet(isPresented: $showIPAPicker) {
                DocumentPicker(contentTypes: [.ipa]) { url in
                    handlePickedIPA(url)
                }
            }
            .sheet(isPresented: $showSignSheet) {
                if let project = store.currentProject {
                    SignSheetView(project: project)
                }
            }
        }
    }

    private func handlePickedIPA(_ url: URL) {
        store.log("تم اختيار الملف: \(url.lastPathComponent)")
        let sizes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        store.currentProject = IPAProject(originalURL: url,
                                           displayName: url.deletingPathExtension().lastPathComponent,
                                           sizeBytes: sizes ?? 0)
    }
}

#Preview {
    HomeView().environmentObject(AppStore())
}
import Security

struct CertificatesView: View {
    @EnvironmentObject var store: AppStore
    @State private var showP12Picker = false
    @State private var showProvPicker = false
    @State private var pendingP12URL: URL?
    @State private var pendingProvURL: URL?
    @State private var certName: String = ""
    @State private var password: String = ""
    @State private var showAddSheet = false

    var body: some View {
        List {
            ForEach(store.certificates) { cert in
                VStack(alignment: .leading, spacing: 4) {
                    Text(cert.name).font(.headline)
                    if let team = cert.teamID {
                        Text("Team: \(team)").font(.caption).foregroundColor(.secondary)
                    }
                    if let exp = cert.expirationDate {
                        Text("تنتهي: \(exp.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption2)
                            .foregroundColor(exp < Date() ? .red : .secondary)
                    }
                }
            }
            .onDelete { indexSet in
                indexSet.forEach { store.removeCertificate(store.certificates[$0]) }
            }
        }
        .navigationTitle("الشهادات")
        .toolbar {
            Button {
                showAddSheet = true
            } label: {
                Image(systemName: "plus")
            }
        }
        .sheet(isPresented: $showAddSheet) {
            addCertificateForm
        }
    }

    private var addCertificateForm: some View {
        NavigationView {
            Form {
                Section("اسم الشهادة") {
                    TextField("مثال: شهادة التطوير", text: $certName)
                }
                Section("ملف p12") {
                    Button(pendingP12URL?.lastPathComponent ?? "اختر ملف .p12") {
                        showP12Picker = true
                    }
                }
                Section("كلمة المرور") {
                    SecureField("كلمة مرور p12", text: $password)
                }
                Section("Provisioning Profile") {
                    Button(pendingProvURL?.lastPathComponent ?? "اختر ملف .mobileprovision") {
                        showProvPicker = true
                    }
                }
                Section {
                    Button("حفظ") { saveCertificate() }
                        .disabled(pendingP12URL == nil || pendingProvURL == nil || certName.isEmpty)
                }
            }
            .navigationTitle("إضافة شهادة")
            .sheet(isPresented: $showP12Picker) {
                DocumentPicker(contentTypes: [.p12]) { pendingP12URL = $0 }
            }
            .sheet(isPresented: $showProvPicker) {
                DocumentPicker(contentTypes: [.mobileProvision]) { pendingProvURL = $0 }
            }
        }
    }

    private func saveCertificate() {
        guard let p12 = pendingP12URL, let prov = pendingProvURL else { return }
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let certsDir = docs.appendingPathComponent("Certificates")
        try? fm.createDirectory(at: certsDir, withIntermediateDirectories: true)

        let p12Dest = certsDir.appendingPathComponent(UUID().uuidString + ".p12")
        let provDest = certsDir.appendingPathComponent(UUID().uuidString + ".mobileprovision")
        try? fm.copyItem(at: p12, to: p12Dest)
        try? fm.copyItem(at: prov, to: provDest)

        var teamID: String?
        var expiry: Date?
        if let dict = try? ProvisioningProfileReader.readDictionary(from: provDest) {
            let summary = ProvisioningProfileReader.summary(from: dict)
            teamID = summary.teamID
            expiry = summary.expiry
        }

        let keychainKey = "p12_pw_\(UUID().uuidString)"
        savePasswordToKeychain(password, key: keychainKey)

        let cert = SigningCertificate(name: certName,
                                       p12FileName: p12Dest.lastPathComponent,
                                       provisioningFileName: provDest.lastPathComponent,
                                       passwordKeychainKey: keychainKey,
                                       teamID: teamID,
                                       expirationDate: expiry)
        store.addCertificate(cert)

        certName = ""; password = ""; pendingP12URL = nil; pendingProvURL = nil
        showAddSheet = false
    }

    private func savePasswordToKeychain(_ password: String, key: String) {
        let data = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }
}

struct SignSheetView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    let project: IPAProject

    @State private var selectedCertID: SigningCertificate.ID?
    @State private var options = SigningOptions()
    @State private var resultURL: URL?
    @State private var errorMessage: String?

    var body: some View {
        NavigationView {
            Form {
                Section("الشهادة") {
                    Picker("اختر شهادة", selection: $selectedCertID) {
                        Text("بدون اختيار").tag(SigningCertificate.ID?.none)
                        ForEach(store.certificates) { cert in
                            Text(cert.name).tag(Optional(cert.id))
                        }
                    }
                }

                Section("خيارات أساسية") {
                    TextField("Bundle ID جديد (اختياري)", text: Binding(
                        get: { options.newBundleID ?? "" },
                        set: { options.newBundleID = $0.isEmpty ? nil : $0 }))
                    TextField("اسم العرض الجديد (اختياري)", text: Binding(
                        get: { options.newDisplayName ?? "" },
                        set: { options.newDisplayName = $0.isEmpty ? nil : $0 }))
                    TextField("رقم الإصدار (اختياري)", text: Binding(
                        get: { options.newVersion ?? "" },
                        set: { options.newVersion = $0.isEmpty ? nil : $0 }))
                }

                Section("خيارات متقدمة") {
                    Toggle("حذف تطبيق Watch", isOn: $options.removeWatchApp)
                    Toggle("إزالة قيود الأجهزة المطلوبة", isOn: $options.removeUIRequiredDeviceCapabilities)
                    Toggle("إزالة قائمة الأجهزة المدعومة", isOn: $options.removeSupportedDevices)
                    Toggle("تفعيل مشاركة الملفات (Files app)", isOn: $options.forceFileSharing)
                    Toggle("فتح المستندات داخل التطبيق مباشرة", isOn: $options.forceItunesFileSharing)
                }

                if let error = errorMessage {
                    Section {
                        Text(error).foregroundColor(.red)
                    }
                }

                if let resultURL = resultURL {
                    Section {
                        ShareLink(item: resultURL) {
                            Label("مشاركة/حفظ الملف الموقّع", systemImage: "square.and.arrow.up")
                        }
                    }
                }

                Section {
                    Button {
                        startSigning()
                    } label: {
                        if store.isBusy {
                            ProgressView()
                        } else {
                            Text("بدء التوقيع")
                        }
                    }
                    .disabled(selectedCertID == nil || store.isBusy)
                }
            }
            .navigationTitle("توقيع التطبيق")
            .toolbar {
                Button("إغلاق") { dismiss() }
            }
        }
    }

    private func startSigning() {
        guard let certID = selectedCertID,
              let cert = store.certificates.first(where: { $0.id == certID }) else { return }

        errorMessage = nil
        resultURL = nil
        store.isBusy = true
        store.progress = 0

        let password = readPasswordFromKeychain(key: cert.passwordKeychainKey) ?? ""

        // ملاحظة: هذا الاستدعاء يستخدم SigningPipeline(engine: nil) افتراضيًا.
        // بعد ربط zsign (راجع SigningService.swift و README.md) مرّر المحرك الحقيقي هنا.
        let pipeline = SigningPipeline(engine: nil)

        Task {
            do {
                let url = try pipeline.run(
                    project: project,
                    certificate: cert,
                    p12Password: password,
                    options: options,
                    log: { msg, level in store.log(msg, level: level) },
                    progress: { p in store.progress = p }
                )
                await MainActor.run {
                    self.resultURL = url
                    store.isBusy = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    store.log(error.localizedDescription, level: .error)
                    store.isBusy = false
                }
            }
        }
    }

    private func readPasswordFromKeychain(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

struct LogConsoleView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        List(store.logs.reversed()) { entry in
            HStack {
                Circle()
                    .fill(color(for: entry.level))
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading) {
                    Text(entry.message).font(.footnote)
                    Text(entry.date.formatted(date: .omitted, time: .standard))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("السجل")
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        case .success: return .green
        }
    }
}
