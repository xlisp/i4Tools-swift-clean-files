// 删除 iPhone 上所有可见的照片/视频（不做备份比对）。
// 用法: iphone_wipe <清单.txt> [--delete]   不带 --delete 只列出不删除
import Foundation
import ImageCaptureCore

let args = CommandLine.arguments
guard args.count >= 2 else { print("用法: iphone_wipe <清单.txt> [--delete]"); exit(1) }
let listPath = args[1]
let doDelete = args.contains("--delete")

final class Ctl: NSObject, ICDeviceBrowserDelegate, ICCameraDeviceDelegate {
    let browser = ICDeviceBrowser()
    var cam: ICCameraDevice?
    var tries = 0, sessionOpen = false

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

    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        let all = (device.mediaFiles ?? []).compactMap { $0 as? ICCameraFile }
        var sidecarIDs = Set<ObjectIdentifier>()
        for f in all { for s in f.sidecarFiles ?? [] { sidecarIDs.insert(ObjectIdentifier(s)) } }
        let primaries = all.filter { !sidecarIDs.contains(ObjectIdentifier($0)) }
        let list = primaries.map { "\($0.name ?? "?")\t\($0.fileSize)" }.joined(separator: "\n")
        try? list.write(toFile: listPath, atomically: true, encoding: .utf8)
        print("手机上共 \(primaries.count) 项，清单已写入: \(listPath)")
        guard doDelete else { print("预演模式，未删除任何文件。"); finish(); return }
        deleteBatches(primaries[...], done: 0)
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
DispatchQueue.main.asyncAfter(deadline: .now() + 1800) { print("超时退出"); exit(4) }
RunLoop.main.run()
