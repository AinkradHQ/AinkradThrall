import Foundation
import Virtualization

/// Builds the VM: direct Linux boot, a read-write root disk, the data disk,
/// NAT networking, a vsock device (the Docker socket bridge) and a console
/// written to `console.log`.
enum ThrallVZConfiguration {
    static func make(
        spec: ThrallVMSpec,
        paths: ThrallEnginePaths,
        console: FileHandle
    ) throws -> VZVirtualMachineConfiguration {
        try ThrallEngineDisk.checkImage(paths)
        try ThrallEngineDisk.prepareDataDisk(at: paths.dataDisk, size: spec.dataDiskBytes)

        let bootLoader = VZLinuxBootLoader(kernelURL: paths.kernel)
        bootLoader.initialRamdiskURL = paths.initialRamdisk
        bootLoader.commandLine = ThrallVMSpec.kernelCommandLine

        let configuration = VZVirtualMachineConfiguration()
        configuration.platform = VZGenericPlatformConfiguration()
        configuration.bootLoader = bootLoader
        configuration.cpuCount = min(
            max(spec.cpuCount, VZVirtualMachineConfiguration.minimumAllowedCPUCount),
            VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        configuration.memorySize = min(
            max(spec.memoryBytes, VZVirtualMachineConfiguration.minimumAllowedMemorySize),
            VZVirtualMachineConfiguration.maximumAllowedMemorySize)

        configuration.storageDevices = [
            try disk(paths.rootFilesystem),  // /dev/vda
            try disk(paths.dataDisk),  // /dev/vdb
        ]

        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        network.macAddress = try macAddress(at: paths.macAddress)
        configuration.networkDevices = [network]

        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        serial.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: nil, fileHandleForWriting: console)
        configuration.serialPorts = [serial]

        configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        configuration.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        do {
            try configuration.validate()
        } catch {
            throw ThrallEngineConfigError.invalidConfiguration(error.localizedDescription)
        }
        return configuration
    }

    private static func disk(_ url: URL) throws -> VZVirtioBlockDeviceConfiguration {
        VZVirtioBlockDeviceConfiguration(
            attachment: try VZDiskImageStorageDeviceAttachment(url: url, readOnly: false))
    }

    /// Reads the saved MAC, or generates and saves one on first boot.
    private static func macAddress(at url: URL) throws -> VZMACAddress {
        if let saved = try? String(contentsOf: url, encoding: .utf8) {
            let value = saved.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let address = VZMACAddress(string: value) else {
                throw ThrallEngineConfigError.invalidMACAddress(value)
            }
            return address
        }
        let address = VZMACAddress.randomLocallyAdministered()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try address.string.write(to: url, atomically: true, encoding: .utf8)
        return address
    }
}
