// The Swift Programming Language
// https://docs.swift.org/swift-book

typealias NodeIndex = UInt32

let topBinCount: UInt32 = 32
let binPerLeafCount: UInt32 = 8
let topBinsIndexShift: UInt32 = 3
let leafBinsIndexMask: UInt32 = 0x7
let leafBinsCount = topBinCount * binPerLeafCount

public struct Allocation {
    public let offset: Int
    let metadata: NodeIndex
}

public struct StorageReport {
    let totalFreeSpace: UInt32
    let largestFreeRegion: UInt32
}

public struct FullStorageReport {
    public struct Region {
        public let size: UInt32
        public let count: UInt32
    }
    
    public let freeRegions: [Region]
}

public class Allocator {
    struct Node {
        var dataOffset: UInt32 = 0
        var dataSize: UInt32 = 0
        var binListPrev: NodeIndex = .max
        var binListNext: NodeIndex = .max
        var neighborPrev: NodeIndex = .max
        var neighborNext: NodeIndex = .max
        var used: Bool = false
        
        private var dataSizeSharedStorage: UInt32 = 0
        
        init() {
        }
        
        init(dataOffset: UInt32, dataSize: UInt32, binListNext: UInt32) {
            self.dataOffset = dataOffset
            self.dataSize = dataSize
            self.binListNext = binListNext
        }
    }
    
    private var size: UInt32
    private var maxAllocationCount: UInt32
    private var freeStorage: UInt32 = 0

    private var usedBinsTop: UInt32 = 0
    private var usedBins: [UInt8] = Array(repeating: 0, count: Int(topBinCount))
    private var binIndices: [NodeIndex] = Array(repeating: .max, count: Int(leafBinsCount))
                
    private var nodes: UnsafeMutablePointer<Node>
    private var freeNodes: [NodeIndex] = []
    private var freeOffset: UInt32 = 0

    public init(size: Int, maxAllocationCount: Int = 128 * 1024) {
        precondition(size > 0)
        precondition(maxAllocationCount > 0)
        precondition(maxAllocationCount <= size)
        
        self.size = UInt32(size)
        self.maxAllocationCount = UInt32(maxAllocationCount)
        
        nodes = .allocate(capacity: Int(maxAllocationCount))
        nodes.initialize(repeating: Node(), count: maxAllocationCount)
        
        freeStorage = 0
        usedBinsTop = 0
        freeOffset = UInt32(maxAllocationCount - 1)

        for i in 0..<Int(topBinCount) {
            usedBins[i] = 0
        }
        
        for i in 0..<Int(leafBinsCount) {
            binIndices[i] = .max
        }
        
        freeNodes = [NodeIndex](repeating: 0, count: maxAllocationCount)
        
        for i in 0..<Int(maxAllocationCount) {
            freeNodes[i] = UInt32(maxAllocationCount) - UInt32(i) - 1
        }
        
        _ = insertNodeIntoBin(size: UInt32(size), dataOffset: 0)
    }
    
    deinit {
        nodes.deallocate()
    }
    
    func allocate(size: UInt32) -> Allocation? {
        precondition(size >= 0)
        
        if freeOffset == 0 {
            return nil
        }
        
        let minBinIndex = SmallFloat.uintToFloatRoundUp(size)
        let minTopBinIndex = minBinIndex >> topBinsIndexShift
        let minLeafBinIndex = minBinIndex & leafBinsIndexMask
                
        var topBinIndex = minTopBinIndex
        var leafBinIndex: UInt32 = .max
        
        if (usedBinsTop & (1 << topBinIndex)) != 0 {
            leafBinIndex = findLowestSetBitAfter(bitMask: UInt32(usedBins[Int(topBinIndex)]), startBitIndex: minLeafBinIndex)
        }
    
        if leafBinIndex == .max {
            topBinIndex = findLowestSetBitAfter(bitMask: usedBinsTop, startBitIndex: minTopBinIndex + 1)
            
            if topBinIndex == .max {
                return nil
            }

            leafBinIndex = tzcnt_nonzero(UInt32(usedBins[Int(topBinIndex)]))
        }
        
        let binIndex = (topBinIndex << topBinsIndexShift) | leafBinIndex
        let nodeIndex = binIndices[Int(binIndex)]
        
        let pNode = nodes.advanced(by: Int(nodeIndex))
        
        let nodeTotalSize = pNode.pointee.dataSize
        pNode.pointee.dataSize = size
        pNode.pointee.used = true
        binIndices[Int(binIndex)] = pNode.pointee.binListNext
        if pNode.pointee.binListNext != .max {
            nodes[Int(pNode.pointee.binListNext)].binListPrev = .max
        }
        freeStorage -= nodeTotalSize
        
        if binIndices[Int(binIndex)] == .max {
            usedBins[Int(topBinIndex)] &= ~(1 << leafBinIndex)
            if usedBins[Int(topBinIndex)] == 0 {
                usedBinsTop &= ~(1 << topBinIndex)
            }
        }
        
        let reminderSize = nodeTotalSize - size
        if reminderSize > 0 {
            let newNodeIndex = insertNodeIntoBin(size: reminderSize, dataOffset: pNode.pointee.dataOffset + size)
            
            if pNode.pointee.neighborNext != .max {
                nodes[Int(pNode.pointee.neighborNext)].neighborPrev = newNodeIndex
            }
            nodes[Int(newNodeIndex)].neighborPrev = nodeIndex
            nodes[Int(newNodeIndex)].neighborNext = pNode.pointee.neighborNext
            pNode.pointee.neighborNext = newNodeIndex
        }
                
        return Allocation(offset: Int(pNode.pointee.dataOffset), metadata: nodeIndex)
    }
    
    func free(allocation: Allocation) {
        let nodeIndex = allocation.metadata
        
        let pNode = nodes.advanced(by: Int(nodeIndex))
        assert(pNode.pointee.used)
        
        var offset = pNode.pointee.dataOffset
        var size = pNode.pointee.dataSize
                            
        if (pNode.pointee.neighborPrev != .max) && (nodes[Int(pNode.pointee.neighborPrev)].used == false) {
            let prevNode = nodes[Int(pNode.pointee.neighborPrev)]
            offset = prevNode.dataOffset
            size += prevNode.dataSize
            
            removeNodeFromBin(at: pNode.pointee.neighborPrev)
            
            assert(prevNode.neighborNext == nodeIndex)
            pNode.pointee.neighborPrev = prevNode.neighborPrev
        }
        
        if (pNode.pointee.neighborNext != .max) && (nodes[Int(pNode.pointee.neighborNext)].used == false) {
            let nextNode = nodes[Int(pNode.pointee.neighborNext)]
            size += nextNode.dataSize
            
            removeNodeFromBin(at: pNode.pointee.neighborNext)
            
            assert(nextNode.neighborPrev == nodeIndex)
            pNode.pointee.neighborNext = nextNode.neighborNext
        }

        let neighborNext = pNode.pointee.neighborNext
        let neighborPrev = pNode.pointee.neighborPrev
        
        freeOffset += 1
        freeNodes[Int(freeOffset)] = nodeIndex

        let combinedNodeIndex = insertNodeIntoBin(size: size, dataOffset: offset)

        if neighborNext != .max {
            nodes[Int(combinedNodeIndex)].neighborNext = neighborNext
            nodes[Int(neighborNext)].neighborPrev = combinedNodeIndex
        }
        if neighborPrev != .max {
            nodes[Int(combinedNodeIndex)].neighborPrev = neighborPrev
            nodes[Int(neighborPrev)].neighborNext = combinedNodeIndex
        }
    }

    private func insertNodeIntoBin(size: UInt32, dataOffset: UInt32) -> NodeIndex {
        let binIndex = SmallFloat.uintToFloatRoundDown(size)
        let topBinIndex = binIndex >> topBinsIndexShift
        let leafBinIndex = binIndex & leafBinsIndexMask
        
        if binIndices[Int(binIndex)] == .max {
            usedBins[Int(topBinIndex)] |= 1 << leafBinIndex
            usedBinsTop |= 1 << topBinIndex
        }
        
        let topNodeIndex = binIndices[Int(binIndex)]
        let nodeIndex = freeNodes[Int(freeOffset)]
        freeOffset -= 1
                
        nodes[Int(nodeIndex)] = Node(dataOffset: dataOffset, dataSize: size, binListNext: topNodeIndex)
        
        if topNodeIndex != .max {
            nodes[Int(topNodeIndex)].binListPrev = nodeIndex
        }
        binIndices[Int(binIndex)] = nodeIndex
        
        freeStorage += size
        
        return nodeIndex
    }
    
    private func removeNodeFromBin(at index: NodeIndex) {
        let node = nodes[Int(index)]
        
        if node.binListPrev != .max {
            nodes[Int(node.binListPrev)].binListNext = node.binListNext
            if node.binListNext != .max {
                nodes[Int(node.binListNext)].binListPrev = node.binListPrev
            }
        } else {
            let binIndex = SmallFloat.uintToFloatRoundDown(node.dataSize)
            let topBinIndex = binIndex >> topBinsIndexShift
            let leafBinIndex = binIndex & leafBinsIndexMask
            
            binIndices[Int(binIndex)] = node.binListNext
            if node.binListNext != .max {
                nodes[Int(node.binListNext)].binListPrev = .max
            }

            if binIndices[Int(binIndex)] == .max {
                usedBins[Int(topBinIndex)] &= ~(1 << leafBinIndex)
                if usedBins[Int(topBinIndex)] == 0 {
                    usedBinsTop &= ~(1 << topBinIndex)
                }
            }
        }
        
        freeOffset += 1
        freeNodes[Int(freeOffset)] = index

        freeStorage -= node.dataSize
    }

    func allocationSize(allocation: Allocation) -> UInt32 {
        return nodes[Int(allocation.metadata)].dataSize
    }

    public func makeStorageReport() -> StorageReport {
        var largestFreeRegion: UInt32 = 0
        var freeStorage: UInt32 = 0
        
        if freeOffset > 0 {
            freeStorage = self.freeStorage
            if usedBinsTop != 0 {
                let topBinIndex = 31 - lzcnt_nonzero(usedBinsTop)
                let leafBinIndex = 31 - lzcnt_nonzero(UInt32(usedBins[Int(topBinIndex)]))
                largestFreeRegion = SmallFloat.floatToUint((topBinIndex << topBinsIndexShift) | leafBinIndex)
                assert(freeStorage >= largestFreeRegion)
            }
        }

        return StorageReport(totalFreeSpace: freeStorage, largestFreeRegion: largestFreeRegion)
    }

    public func makeFullStorageReport() -> FullStorageReport {
        let regions = (0..<Int(leafBinsCount)).map { i in
            var count: UInt32 = 0
            var nodeIndex = binIndices[i]
            while nodeIndex != .max {
                nodeIndex = nodes[Int(nodeIndex)].binListNext
                count += 1
            }
            
            return FullStorageReport.Region(size: SmallFloat.floatToUint(UInt32(i)), count: count)
        }
                
        return FullStorageReport(freeRegions: regions)
    }
}

func lzcnt_nonzero(_ v: UInt32) -> UInt32 {
#if os(Windows)
    var retVal: UInt32 = 0
    _BitScanReverse(&retVal, v)
    return 31 - retVal
#else
    return UInt32(v.leadingZeroBitCount)
#endif
}

func tzcnt_nonzero(_ v: UInt32) -> UInt32 {
#if os(Windows)
    var retVal: UInt32 = 0
    _BitScanForward(&retVal, v)
    return retVal
#else
    return UInt32(v.trailingZeroBitCount)
#endif
}

enum SmallFloat {
    static let mantissaBits: UInt32 = 3
    static let mantissaValue: UInt32 = 1 << mantissaBits
    static let mantissaMask: UInt32 = mantissaValue - 1
    
    static func uintToFloatRoundUp(_ size: UInt32) -> UInt32 {
        var exp: UInt32 = 0
        var mantissa: UInt32 = 0
        
        if size < mantissaValue {
            mantissa = size
        } else {
            let leadingZeros = lzcnt_nonzero(size)
            let highestSetBit = 31 - leadingZeros
            
            let mantissaStartBit = highestSetBit - mantissaBits
            exp = mantissaStartBit + 1
            mantissa = (size >> mantissaStartBit) & mantissaMask
            
            let lowBitsMask = UInt32((1 << mantissaStartBit) - 1)
            
            if (size & lowBitsMask) != 0 {
                mantissa += 1
            }
        }
        
        return (exp << mantissaBits) + mantissa
    }

    static func uintToFloatRoundDown(_ size: UInt32) -> UInt32 {
        var exp: UInt32 = 0
        var mantissa: UInt32 = 0
        
        if size < mantissaValue {
            mantissa = size
        } else {
            let leadingZeros = lzcnt_nonzero(size)
            let highestSetBit = 31 - leadingZeros
            
            let mantissaStartBit = highestSetBit - mantissaBits
            exp = mantissaStartBit + 1
            mantissa = (size >> mantissaStartBit) & mantissaMask
        }
        
        return (exp << mantissaBits) | mantissa
    }

    static func floatToUint(_ floatValue: UInt32) -> UInt32 {
        let exponent = floatValue >> mantissaBits
        let mantissa = floatValue & mantissaMask
        if exponent == 0 {
            return mantissa
        } else {
            return (mantissa | mantissaValue) << (exponent - 1)
        }
    }
}

func findLowestSetBitAfter(bitMask: UInt32, startBitIndex: UInt32) -> UInt32 {
    let maskBeforeStartIndex = UInt32((1 << startBitIndex) - 1)
    let maskAfterStartIndex = ~maskBeforeStartIndex
    let bitsAfter = bitMask & maskAfterStartIndex
    if bitsAfter == 0 { return .max }
    return tzcnt_nonzero(bitsAfter)
}
