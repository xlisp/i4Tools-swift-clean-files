// 只删除 iPhone 上"已在电脑上完整备份"的照片/视频。
// 用法: swift iphone_prune.swift <备份根目录> <报告.csv> [--delete]
// 不带 --delete 时只预演，不删除任何东西。
// 匹配规则: 文件名相同 + 文件大小完全相同 + 拍摄时间相差 ≤2 秒；Live Photo 的视频部分也必须匹配。
import Foundation
import ImageCaptureCore

let args = CommandLine.arguments
guard args.count >= 3 else { print("用法: swift iphone_prune.swift <备份根目录> <报告.csv> [--delete]"); exit(1) }
let backupRoot = args[1], reportPath = args[2]
let doDelete = args.contains("--delete")

// ---------- 建立备份索引 ----------
struct BFile { let size: Int64; let date: Date; let path: String }
var index: [String: [BFile]] = [:]
let stampFmt = DateFormatter()
stampFmt.dateFormat = "yyyy_MM_dd_HH_mm_ss"
stampFmt.timeZone = .current
let re = try! NSRegularExpression(pattern: "^(\\d{4}_\\d{2}_\\d{2}_\\d{2}_\\d{2}_\\d{2})_(.+)$")
let en = FileManager.default.enumerator(at: URL(fileURLWithPath: backupRoot),
                                        includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])!
var nBackup = 0
for case let u as URL in en {
    guard let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true else { continue }
    let n = u.lastPathComponent as NSString
    guard let m = re.firstMatch(in: n as String, range: NSRange(location: 0, length: n.length)),
          let d = stampFmt.date(from: n.substring(with: m.range(at: 1))) else { continue }
    let name = n.substring(with: m.range(at: 2)).uppercased()
    index[name, default: []].append(BFile(size: Int64(v.fileSize ?? -1), date: d, path: u.path))
    nBackup += 1
}
print("备份索引: \(nBackup) 个文件")

// ---------- 比对 ----------
enum Status: String { case ok = "已备份", noFile = "未找到备份", sizeDiff = "大小不符", dateDiff = "时间不符" }
func check(_ f: ICCameraFile) -> (Status, String) {
    guard let name = f.name?.uppercased(), let cands = index[name] else { return (.noFile, "") }
    let sized = cands.filter { $0.size == f.fileSize }
    if sized.isEmpty { return (.sizeDiff, cands.map { "\($0.size)" }.joined(separator: "|")) }
    let dates = [f.exifCreationDate, f.fileCreationDate, f.creationDate].compactMap { $0 }
    if let b = sized.first(where: { b in dates.contains { abs($0.timeIntervalSince(b.date)) <= 2 } }) { return (.ok, b.path) }
    return (.dateDiff, sized[0].path)
}
func csv(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

final class Ctl: NSObject, ICDeviceBrowserDelegate, ICCameraDeviceDelegate {
    let browser = ICDeviceBrowser()
    var cam: ICCameraDevice?

    func start() {
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue:
            ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
        browser.start()
        print("正在查找 iPhone（请解锁手机并保持亮屏）…")
    }

    func deviceBrowser(_ b: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard cam == nil, let c = device as? ICCameraDevice else { return }
        print("找到设备: \(c.name ?? "?")，正在读取目录（文件多时需几分钟）…")
        cam = c; c.delegate = self; c.requestOpenSession()
    }
    func deviceBrowser(_ b: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {}

    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        let all = (device.mediaFiles ?? []).compactMap { $0 as? ICCameraFile }
        // Live Photo 视频等作为 sidecar 挂在主文件下，不单独处理
        var sidecarIDs = Set<ObjectIdentifier>()
        for f in all { for s in f.sidecarFiles ?? [] { sidecarIDs.insert(ObjectIdentifier(s)) } }
        let primaries = all.filter { !sidecarIDs.contains(ObjectIdentifier($0)) }

        var report = "状态,手机文件名,手机大小,拍摄时间,备份路径或备注\n"
        var toDelete: [ICCameraFile] = []
        var counts: [String: Int] = [:]
        let iso = ISO8601DateFormatter(); iso.timeZone = .current
        for f in primaries {
            var (st, note) = check(f)
            if st == .ok {
                for s in (f.sidecarFiles ?? []).compactMap({ $0 as? ICCameraFile }) where (s.name ?? "").uppercased().hasSuffix(".AAE") == false {
                    let (ss, _) = check(s)
                    if ss != .ok { st = ss; note = "Live/附属文件 \(s.name ?? "?") \(ss.rawValue)"; break }
                }
            }
            counts[st.rawValue, default: 0] += 1
            if st == .ok { toDelete.append(f) }
            let d = f.exifCreationDate ?? f.creationDate
            report += [st.rawValue, f.name ?? "", "\(f.fileSize)", d.map { iso.string(from: $0) } ?? "", note].map(csv).joined(separator: ",") + "\n"
        }
        try? report.write(toFile: reportPath, atomically: true, encoding: .utf8)
        print("手机上共 \(primaries.count) 项（另有 \(sidecarIDs.count) 个附属文件）")
        for (k, v) in counts.sorted(by: { $0.key < $1.key }) { print("  \(k): \(v)") }
        print("报告已写入: \(reportPath)")

        guard doDelete else { print("预演模式，未删除任何文件。"); finish(); return }
        guard device.capabilities.contains(ICDeviceCapability.cameraDeviceCanDeleteOneFile.rawValue) else {
            print("该设备不允许删除文件（请确认手机已解锁并信任此电脑）"); finish(); return
        }
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
            print("  已处理 \(n)/\(n + rest.count - batch.count)")
            DispatchQueue.main.async { self.deleteBatches(rest.dropFirst(batch.count), done: n) }
        })
    }

    func finish() { cam?.requestCloseSession(); DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(0) } }

    // 其余必需的代理方法
    func didRemove(_ device: ICDevice) { print("设备已断开"); exit(2) }
    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) { if let error { print("打开会话失败: \(error)"); exit(3) } }
    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
}

let ctl = Ctl()
ctl.start()
DispatchQueue.main.asyncAfter(deadline: .now() + 1800) { print("超时退出"); exit(4) }
RunLoop.main.run()
