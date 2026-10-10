// 第二轮：按"文件内容"核对。把手机上剩余文件下载到临时目录，计算 SHA-256，
// 与备份中同样大小的文件逐一比对，内容完全一致（含 Live Photo 视频部分）才删除。
// 用法: iphone_verify <备份根目录> <临时下载目录> <报告.csv> [--delete]
import Foundation
import CryptoKit
import ImageCaptureCore

let args = CommandLine.arguments
guard args.count >= 4 else { print("用法: iphone_verify <备份根目录> <临时目录> <报告.csv> [--delete]"); exit(1) }
let backupRoot = args[1], tmpDir = URL(fileURLWithPath: args[2]), reportPath = args[3]
let doDelete = args.contains("--delete")
try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

// ---------- 备份索引：大小 -> 路径 ----------
var bySize: [Int64: [String]] = [:]
let en = FileManager.default.enumerator(at: URL(fileURLWithPath: backupRoot),
                                        includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])!
for case let u as URL in en {
    guard let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true else { continue }
    bySize[Int64(v.fileSize ?? -1), default: []].append(u.path)
}
var hashCache: [String: String] = [:]
func sha(_ path: String) -> String? {
    if let h = hashCache[path] { return h }
    guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? fh.close() }
    var hasher = SHA256()
    while let d = try? fh.read(upToCount: 4 << 20), !d.isEmpty { hasher.update(data: d) }
    let h = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    hashCache[path] = h
    return h
}
func csv(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

final class Ctl: NSObject, ICDeviceBrowserDelegate, ICCameraDeviceDelegate {
    let browser = ICDeviceBrowser()
    var cam: ICCameraDevice?
    var tries = 0, sessionOpen = false
    var report = "状态,手机文件名,大小,备份路径或备注\n"
    var counts: [String: Int] = [:]
    var toDelete: [ICCameraFile] = []

    func start() {
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue:
            ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
        browser.start()
        print("正在查找 iPhone（请解锁手机并保持亮屏，关闭爱思助手）…")
    }
    func reopen() {
        guard let c = cam, !sessionOpen else { return }
        tries += 1
        guard tries <= 60 else { print("等待 3 分钟仍无法访问，退出。"); exit(3) }
        c.requestOpenSession()
    }
    func deviceBrowser(_ b: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard cam == nil, let c = device as? ICCameraDevice else { return }
        print("找到设备: \(c.name ?? "?")")
        cam = c; c.delegate = self; reopen()
    }
    func deviceBrowser(_ b: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {}
    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        guard let error else { sessionOpen = true; print("会话已打开，正在读取目录…"); return }
        print("打开失败: \(error.localizedDescription)，3 秒后重试…")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.reopen() }
    }

    // 一个"项"= 主文件 + 非 AAE 附属文件（Live Photo 视频）
    struct Job { let primary: ICCameraFile; let parts: [ICCameraFile] }
    var jobs: [Job] = []

    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        let all = (device.mediaFiles ?? []).compactMap { $0 as? ICCameraFile }
        var sidecarIDs = Set<ObjectIdentifier>()
        for f in all { for s in f.sidecarFiles ?? [] { sidecarIDs.insert(ObjectIdentifier(s)) } }
        for f in all where !sidecarIDs.contains(ObjectIdentifier(f)) {
            let parts = [f] + (f.sidecarFiles ?? []).compactMap { $0 as? ICCameraFile }
                .filter { !($0.name ?? "").uppercased().hasSuffix(".AAE") }
            if let miss = parts.first(where: { bySize[$0.fileSize] == nil }) {
                record("无同大小备份", f, miss === f ? "" : "附属文件 \(miss.name ?? "?") 无备份")
            } else {
                jobs.append(Job(primary: f, parts: parts))
            }
        }
        print("手机上剩余 \(all.count - sidecarIDs.count) 项；需下载核对 \(jobs.count) 项")
        nextJob(0)
    }

    func record(_ st: String, _ f: ICCameraFile, _ note: String) {
        counts[st, default: 0] += 1
        report += [st, f.name ?? "", "\(f.fileSize)", note].map(csv).joined(separator: ",") + "\n"
    }

    func nextJob(_ i: Int) {
        guard i < jobs.count else { summarize(); return }
        if i % 100 == 0 { print("  核对进度 \(i)/\(jobs.count)") }
        let job = jobs[i]
        verifyParts(job.parts[...], matched: []) { ok, note in
            if ok { self.toDelete.append(job.primary); self.record("内容一致", job.primary, note) }
            else { self.record("内容不一致", job.primary, note) }
            DispatchQueue.main.async { self.nextJob(i + 1) }
        }
    }

    func verifyParts(_ rest: ArraySlice<ICCameraFile>, matched: [String], done: @escaping (Bool, String) -> Void) {
        guard let f = rest.first else { done(true, matched.joined(separator: " | ")); return }
        let opts: [ICDownloadOption: Any] = [.downloadsDirectoryURL: tmpDir, .overwrite: true]
        _ = f.requestDownload(options: opts) { name, err in
            DispatchQueue.main.async {
                guard let name, err == nil else { done(false, "下载失败 \(f.name ?? "?"): \(err?.localizedDescription ?? "")"); return }
                let local = tmpDir.appendingPathComponent(name).path
                let h = sha(local)
                try? FileManager.default.removeItem(atPath: local)
                hashCache[local] = nil
                if let h, let hit = bySize[f.fileSize]?.first(where: { sha($0) == h }) {
                    self.verifyParts(rest.dropFirst(), matched: matched + [hit], done: done)
                } else {
                    done(false, "\(f.name ?? "?") 无内容相同的备份")
                }
            }
        }
    }

    func summarize() {
        try? report.write(toFile: reportPath, atomically: true, encoding: .utf8)
        for (k, v) in counts.sorted(by: { $0.key < $1.key }) { print("  \(k): \(v)") }
        print("报告已写入: \(reportPath)")
        guard doDelete else { print("预演模式，未删除任何文件。"); finish(); return }
        deleteBatches(toDelete[...], done: 0)
    }

    func deleteBatches(_ rest: ArraySlice<ICCameraFile>, done: Int) {
        guard let cam, !rest.isEmpty else { print("删除完成: \(done) 项"); finish(); return }
        let batch = Array(rest.prefix(100))
        _ = cam.requestDeleteFiles(batch, deleteFailed: { failed in
            for (k, _) in failed { print("  删除失败: \(k)") }
        }, completion: { _, err in
            if let err { print("批次出错: \(err.localizedDescription)") }
            let n = done + batch.count
            print("  已删除 \(n)/\(n + rest.count - batch.count)")
            DispatchQueue.main.async { self.deleteBatches(rest.dropFirst(batch.count), done: n) }
        })
    }

    func finish() { cam?.requestCloseSession(); DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(0) } }

    func didRemove(_ device: ICDevice) { print("设备已断开"); exit(2) }
    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) { print("访问限制已解除"); reopen() }
    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) { print("设备进入访问限制（锁屏？）") }
}

let ctl = Ctl()
ctl.start()
DispatchQueue.main.asyncAfter(deadline: .now() + 5400) { print("超时退出"); exit(4) }
RunLoop.main.run()
