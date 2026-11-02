import Foundation
import DiscImageCore

/// ECC 簇组装：LDC（304 × RS(248,216)）、BIS（地址 + RS(9,5) + RS(62,30)）与复用。
///
/// 返回的字节是 DC 控制位、17PP 与 RUB 之前的样子，**不是**可刻录镜像：
/// 它只包含 EDC、扰码、LDC/BIS 校验与交织。
public enum BluRayECCEncoder {
    public static let sectorsPerCluster = BluRaySpec.sectorsPerCluster
    public static let payloadBytes = BluRaySpec.payloadBytesPerCluster
    public static let recordingFrames = BluRaySpec.recordingFrames
    public static let eccBytesPerFrame = BluRaySpec.eccBytesPerFrame
    public static let eccClusterBytes = BluRaySpec.eccClusterBytes
    public static let ldcClusterBytes = BluRaySpec.ldcClusterBytes
    public static let bisClusterBytes = BluRaySpec.bisClusterBytes
    public static let userControlBytes = BluRaySpec.userControlBytesPerCluster

    /// ECC 复用后的 496 行 × 155 字节。
    public static func encode(
        userData: [UInt8],
        firstPhysicalSectorNumber: UInt32,
        addressFlags: [UInt8] = [],
        userControlData: [UInt8] = []
    ) throws -> [UInt8] {
        let ldc = try encodeLDCCluster(userData: userData, firstPhysicalSectorNumber: firstPhysicalSectorNumber)
        let bis = try encodeBISCluster(
            firstPhysicalSectorNumber: firstPhysicalSectorNumber,
            addressFlags: addressFlags,
            userControlData: userControlData
        )
        var ecc = [UInt8](repeating: 0, count: eccClusterBytes)
        for row in 0..<recordingFrames {
            for group in 0..<4 {
                let sourceOffset = row * 152 + group * 38
                let destinationOffset = row * 155 + group * 39
                ecc.replaceSubrange(
                    destinationOffset..<(destinationOffset + 38),
                    with: ldc[sourceOffset..<(sourceOffset + 38)]
                )
                if group < 3 {
                    ecc[destinationOffset + 38] = bis[row * 3 + group]
                }
            }
        }
        return ecc
    }

    /// 496 行 × 152 字节的 LDC 交织结果（录制顺序）。
    public static func encodeLDCCluster(userData: [UInt8], firstPhysicalSectorNumber: UInt32) throws -> [UInt8] {
        try validatePSN(firstPhysicalSectorNumber)
        guard userData.count == payloadBytes else {
            throw DiscError.encoding("一个 BD 簇必须包含 65,536 个用户字节（当前 \(userData.count)）")
        }
        // 32 个 data frame（payload + EDC）排成 65,664 字节 = 304 × 216，
        // 与 LDC 的 304 个码字 × 216 个数据字节一一对应。
        var dataBlock = [UInt8](repeating: 0, count: BluRaySpec.dataBytesPerCluster)
        let mask = BluRayScrambler.mask(physicalSectorNumber: firstPhysicalSectorNumber)
        var frame = [UInt8](repeating: 0, count: BluRaySpec.dataFrameBytes)
        for sector in 0..<sectorsPerCluster {
            let start = sector * BluRaySpec.bytesPerSector
            try BluRayEDC.writeDataFrame(
                userData: Array(userData[start..<(start + BluRaySpec.bytesPerSector)]),
                into: &frame
            )
            let base = sector * BluRaySpec.dataFrameBytes
            for index in 0..<BluRaySpec.dataFrameBytes {
                dataBlock[base + index] = frame[index] ^ mask[index]
            }
        }

        var cluster = [UInt8](repeating: 0, count: ldcClusterBytes)
        var codeword = [UInt8](repeating: 0, count: BluRaySpec.ldccodewordBytes)
        for column in 0..<BluRaySpec.ldcCodewords {
            let base = column * BluRaySpec.ldcDataBytes
            codeword.replaceSubrange(0..<BluRaySpec.ldcDataBytes, with: dataBlock[base..<(base + BluRaySpec.ldcDataBytes)])
            let parity = try BluRayReedSolomon.parity(
                information: Array(codeword[0..<BluRaySpec.ldcDataBytes]),
                parityLength: BluRaySpec.ldcParityBytes
            )
            codeword.replaceSubrange(BluRaySpec.ldcDataBytes..<BluRaySpec.ldccodewordBytes, with: parity)
            for row in 0..<BluRaySpec.ldccodewordBytes {
                let outputRow = row * 2 + column % 2
                let outputColumn = (column / 2 + 152 - (row * 3) % 152) % 152
                cluster[outputRow * 152 + outputColumn] = codeword[row]
            }
        }
        return cluster
    }

    /// 496 行 × 3 字节的 BIS 交织结果。
    public static func encodeBISCluster(
        firstPhysicalSectorNumber: UInt32,
        addressFlags: [UInt8] = [],
        userControlData: [UInt8] = []
    ) throws -> [UInt8] {
        try validatePSN(firstPhysicalSectorNumber)
        guard addressFlags.isEmpty || addressFlags.count == 16 else {
            throw DiscError.encoding("addressFlags 必须为空或 16 字节（每个地址单元一个）")
        }
        guard userControlData.isEmpty || userControlData.count == userControlBytes else {
            throw DiscError.encoding("userControlData 必须为空或 32 × 18 = 576 字节")
        }

        // 访问块按列优先：每个缩短 RS 字连续。
        var access = [UInt8](repeating: 0, count: 24 * 30)
        for unit in 0..<16 {
            var address = [UInt8](repeating: 0, count: 9)
            let psn = firstPhysicalSectorNumber &+ UInt32(unit * 2)
            address[0] = UInt8((psn >> 24) & 0xFF)
            address[1] = UInt8((psn >> 16) & 0xFF)
            address[2] = UInt8((psn >> 8) & 0xFF)
            address[3] = UInt8(psn & 0xFF)
            address[4] = addressFlags.isEmpty ? 0 : addressFlags[unit]
            let parity = try BluRayReedSolomon.parity(information: Array(address[0..<5]), parityLength: 4)
            address.replaceSubrange(5..<9, with: parity)
            for x in 0..<9 {
                let row = 2 * (x / 3) + unit / 8
                let column = 3 * ((x / 3 + 16 - unit) % 8) + (x - x / 3) % 3
                access[column * 30 + row] = address[x]
            }
        }
        if !userControlData.isEmpty {
            for index in 0..<userControlBytes {
                access[(index / 24) * 30 + 6 + index % 24] = userControlData[index]
            }
        }

        var cluster = [UInt8](repeating: 0, count: bisClusterBytes)
        var codeword = [UInt8](repeating: 0, count: 62)
        for column in 0..<24 {
            codeword.replaceSubrange(0..<30, with: access[(column * 30)..<(column * 30 + 30)])
            let parity = try BluRayReedSolomon.parity(information: Array(codeword[0..<30]), parityLength: 32)
            codeword.replaceSubrange(30..<62, with: parity)
            for row in 0..<62 {
                let unit = (row / 2 + 8 - column / 3) % 8 + 8 * (row % 2)
                let unitRow = row / 2
                let outputColumn = (column + unitRow) % 3
                cluster[(unit * 31 + unitRow) * 3 + outputColumn] = codeword[row]
            }
        }
        return cluster
    }

    /// 簇起始 PSN 必须是 32 的倍数，且高 5 位保留位为 0。
    static func validatePSN(_ psn: UInt32) throws {
        guard psn & 31 == 0, psn <= 0x07FF_FFE0 else {
            throw DiscError.encoding("簇 PSN 必须是 32 的倍数且保留位 bit31…27 为 0（当前 0x\(String(psn, radix: 16))）")
        }
    }
}
