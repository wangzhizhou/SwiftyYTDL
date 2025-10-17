//
//  YTDL.swift
//  YTDLKit
//
//  Created by Danylo Kostyshyn on 20.07.2022.
//

import YTDLKit.Private
import Foundation
import Darwin
import PythonKit
import ZipArchive

extension String: @retroactive LocalizedError {
    
    public var errorDescription: String? { return self }
    
}

public class YTDL {
    
    public static let shared = YTDL()
    
    public var version: String!
    private var yt_dlp: PythonObject!
    
    private var module: Bundle {
        Bundle(for: type(of: self))
    }
    
    init() {
        setupPython()
        try? setupYTDL()
    }
    
    var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    func setupPython() {
        guard
            let pythonBundle = module.path(forResource: "python.zip", ofType: nil)
        else { fatalError("Python bundle not found.") }
        
        let pythonHome = documentsDirectory
            .appendingPathComponent("python", isDirectory: true).path
        let verFilePath = URL(fileURLWithPath: pythonHome)
            .appendingPathComponent(".version").path
        
        // Remove existing installation if newer version is available
        if let infoPlistVer = module.infoDictionary?["PYTHON_VER"] as? String,
           let currVer = try? String(contentsOfFile: verFilePath),
           infoPlistVer == currVer {
            print("Python version already installed: \(currVer)")
        } else {
            try? FileManager.default.removeItem(atPath: pythonHome)
        }
        
        if !FileManager.default.fileExists(atPath: pythonHome) {
            SSZipArchive.unzipFile(
                atPath: pythonBundle,
                toDestination: pythonHome
            )
        }
        
        setenv("PYTHONHOME", pythonHome, 1)
        setenv("PYTHONPATH", "\(pythonHome)/lib/python3.9/:\(pythonHome)/lib/python3.9/site-packages", 1)
        setenv("TMP", NSTemporaryDirectory(), 1)
        
        // libPython is statically linked, so we can force init it here
        Py_Initialize()
        PyEval_InitThreads()
        
        let sys = Python.import("sys")
        
        let pythonVer = [
            sys.version_info.major,
            sys.version_info.minor,
            sys.version_info.micro
        ]
            .compactMap { "\($0)" }
            .joined(separator: ".")
        
        print("Python \(pythonVer)")
        print("Python Version: \(sys.version)")
        print("Python Encoding: \(sys.getdefaultencoding().upper())")
        
        // Update ".version" file
        try? pythonVer.write(
            toFile: verFilePath,
            atomically: true,
            encoding: .utf8
        )
    }
    
    enum YTDLDefaults {
        static let options: PythonObject = [
            "format": "best",
            "outtmpl": "%(title)s-%(id)s.%(ext)s",
            "cachedir": .init(stringLiteral: NSTemporaryDirectory())
        ]
        
        static let extraOptions: PythonObject = [
            "format": YTDLDefaults.options["format"],
            "nocheckcertificate": true,
            "cachedir": YTDLDefaults.options["format"],
        ]
        
        static func downloadOptions(progressHooks: PythonObject, playListItems: PythonObject) -> PythonObject {
            return [
                "format": YTDLDefaults.options["format"],
                "outtmpl": YTDLDefaults.options["outtmpl"],
                "nocheckcertificate": true,
                "cachedir": YTDLDefaults.options["format"],
                "progress_hooks": progressHooks,
                "playlist_items": playListItems,
            ]
        }
    }
    
    private var ytdlPythonExecScript: String { "yt-dlp" }
    
    func setupYTDL() throws {
        guard
            let moduleBundle = module.path(forResource: "yt-dlp.zip", ofType: nil)
        else { fatalError("yt-dlp not found.") }
        
        let moduleDestPath = documentsDirectory
            .appendingPathComponent("yt-dlp", isDirectory: true).path
        let modulePath = documentsDirectory
            .appendingPathComponent("yt-dlp/yt-dlp").path
        let verFilePath = URL(fileURLWithPath: moduleDestPath)
            .appendingPathComponent(".version").path
        
        // Remove existing installation if newer version is available
        if let infoPlistVer = module.infoDictionary?["YT_DLP_VER"] as? String,
           let currVer = try? String(contentsOfFile: verFilePath),
           infoPlistVer == currVer {
            print("yt-dlp version already installed: \(currVer)")
        } else {
            try? FileManager.default.removeItem(atPath: moduleDestPath)
        }
        
        if !FileManager.default.fileExists(atPath: modulePath) {
            SSZipArchive.unzipFile(
                atPath: moduleBundle,
                toDestination: moduleDestPath
            )
        }
        
        // Add module to `sys.path`
        guard
            let sys = try? Python.attemptImport("sys")
        else {
            throw "Failed to import `sys`"
        }
        sys.path.insert(1, modulePath)
        
        // Add module to `sys.path`
        guard
            let os = try? Python.attemptImport("os")
        else {
            throw "Failed to import `os`"
        }
        // Change working directory
        try os.chdir.throwing.dynamicallyCall(
            withKeywordArguments: [
                "": NSTemporaryDirectory()
            ]
        )
        
        // Import module
        guard
            let module = try? Python.attemptImport("yt_dlp"),
            let version = String(module.version.__version__)
        else {
            throw "Failed to import 'yt-dlp'"
        }
        
        print("yt-dlp: \(version)")
        self.version = version
        self.yt_dlp = module
        
        try? version.write(
            toFile: verFilePath,
            atomically: true,
            encoding: .utf8
        )
    }
    
    public func helloWorld() -> Int {
        return 42
    }
    
    // MARK: -
    
    public typealias ProgressUpdate = (Int64, Int64) -> Void
    
    public typealias ProgressCompletion = (Result<URL, Error>) -> Void
    
    private func statusCallback(_ updateHandler: @escaping ProgressUpdate,
                                _ completionHandler: @escaping ProgressCompletion) -> PythonObject {
        return PythonFunction { args, kwargs in
            guard
                let dict: [String: PythonObject] = Dictionary(args[0]),
                let status = dict["status"].flatMap({ String($0) })
            else { return 0 }
            
            switch status {
            case "downloading":
                let downloadedBytes = dict["downloaded_bytes"].flatMap({ Int64($0) }) ?? -1
                let totalBytes = dict["total_bytes"].flatMap({ Int64($0) }) ?? -1
                updateHandler(downloadedBytes, totalBytes)
            case "finished":
                let fileName = dict["filename"].flatMap({ String($0) })!
                let fileURL = URL(fileURLWithPath: NSTemporaryDirectory() + fileName)
                completionHandler(.success(fileURL))
            case "error":
                completionHandler(.failure("`progress_hook` Error"))
            default: break
            }
            
            return 0
        }.pythonObject
    }
    
    public func download(from url: URL, playlistIdx: Int = 1,
                         updateHandler: @escaping ProgressUpdate,
                         completionHandler: @escaping ProgressCompletion) throws {
        let progressHooks: PythonObject = [statusCallback(updateHandler, completionHandler)]
        let playListItems: PythonObject = .init(integerLiteral: playlistIdx)
        let options = YTDLDefaults.downloadOptions(progressHooks: progressHooks, playListItems: playListItems)
        let ydl = yt_dlp.YoutubeDL(options)
        try ydl.extract_info.throwing.dynamicallyCall(
            withKeywordArguments: [
                "": url.absoluteString,
                "download": true
            ])
    }
    
    public func extractInfo(from url: URL) throws -> [Downloadable] {
        let ydl = yt_dlp.YoutubeDL(YTDLDefaults.extraOptions)
        let info = try ydl.extract_info.throwing.dynamicallyCall(
            withKeywordArguments: [
                "": url.absoluteString,
                "download": false
            ])
        
        if let type = info.checking["_type"] {
            switch type {
            case "playlist":
                return try playlistEntries(from: info, browserUrl: url)
            default:
                throw "Unsupported `type`: \(type)"
            }
        } else if let _ = info.checking["formats"] {
            return try formats(from: info, ydl: ydl, browserUrl: url)
        }
        
        throw "Unsupported `url`: \(url)"
    }
    
    // MARK: -
    
    private func formats(from info: PythonObject, ydl: PythonObject, browserUrl: URL) throws -> [Format] {
        guard
            let id = info.checking["id"].flatMap({ String($0) }),
            let title = info.checking["title"].flatMap({ String($0) })
        else { throw "Failed to get `id` or `title`" }
        
        let formatSel = ydl.build_format_selector(YTDLDefaults.options["format"])
        let formats = try formatSel.throwing.dynamicallyCall(withArguments: info)
        
        var results: [Format] = []
        for format in formats {
            let width = format.checking["width"]
                .flatMap({ UInt($0) })
            let height = format.checking["height"]
                .flatMap({ UInt($0) })
            let fileSize = format.checking["filesize"]
                .flatMap({ Int64($0) })
            let fileSizeApprox = format.checking["filesize_approx"]
                .flatMap({ Int64($0) })
            
            let result = Format(
                id: id, title: title,
                browserUrl: browserUrl,
                width: width, height: height,
                fileSize: fileSize ?? fileSizeApprox
            )
            results.append(result)
        }
        return results
    }
    
    private func playlistEntries(from info: PythonObject, browserUrl: URL) throws -> [PlaylistEntry] {
        guard
            let entries = info.checking["entries"]
        else { throw "No entries" }
        
        var results: [PlaylistEntry] = []
        for entry in entries {
            guard
                let id = entry.checking["id"]
                    .flatMap({ String($0) }),
                let title = entry.checking["title"]
                    .flatMap({ String($0) })
            else { continue }
            
            let width = entry.checking["width"]
                .flatMap({ UInt($0) })
            let height = entry.checking["height"]
                .flatMap({ UInt($0) })
            let fileSize = entry.checking["filesize"]
                .flatMap({ Int64($0) })
            let fileSizeApprox = entry.checking["filesize_approx"]
                .flatMap({ Int64($0) })
            
            let result = PlaylistEntry(
                id: id, title: title,
                browserUrl: browserUrl,
                width: width, height: height,
                fileSize: fileSize ?? fileSizeApprox
            )
            results.append(result)
        }
        return results
    }
    
}

public class Formatter {
    
    public static let shared = Formatter()
    
    public lazy var byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
    
}

public protocol Downloadable: CustomStringConvertible {
    
    var id: String { get }
    var title: String { get }
    var browserUrl: URL { get }
    var width: UInt? { get }
    var height: UInt? { get }
    var fileSize: Int64? { get }
    
    var isUniqueTitle: Bool { get }
    
}

extension Downloadable {
    
    public var description: String {
        var parts = [String]()
        
        if isUniqueTitle {
            parts.append(title)
        }
        
        if let fileSize = fileSize {
            let sizeString = Formatter.shared.byteFormatter.string(fromByteCount: fileSize)
            parts.append(sizeString)
        }
        
        if let width = width, let height = height {
            parts.append("\(width)x\(height)")
        }
        
        let desc = parts.joined(separator: ", ")
        if desc.count == 0 {
            return id
        }
        
        return desc
    }
    
}

public struct PlaylistEntry: Downloadable {
    
    public let id: String
    public let title: String
    public let browserUrl: URL
    public let width: UInt?
    public let height: UInt?
    public let fileSize: Int64?
    
    public var isUniqueTitle: Bool { true }
    
}

public struct Format: Downloadable {
    
    public let id: String
    public let title: String
    public let browserUrl: URL
    public let width: UInt?
    public let height: UInt?
    public let fileSize: Int64?
    
    public var isUniqueTitle: Bool { false }
    
}
