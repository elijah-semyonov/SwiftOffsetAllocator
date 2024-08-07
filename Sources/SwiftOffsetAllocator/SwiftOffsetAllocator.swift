// The Swift Programming Language
// https://docs.swift.org/swift-book

#if USE_16_BIT_NODE_INDICES
    typealias NodeIndex = UInt16
#else
    typealias NodeIndex = UInt32
#endif

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

struct StorageReportFull {
    struct Region {
        var size: UInt32
        var count: UInt32
    }
    
    var freeRegions: [Region] = Array(repeating: Region(size: 0, count: 0), count: Int(leafBinsCount))
}

class Allocator {
    struct Node {
        static let unused: NodeIndex = 0xffffffff
        
        var dataOffset: UInt32 = 0
        var dataSize: UInt32 = 0
        var binListPrev: NodeIndex = Node.unused
        var binListNext: NodeIndex = Node.unused
        var neighborPrev: NodeIndex = Node.unused
        var neighborNext: NodeIndex = Node.unused
        var used: Bool = false // TODO: Merge as bit flag
    }
    
    private var m_size: UInt32
    private var m_maxAllocs: UInt32
    private var m_freeStorage: UInt32 = 0

    private var m_usedBinsTop: UInt32 = 0
    private var m_usedBins: [UInt8] = Array(repeating: 0, count: Int(topBinCount))
    private var m_binIndices: [NodeIndex] = Array(repeating: Node.unused, count: Int(leafBinsCount))
                
    private var m_nodes: UnsafeMutablePointer<Node>
    private var m_freeNodes: [NodeIndex] = []
    private var m_freeOffset: UInt32 = 0

    init(size: UInt32, maxAllocs: UInt32 = 128 * 1024) {
        self.m_size = size
        self.m_maxAllocs = maxAllocs
        
        m_nodes = .allocate(capacity: Int(m_maxAllocs))
        m_nodes.initialize(repeating: Node(), count: Int(m_maxAllocs))
        
        m_freeStorage = 0
        m_usedBinsTop = 0
        m_freeOffset = m_maxAllocs - 1

        for i in 0..<Int(topBinCount) {
            m_usedBins[i] = 0
        }
        
        for i in 0..<Int(leafBinsCount) {
            m_binIndices[i] = Node.unused
        }
        
        //m_nodes = [Node](repeating: Node(), count: Int(m_maxAllocs))
        m_freeNodes = [NodeIndex](repeating: 0, count: Int(m_maxAllocs))
        
        for i in 0..<Int(m_maxAllocs) {
            m_freeNodes[i] = m_maxAllocs - UInt32(i) - 1
        }
        
        _ = insertNodeIntoBin(size: m_size, dataOffset: 0)
    }
    
    func allocate(size: UInt32) -> Allocation? {
        if m_freeOffset == 0 {
            return nil
        }
        
        let minBinIndex = SmallFloat.uintToFloatRoundUp(size)
        let minTopBinIndex = minBinIndex >> topBinsIndexShift
        let minLeafBinIndex = minBinIndex & leafBinsIndexMask
                
        var topBinIndex = minTopBinIndex
        var leafBinIndex: UInt32 = .max
        
        if (m_usedBinsTop & (1 << topBinIndex)) != 0 {
            leafBinIndex = findLowestSetBitAfter(bitMask: UInt32(m_usedBins[Int(topBinIndex)]), startBitIndex: minLeafBinIndex)
        }
    
        if leafBinIndex == .max {
            topBinIndex = findLowestSetBitAfter(bitMask: m_usedBinsTop, startBitIndex: minTopBinIndex + 1)
            
            if topBinIndex == .max {
                return nil
            }

            leafBinIndex = tzcnt_nonzero(UInt32(m_usedBins[Int(topBinIndex)]))
        }
        
        let binIndex = (topBinIndex << topBinsIndexShift) | leafBinIndex
        let nodeIndex = m_binIndices[Int(binIndex)]
        
        let pNode = m_nodes.advanced(by: Int(nodeIndex))
        
        let nodeTotalSize = pNode.pointee.dataSize
        pNode.pointee.dataSize = size
        pNode.pointee.used = true
        m_binIndices[Int(binIndex)] = pNode.pointee.binListNext
        if pNode.pointee.binListNext != Node.unused {
            m_nodes[Int(pNode.pointee.binListNext)].binListPrev = Node.unused
        }
        m_freeStorage -= nodeTotalSize
        
        if m_binIndices[Int(binIndex)] == Node.unused {
            m_usedBins[Int(topBinIndex)] &= ~(1 << leafBinIndex)
            if m_usedBins[Int(topBinIndex)] == 0 {
                m_usedBinsTop &= ~(1 << topBinIndex)
            }
        }
        
        let reminderSize = nodeTotalSize - size
        if reminderSize > 0 {
            let newNodeIndex = insertNodeIntoBin(size: reminderSize, dataOffset: pNode.pointee.dataOffset + size)
            
            if pNode.pointee.neighborNext != Node.unused {
                m_nodes[Int(pNode.pointee.neighborNext)].neighborPrev = newNodeIndex
            }
            m_nodes[Int(newNodeIndex)].neighborPrev = nodeIndex
            m_nodes[Int(newNodeIndex)].neighborNext = pNode.pointee.neighborNext
            pNode.pointee.neighborNext = newNodeIndex
        }
                
        return Allocation(offset: Int(pNode.pointee.dataOffset), metadata: nodeIndex)
    }
    
    func free(allocation: Allocation) {
        let nodeIndex = allocation.metadata
        
        let pNode = m_nodes.advanced(by: Int(nodeIndex))
        assert(pNode.pointee.used)
        
        var offset = pNode.pointee.dataOffset
        var size = pNode.pointee.dataSize
                            
        if (pNode.pointee.neighborPrev != Node.unused) && (m_nodes[Int(pNode.pointee.neighborPrev)].used == false) {
            let prevNode = m_nodes[Int(pNode.pointee.neighborPrev)]
            offset = prevNode.dataOffset
            size += prevNode.dataSize
            
            removeNodeFromBin(nodeIndex: pNode.pointee.neighborPrev)
            
            assert(prevNode.neighborNext == nodeIndex)
            pNode.pointee.neighborPrev = prevNode.neighborPrev
        }
        
        if (pNode.pointee.neighborNext != Node.unused) && (m_nodes[Int(pNode.pointee.neighborNext)].used == false) {
            let nextNode = m_nodes[Int(pNode.pointee.neighborNext)]
            size += nextNode.dataSize
            
            removeNodeFromBin(nodeIndex: pNode.pointee.neighborNext)
            
            assert(nextNode.neighborPrev == nodeIndex)
            pNode.pointee.neighborNext = nextNode.neighborNext
        }

        let neighborNext = pNode.pointee.neighborNext
        let neighborPrev = pNode.pointee.neighborPrev
        
        m_freeOffset += 1
        m_freeNodes[Int(m_freeOffset)] = nodeIndex

        let combinedNodeIndex = insertNodeIntoBin(size: size, dataOffset: offset)

        if neighborNext != Node.unused {
            m_nodes[Int(combinedNodeIndex)].neighborNext = neighborNext
            m_nodes[Int(neighborNext)].neighborPrev = combinedNodeIndex
        }
        if neighborPrev != Node.unused {
            m_nodes[Int(combinedNodeIndex)].neighborPrev = neighborPrev
            m_nodes[Int(neighborPrev)].neighborNext = combinedNodeIndex
        }
    }

    private func insertNodeIntoBin(size: UInt32, dataOffset: UInt32) -> NodeIndex {
        let binIndex = SmallFloat.uintToFloatRoundDown(size)
        let topBinIndex = binIndex >> topBinsIndexShift
        let leafBinIndex = binIndex & leafBinsIndexMask
        
        if m_binIndices[Int(binIndex)] == Node.unused {
            m_usedBins[Int(topBinIndex)] |= 1 << leafBinIndex
            m_usedBinsTop |= 1 << topBinIndex
        }
        
        let topNodeIndex = m_binIndices[Int(binIndex)]
        let nodeIndex = m_freeNodes[Int(m_freeOffset)]
        m_freeOffset -= 1
                
        m_nodes[Int(nodeIndex)] = Node(dataOffset: dataOffset, dataSize: size, binListNext: topNodeIndex)
        
        if topNodeIndex != Node.unused {
            m_nodes[Int(topNodeIndex)].binListPrev = nodeIndex
        }
        m_binIndices[Int(binIndex)] = nodeIndex
        
        m_freeStorage += size
        
        return nodeIndex
    }
    
    private func removeNodeFromBin(nodeIndex: NodeIndex) {
        let node = m_nodes[Int(nodeIndex)]
        
        if node.binListPrev != Node.unused {
            m_nodes[Int(node.binListPrev)].binListNext = node.binListNext
            if node.binListNext != Node.unused {
                m_nodes[Int(node.binListNext)].binListPrev = node.binListPrev
            }
        } else {
            let binIndex = SmallFloat.uintToFloatRoundDown(node.dataSize)
            let topBinIndex = binIndex >> topBinsIndexShift
            let leafBinIndex = binIndex & leafBinsIndexMask
            
            m_binIndices[Int(binIndex)] = node.binListNext
            if node.binListNext != Node.unused {
                m_nodes[Int(node.binListNext)].binListPrev = Node.unused
            }

            if m_binIndices[Int(binIndex)] == Node.unused {
                m_usedBins[Int(topBinIndex)] &= ~(1 << leafBinIndex)
                if m_usedBins[Int(topBinIndex)] == 0 {
                    m_usedBinsTop &= ~(1 << topBinIndex)
                }
            }
        }
        
        m_freeOffset += 1
        m_freeNodes[Int(m_freeOffset)] = nodeIndex

        m_freeStorage -= node.dataSize
    }

    func allocationSize(allocation: Allocation) -> UInt32 {
        return m_nodes[Int(allocation.metadata)].dataSize
    }

    func storageReport() -> StorageReport {
        var largestFreeRegion: UInt32 = 0
        var freeStorage: UInt32 = 0
        
        if m_freeOffset > 0 {
            freeStorage = m_freeStorage
            if m_usedBinsTop != 0 {
                let topBinIndex = 31 - lzcnt_nonzero(m_usedBinsTop)
                let leafBinIndex = 31 - lzcnt_nonzero(UInt32(m_usedBins[Int(topBinIndex)]))
                largestFreeRegion = SmallFloat.floatToUint((topBinIndex << topBinsIndexShift) | leafBinIndex)
                assert(freeStorage >= largestFreeRegion)
            }
        }

        return StorageReport(totalFreeSpace: freeStorage, largestFreeRegion: largestFreeRegion)
    }

    func storageReportFull() -> StorageReportFull {
        var report = StorageReportFull()
        for i in 0..<Int(leafBinsCount) {
            var count: UInt32 = 0
            var nodeIndex = m_binIndices[i]
            while nodeIndex != Node.unused {
                nodeIndex = m_nodes[Int(nodeIndex)].binListNext
                count += 1
            }
            report.freeRegions[i] = StorageReportFull.Region(size: SmallFloat.floatToUint(UInt32(i)), count: count)
        }
        return report
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
