// The Swift Programming Language
// https://docs.swift.org/swift-book

#if USE_16_BIT_NODE_INDICES
    typealias NodeIndex = UInt16
#else
    typealias NodeIndex = UInt32
#endif

let NUM_TOP_BINS: UInt32 = 32
let BINS_PER_LEAF: UInt32 = 8
let TOP_BINS_INDEX_SHIFT: UInt32 = 3
let LEAF_BINS_INDEX_MASK: UInt32 = 0x7
let NUM_LEAF_BINS = NUM_TOP_BINS * BINS_PER_LEAF

struct Allocation {
    static let NO_SPACE: UInt32 = 0xffffffff
    
    var offset: UInt32 = NO_SPACE
    var metadata: NodeIndex = NO_SPACE // internal: node index
}

struct StorageReport {
    var totalFreeSpace: UInt32
    var largestFreeRegion: UInt32
}

struct StorageReportFull {
    struct Region {
        var size: UInt32
        var count: UInt32
    }
    
    var freeRegions: [Region] = Array(repeating: Region(size: 0, count: 0), count: Int(NUM_LEAF_BINS))
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
    private var m_usedBins: [UInt8] = Array(repeating: 0, count: Int(NUM_TOP_BINS))
    private var m_binIndices: [NodeIndex] = Array(repeating: Node.unused, count: Int(NUM_LEAF_BINS))
                
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

        for i in 0..<Int(NUM_TOP_BINS) {
            m_usedBins[i] = 0
        }
        
        for i in 0..<Int(NUM_LEAF_BINS) {
            m_binIndices[i] = Node.unused
        }
        
        //m_nodes = [Node](repeating: Node(), count: Int(m_maxAllocs))
        m_freeNodes = [NodeIndex](repeating: 0, count: Int(m_maxAllocs))
        
        for i in 0..<Int(m_maxAllocs) {
            m_freeNodes[i] = m_maxAllocs - UInt32(i) - 1
        }
        
        _ = insertNodeIntoBin(size: m_size, dataOffset: 0)
    }
    
    func allocate(size: UInt32) -> Allocation {
        if m_freeOffset == 0 {
            return Allocation(offset: Allocation.NO_SPACE, metadata: Allocation.NO_SPACE)
        }
        
        let minBinIndex = SmallFloat.uintToFloatRoundUp(size)
        let minTopBinIndex = minBinIndex >> TOP_BINS_INDEX_SHIFT
        let minLeafBinIndex = minBinIndex & LEAF_BINS_INDEX_MASK
                
        var topBinIndex = minTopBinIndex
        var leafBinIndex: UInt32 = Allocation.NO_SPACE
        
        if (m_usedBinsTop & (1 << topBinIndex)) != 0 {
            leafBinIndex = findLowestSetBitAfter(bitMask: UInt32(m_usedBins[Int(topBinIndex)]), startBitIndex: minLeafBinIndex)
        }
    
        if leafBinIndex == Allocation.NO_SPACE {
            topBinIndex = findLowestSetBitAfter(bitMask: m_usedBinsTop, startBitIndex: minTopBinIndex + 1)
            
            if topBinIndex == Allocation.NO_SPACE {
                return Allocation(offset: Allocation.NO_SPACE, metadata: Allocation.NO_SPACE)
            }

            leafBinIndex = tzcnt_nonzero(UInt32(m_usedBins[Int(topBinIndex)]))
        }
        
        let binIndex = (topBinIndex << TOP_BINS_INDEX_SHIFT) | leafBinIndex
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
                
        return Allocation(offset: pNode.pointee.dataOffset, metadata: nodeIndex)
    }
    
    func free(allocation: Allocation) {
        assert(allocation.metadata != Allocation.NO_SPACE)
        
        let nodeIndex = allocation.metadata
        
        let pNode = m_nodes.advanced(by: Int(nodeIndex))
        assert(pNode.pointee.used)
        
        var offset = pNode.pointee.dataOffset
        var size = pNode.pointee.dataSize
        
        
        if (pNode.pointee.neighborPrev != Node.unused) {
            print("m_nodes[\(pNode.pointee.neighborPrev)].used = \(m_nodes[Int(pNode.pointee.neighborPrev)].used)")
        }
              
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
        let topBinIndex = binIndex >> TOP_BINS_INDEX_SHIFT
        let leafBinIndex = binIndex & LEAF_BINS_INDEX_MASK
        
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
            let topBinIndex = binIndex >> TOP_BINS_INDEX_SHIFT
            let leafBinIndex = binIndex & LEAF_BINS_INDEX_MASK
            
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
        if allocation.metadata == Allocation.NO_SPACE { return 0 }
        
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
                largestFreeRegion = SmallFloat.floatToUint((topBinIndex << TOP_BINS_INDEX_SHIFT) | leafBinIndex)
                assert(freeStorage >= largestFreeRegion)
            }
        }

        return StorageReport(totalFreeSpace: freeStorage, largestFreeRegion: largestFreeRegion)
    }

    func storageReportFull() -> StorageReportFull {
        var report = StorageReportFull()
        for i in 0..<Int(NUM_LEAF_BINS) {
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
    static let MANTISSA_BITS: UInt32 = 3
    static let MANTISSA_VALUE: UInt32 = 1 << MANTISSA_BITS
    static let MANTISSA_MASK: UInt32 = MANTISSA_VALUE - 1
    
    static func uintToFloatRoundUp(_ size: UInt32) -> UInt32 {
        var exp: UInt32 = 0
        var mantissa: UInt32 = 0
        
        if size < MANTISSA_VALUE {
            mantissa = size
        } else {
            let leadingZeros = lzcnt_nonzero(size)
            let highestSetBit = 31 - leadingZeros
            
            let mantissaStartBit = highestSetBit - MANTISSA_BITS
            exp = mantissaStartBit + 1
            mantissa = (size >> mantissaStartBit) & MANTISSA_MASK
            
            let lowBitsMask = UInt32((1 << mantissaStartBit) - 1)
            
            if (size & lowBitsMask) != 0 {
                mantissa += 1
            }
        }
        
        return (exp << MANTISSA_BITS) + mantissa
    }

    static func uintToFloatRoundDown(_ size: UInt32) -> UInt32 {
        var exp: UInt32 = 0
        var mantissa: UInt32 = 0
        
        if size < MANTISSA_VALUE {
            mantissa = size
        } else {
            let leadingZeros = lzcnt_nonzero(size)
            let highestSetBit = 31 - leadingZeros
            
            let mantissaStartBit = highestSetBit - MANTISSA_BITS
            exp = mantissaStartBit + 1
            mantissa = (size >> mantissaStartBit) & MANTISSA_MASK
        }
        
        return (exp << MANTISSA_BITS) | mantissa
    }

    static func floatToUint(_ floatValue: UInt32) -> UInt32 {
        let exponent = floatValue >> MANTISSA_BITS
        let mantissa = floatValue & MANTISSA_MASK
        if exponent == 0 {
            return mantissa
        } else {
            return (mantissa | MANTISSA_VALUE) << (exponent - 1)
        }
    }
}

func findLowestSetBitAfter(bitMask: UInt32, startBitIndex: UInt32) -> UInt32 {
    let maskBeforeStartIndex = UInt32((1 << startBitIndex) - 1)
    let maskAfterStartIndex = ~maskBeforeStartIndex
    let bitsAfter = bitMask & maskAfterStartIndex
    if bitsAfter == 0 { return Allocation.NO_SPACE }
    return tzcnt_nonzero(bitsAfter)
}
