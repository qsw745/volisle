// Test VM for Volisle: a macOS guest on Apple silicon (Virtualization.framework)
// with raw disk images plugged in as USB drives, attached and pulled while it
// runs, as a user plugs a disk in and out.
//
//   volisle-vm install <restore.ipsw> <bundle> [--disk-gb 80] [--cpus 4] [--memory-gb 8]
//   volisle-vm run <bundle> [--share <folder>] [--cpus 4] [--memory-gb 8]
//
// While it runs, commands go into <bundle>/control (a FIFO), one per line:
//   attach <image>   plug a raw disk image in as a USB drive
//   detach <image>   pull it out (no eject first: like pulling the cable)
//   list             what is plugged in
//   stop             ask the guest to shut down
// Status lines go to standard output. The shared folder appears in the guest
// at /Volumes/My Shared Files.
import AppKit
import Foundation
import Virtualization

struct VMBundle {
    let url: URL
    var disk: URL { url.appendingPathComponent("Disk.img") }
    var auxiliary: URL { url.appendingPathComponent("AuxiliaryStorage") }
    var hardwareModel: URL { url.appendingPathComponent("HardwareModel") }
    var machineIdentifier: URL { url.appendingPathComponent("MachineIdentifier") }
    var control: URL { url.appendingPathComponent("control") }
}

/// Fixed, so the guest's address can be found in the host's DHCP leases.
let guestMAC = "52:54:00:76:6f:6c"
/// Objects that must live as long as the process (installer, runner, observers).
var kept: [Any] = []

func say(_ text: String) { print(text); fflush(stdout) }
func fail(_ text: String) -> Never { FileHandle.standardError.write(Data((text + "\n").utf8)); exit(1) }

struct Options {
    var cpus = 4
    var memoryGB: UInt64 = 8
    var diskGB: UInt64 = 80
    var share: URL?

    init<S: Sequence>(_ arguments: S) where S.Element == String {
        var items = arguments.makeIterator()
        while let item = items.next() {
            switch item {
            case "--cpus": cpus = Int(items.next() ?? "") ?? cpus
            case "--memory-gb": memoryGB = UInt64(items.next() ?? "") ?? memoryGB
            case "--disk-gb": diskGB = UInt64(items.next() ?? "") ?? diskGB
            case "--share": share = items.next().map { URL(fileURLWithPath: $0) }
            default: fail("未知参数：\(item)")
            }
        }
    }
}

func configuration(_ bundle: VMBundle, model: VZMacHardwareModel, machine: VZMacMachineIdentifier,
                   options: Options) throws -> VZVirtualMachineConfiguration {
    let platform = VZMacPlatformConfiguration()
    platform.hardwareModel = model
    platform.machineIdentifier = machine
    platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: bundle.auxiliary)

    let config = VZVirtualMachineConfiguration()
    config.platform = platform
    config.bootLoader = VZMacOSBootLoader()
    config.cpuCount = options.cpus
    config.memorySize = options.memoryGB << 30
    let graphics = VZMacGraphicsDeviceConfiguration()
    graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: 2880, heightInPixels: 1800, pixelsPerInch: 220)]
    config.graphicsDevices = [graphics]
    let system = try VZDiskImageStorageDeviceAttachment(url: bundle.disk, readOnly: false)
    config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: system)]
    let network = VZVirtioNetworkDeviceConfiguration()
    network.attachment = VZNATNetworkDeviceAttachment()
    network.macAddress = VZMACAddress(string: guestMAC)!
    config.networkDevices = [network]
    config.pointingDevices = [VZMacTrackpadConfiguration(), VZUSBScreenCoordinatePointingDeviceConfiguration()]
    config.keyboards = [VZMacKeyboardConfiguration()]
    config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
    // USB drives are plugged in and out at run time through this controller.
    config.usbControllers = [VZXHCIControllerConfiguration()]
    if let share = options.share {
        let device = VZVirtioFileSystemDeviceConfiguration(tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
        device.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: share, readOnly: false))
        config.directorySharingDevices = [device]
    }
    try config.validate()
    return config
}

func install(_ ipsw: URL, into bundle: VMBundle, options: Options) {
    VZMacOSRestoreImage.load(from: ipsw) { result in
        DispatchQueue.main.async {
            do {
                let image = try result.get()
                let version = image.operatingSystemVersion
                let name = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)（\(image.buildVersion)）"
                guard let requirements = image.mostFeaturefulSupportedConfiguration,
                      requirements.hardwareModel.isSupported else { fail("这台 Mac 不能运行 macOS \(name) 的虚拟机") }
                let manager = FileManager.default
                guard !manager.fileExists(atPath: bundle.url.path) else { fail("目录已存在：\(bundle.url.path)") }
                try manager.createDirectory(at: bundle.url, withIntermediateDirectories: true)
                // Sparse: grows as the guest writes.
                let fd = open(bundle.disk.path, O_RDWR | O_CREAT | O_EXCL, 0o644)
                guard fd >= 0, ftruncate(fd, off_t(options.diskGB << 30)) == 0 else { fail("无法建立虚拟磁盘") }
                close(fd)
                _ = try VZMacAuxiliaryStorage(creatingStorageAt: bundle.auxiliary, hardwareModel: requirements.hardwareModel, options: [])
                try requirements.hardwareModel.dataRepresentation.write(to: bundle.hardwareModel)
                let machine = VZMacMachineIdentifier()
                try machine.dataRepresentation.write(to: bundle.machineIdentifier)
                var options = options
                options.cpus = max(options.cpus, requirements.minimumSupportedCPUCount)
                options.memoryGB = max(options.memoryGB, (requirements.minimumSupportedMemorySize + (1 << 30) - 1) >> 30)
                let vm = VZVirtualMachine(configuration: try configuration(bundle, model: requirements.hardwareModel,
                                                                            machine: machine, options: options))
                let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: ipsw)
                var reported = -1
                let observer = installer.progress.observe(\.fractionCompleted) { progress, _ in
                    let percent = Int(progress.fractionCompleted * 100)
                    if percent / 5 != reported / 5 { reported = percent; say("安装进度 \(percent)%") }
                }
                kept += [vm, installer, observer]
                say("开始安装 macOS \(name)，\(options.cpus) 核 \(options.memoryGB) GB 内存，磁盘 \(options.diskGB) GB")
                installer.install { result in
                    switch result {
                    case .success: say("安装完成：\(bundle.url.path)"); exit(0)
                    case .failure(let error): fail("安装失败：\(error.localizedDescription)")
                    }
                }
            } catch {
                fail("安装失败：\(error.localizedDescription)")
            }
        }
    }
}

final class Runner: NSObject, VZVirtualMachineDelegate, NSWindowDelegate {
    let bundle: VMBundle
    let vm: VZVirtualMachine
    private var window: NSWindow?
    private var plugged: [String: VZUSBMassStorageDevice] = [:]
    private var control: Int32 = -1
    private var source: DispatchSourceRead?
    private var pending = Data()

    init(bundle: VMBundle, configuration: VZVirtualMachineConfiguration) {
        self.bundle = bundle
        vm = VZVirtualMachine(configuration: configuration)
        super.init()
        vm.delegate = self
    }

    func start() {
        let view = VZVirtualMachineView()
        view.virtualMachine = vm
        view.capturesSystemKeys = true
        view.automaticallyReconfiguresDisplay = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "macOS 测试机 · 盘屿"
        window.contentView = view
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        vm.start { result in
            if case .failure(let error) = result { fail("启动失败：\(error.localizedDescription)") }
            say("已启动")
        }
        openControl()
    }

    private func openControl() {
        unlink(bundle.control.path)
        guard mkfifo(bundle.control.path, 0o600) == 0 else { fail("无法建立控制管道：\(bundle.control.path)") }
        // Read-write: the pipe never reports end of file between two writers.
        control = open(bundle.control.path, O_RDWR | O_NONBLOCK)
        guard control >= 0 else { fail("无法打开控制管道") }
        let source = DispatchSource.makeReadSource(fileDescriptor: control, queue: .main)
        source.setEventHandler { [weak self] in self?.readControl() }
        source.resume()
        self.source = source
        say("控制管道：\(bundle.control.path)")
    }

    private func readControl() {
        var chunk = [UInt8](repeating: 0, count: 4096)
        let count = read(control, &chunk, chunk.count)
        guard count > 0 else { return }
        pending.append(contentsOf: chunk[0..<count])
        while let newline = pending.firstIndex(of: 0x0a) {
            let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
            pending.removeSubrange(pending.startIndex...newline)
            handle(line.trimmingCharacters(in: .whitespaces))
        }
    }

    private func handle(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard let command = parts.first else { return }
        let argument = parts.count > 1 ? parts[1] : ""
        switch command {
        case "attach": attach(argument)
        case "detach": detach(argument)
        case "list": say("已插入：\(plugged.keys.sorted())")
        case "stop":
            do { try vm.requestStop(); say("已请求关机") } catch { say("无法请求关机：\(error.localizedDescription)") }
        default: say("未知命令：\(line)")
        }
    }

    private func attach(_ path: String) {
        let key = URL(fileURLWithPath: path).standardizedFileURL.path
        guard plugged[key] == nil else { return say("已经插着：\(key)") }
        guard let controller = vm.usbControllers.first else { return say("没有 USB 控制器") }
        do {
            // Full synchronization: what the guest flushed is on the host disk,
            // as on a real drive whose cache was flushed.
            let attachment = try VZDiskImageStorageDeviceAttachment(url: URL(fileURLWithPath: key), readOnly: false,
                                                                    cachingMode: .automatic, synchronizationMode: .full)
            let device = VZUSBMassStorageDevice(configuration: VZUSBMassStorageDeviceConfiguration(attachment: attachment))
            controller.attach(device: device) { error in
                DispatchQueue.main.async {
                    if let error { return say("插入失败：\(error.localizedDescription)") }
                    self.plugged[key] = device
                    say("已插入 USB：\(key)")
                }
            }
        } catch {
            say("插入失败：\(error.localizedDescription)")
        }
    }

    private func detach(_ path: String) {
        let key = URL(fileURLWithPath: path).standardizedFileURL.path
        guard let device = plugged[key], let controller = vm.usbControllers.first else { return say("没有插着：\(key)") }
        controller.detach(device: device) { error in
            DispatchQueue.main.async {
                if let error { return say("拔出失败：\(error.localizedDescription)") }
                self.plugged[key] = nil
                say("已拔出 USB：\(key)")
            }
        }
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        say("虚拟机已关机")
        unlink(bundle.control.path)
        exit(0)
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        say("虚拟机异常停止：\(error.localizedDescription)")
        unlink(bundle.control.path)
        exit(1)
    }

    /// Closing the window shuts the guest down instead of cutting it off.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        do { try vm.requestStop(); say("已请求关机（关闭了窗口）") } catch { say("无法请求关机：\(error.localizedDescription)") }
        return false
    }
}

@main
enum Main {
    static func main() {
        let arguments = CommandLine.arguments
        let usage = "用法：volisle-vm install <恢复镜像.ipsw> <虚拟机目录> [--disk-gb 80] [--cpus 4] [--memory-gb 8]\n      volisle-vm run <虚拟机目录> [--share <文件夹>] [--cpus 4] [--memory-gb 8]"
        guard arguments.count >= 3 else { fail(usage) }
        let app = NSApplication.shared
        switch arguments[1] {
        case "install":
            guard arguments.count >= 4 else { fail(usage) }
            app.setActivationPolicy(.prohibited)
            let ipsw = URL(fileURLWithPath: arguments[2])
            let bundle = VMBundle(url: URL(fileURLWithPath: arguments[3]))
            let options = Options(arguments.dropFirst(4))
            DispatchQueue.main.async { install(ipsw, into: bundle, options: options) }
        case "run":
            app.setActivationPolicy(.regular)
            let bundle = VMBundle(url: URL(fileURLWithPath: arguments[2]))
            let options = Options(arguments.dropFirst(3))
            guard let modelData = try? Data(contentsOf: bundle.hardwareModel),
                  let model = VZMacHardwareModel(dataRepresentation: modelData),
                  let machineData = try? Data(contentsOf: bundle.machineIdentifier),
                  let machine = VZMacMachineIdentifier(dataRepresentation: machineData) else {
                fail("不是安装好的虚拟机目录：\(bundle.url.path)")
            }
            do {
                let runner = Runner(bundle: bundle, configuration: try configuration(bundle, model: model, machine: machine, options: options))
                kept.append(runner)
                DispatchQueue.main.async { runner.start() }
            } catch {
                fail("配置无效：\(error.localizedDescription)")
            }
        default:
            fail(usage)
        }
        app.run()
    }
}
