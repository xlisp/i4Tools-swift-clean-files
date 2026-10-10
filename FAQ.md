## 需要打开never不熄屏模式：设置里面的显示里面

```
❯ 我并没有锁屏啊，怎么执行失败？
  ❯ "/private/tmp/claude-501/-Users-xlisp-Downloads-i4ToolsDownloads-CustomizedBackup-Shunli-iPhone-2026-10-10-8-53-21--Photos------HEIC-files/e07e8177-39d0-4028-a625-26fbeed55857/scratchpad/iphone_prune" "/Users/xlisp/Downloads/i4ToolsDownloads/CustomizedBackup/Shunli的iPhone(2026-10-10-8-53-21)/Photos/相机胶卷" "/private/tmp/claude-501/-Users-xlisp-Downloads-i4ToolsDownloads-CustomizedBackup-Shunli-iPhone-2026-10-10-8-53-21--Photos------HEIC-files/e07e8177-39d0-4028-a625-26fbeed55857/scratchpad/report.csv" --delete

  备份索引: 15181 个文件
  正在查找 iPhone（请解锁手机并保持亮屏）…

  找到设备: Shunli的iPhone，正在读取目录（文件多时需几分钟）…
  打开会话失败: Error Domain=com.apple.ImageCaptureCore Code=-9943 "Please unlock “Shunli的iPhone”" UserInfo={NSLocalizedDescription=Please unlock “Shunli的iPhone”}

  /private/tmp/claude-501/-Users-xlisp-Downloads-i4ToolsDownloads-CustomizedBackup-Shunli-iPhone-2026-10-10-8-53-21--Photos------HEIC-files/e07e8177-39d0-4028-a625-26fbeed55857/scratchpad 1m 8s
  ❯

这个报错不一定是真的锁屏了。ImageCaptureCore 在两种情况下都会报「Please unlock」：手机刚连接时访问限制还没解除（会话打开得太早），或者另一个思助手、照片App、图像捕捉。我的脚本第一次失败就直接退出了，处理得太粗糙。现在改成：遇到这个错误先等待，等系统通知访问限制解除后自动重试，同时打印手机当前的状态，方便排查。

  Ran 2 shell commands

找到一个很可能的原因：爱思助手（i4Tools）还开着，它可能一直占着和 iPhone 的连接。手机在连接期间也可能自动锁屏或进入访问限制，这样我的脚本就拿不到访问权限。

我已经把脚本改成会自动等待并重试，最多等 3 分钟，不会再一失败就退出。现在请你：

1. 完全退出爱思助手：在菜单栏里选「爱思助手」→「退出」，或者按 ⌘Q。只关掉窗口是不够的。
2. 确认「照片」App 和「图像捕捉」也没有打开。
3. 拔掉数据线再重新插上。iPhone 解锁并停留在主屏幕；如果弹出「信任此电脑」，点信任并输入锁屏密码。
4. 回复「好了」，我就带 --delete 执行。

脚本运行时会打印每次重试的状态。如果还是「访问受限=true」，说明手机  继续排查。

```
