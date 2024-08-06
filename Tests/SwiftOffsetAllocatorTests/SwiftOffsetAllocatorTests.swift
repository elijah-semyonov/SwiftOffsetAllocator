import XCTest
@testable import SwiftOffsetAllocator

class SmallFloatTests: XCTestCase {
    
    func testUintToFloat() {
        // Denorms, exp=1 and exp=2 + mantissa = 0 are all precise.
        // NOTE: Assuming 8 value (3 bit) mantissa.
        // If this test fails, please change this assumption!
        let preciseNumberCount: UInt32 = 17
        for i in 0..<preciseNumberCount {
            let roundUp = SmallFloat.uintToFloatRoundUp(i)
            let roundDown = SmallFloat.uintToFloatRoundDown(i)
            XCTAssertEqual(i, roundUp)
            XCTAssertEqual(i, roundDown)
        }
        
        // Test some random picked numbers
        let testData: [(number: UInt32, up: UInt32, down: UInt32)] = [
            (number: 17, up: 17, down: 16),
            (number: 118, up: 39, down: 38),
            (number: 1024, up: 64, down: 64),
            (number: 65536, up: 112, down: 112),
            (number: 529445, up: 137, down: 136),
            (number: 1048575, up: 144, down: 143),
        ]
        
        for v in testData {
            let roundUp = SmallFloat.uintToFloatRoundUp(v.number)
            let roundDown = SmallFloat.uintToFloatRoundDown(v.number)
            XCTAssertEqual(roundUp, v.up)
            XCTAssertEqual(roundDown, v.down)
        }
    }
    
    func testFloatToUint() {
        // Denorms, exp=1 and exp=2 + mantissa = 0 are all precise.
        // NOTE: Assuming 8 value (3 bit) mantissa.
        // If this test fails, please change this assumption!
        let preciseNumberCount: UInt32 = 17
        for i in 0..<preciseNumberCount {
            let v = SmallFloat.floatToUint(i)
            XCTAssertEqual(i, v)
        }
        
        // Test that float->uint->float conversion is precise for all numbers
        // NOTE: Test values < 240. 240->4G = overflows 32 bit integer
        for i in 0..<UInt32(240){
            let v = SmallFloat.floatToUint(UInt32(i))
            let roundUp = SmallFloat.uintToFloatRoundUp(v)
            let roundDown = SmallFloat.uintToFloatRoundDown(v)
            XCTAssertEqual(i, roundUp)
            XCTAssertEqual(i, roundDown)
        }
    }
}

class OffsetAllocatorTests: XCTestCase {
    
    func testBasic() {
        let allocator = Allocator(size: 1024 * 1024 * 256)
        let a = allocator.allocate(size: 1337)
        let offset = a.offset
        XCTAssertEqual(offset, 0)
        allocator.free(allocation: a)
    }
    
    func testAllocate() {
        let allocator = Allocator(size: 1024 * 1024 * 256)
        
        func testSimple() {
            let a = allocator.allocate(size: 0)
            XCTAssertEqual(a.offset, 0)
            
            let b = allocator.allocate(size: 1)
            XCTAssertEqual(b.offset, 0)
            
            let c = allocator.allocate(size: 123)
            XCTAssertEqual(c.offset, 1)
            
            let d = allocator.allocate(size: 1234)
            XCTAssertEqual(d.offset, 124)
            
            allocator.free(allocation: a)
            allocator.free(allocation: b)
            allocator.free(allocation: c)
            allocator.free(allocation: d)
            
            let validateAll = allocator.allocate(size: 1024 * 1024 * 256)
            XCTAssertEqual(validateAll.offset, 0)
            allocator.free(allocation: validateAll)
        }
        
        func testMergeTrivial() {
            let a = allocator.allocate(size: 1337)
            XCTAssertEqual(a.offset, 0)
            allocator.free(allocation: a)
            
            let b = allocator.allocate(size: 1337)
            XCTAssertEqual(b.offset, 0)
            allocator.free(allocation: b)
            
            let validateAll = allocator.allocate(size: 1024 * 1024 * 256)
            XCTAssertEqual(validateAll.offset, 0)
            allocator.free(allocation: validateAll)
        }
        
        func testReuseTrivial() {
            let a = allocator.allocate(size: 1024)
            XCTAssertEqual(a.offset, 0)
            
            let b = allocator.allocate(size: 3456)
            XCTAssertEqual(b.offset, 1024)
            
            allocator.free(allocation: a)
            
            let c = allocator.allocate(size: 1024)
            XCTAssertEqual(c.offset, 0)
            
            allocator.free(allocation: c)
            allocator.free(allocation: b)
            
            let validateAll = allocator.allocate(size: 1024 * 1024 * 256)
            XCTAssertEqual(validateAll.offset, 0)
            allocator.free(allocation: validateAll)
        }
        
        func testReuseComplex() {
            let a = allocator.allocate(size: 1024)
            XCTAssertEqual(a.offset, 0)
            
            let b = allocator.allocate(size: 3456)
            XCTAssertEqual(b.offset, 1024)
            
            allocator.free(allocation: a)
            
            let c = allocator.allocate(size: 2345)
            XCTAssertEqual(c.offset, 1024 + 3456)
            
            let d = allocator.allocate(size: 456)
            XCTAssertEqual(d.offset, 0)
            
            let e = allocator.allocate(size: 512)
            XCTAssertEqual(e.offset, 456)
                        
            let report = allocator.storageReport()
            let expected: UInt32 = 1024 * 1024 * 256 - 3456 - 2345 - 456 - 512
            XCTAssertEqual(report.totalFreeSpace, expected)
            XCTAssertNotEqual(report.largestFreeRegion, report.totalFreeSpace)
            
            allocator.free(allocation: c)
            allocator.free(allocation: d)
            allocator.free(allocation: b)
            allocator.free(allocation: e)
            
            let validateAll = allocator.allocate(size: 1024 * 1024 * 256)
            XCTAssertEqual(validateAll.offset, 0)
            allocator.free(allocation: validateAll)
        }
        
        func testZeroFragmentation() {
            var allocations = [Allocation](repeating: Allocation(), count: 256)
            for i in 0..<256 {
                allocations[i] = allocator.allocate(size: 1024 * 1024)
                XCTAssertEqual(allocations[i].offset, UInt32(i) * 1024 * 1024)
            }
            
            var report = allocator.storageReport()
            XCTAssertEqual(report.totalFreeSpace, 0)
            XCTAssertEqual(report.largestFreeRegion, 0)
            
            allocator.free(allocation: allocations[243])
            allocator.free(allocation: allocations[5])
            allocator.free(allocation: allocations[123])
            allocator.free(allocation: allocations[95])
            
            allocator.free(allocation: allocations[151])
            allocator.free(allocation: allocations[152])
            allocator.free(allocation: allocations[153])
            allocator.free(allocation: allocations[154])
            
            allocations[243] = allocator.allocate(size: 1024 * 1024)
            allocations[5] = allocator.allocate(size: 1024 * 1024)
            allocations[123] = allocator.allocate(size: 1024 * 1024)
            allocations[95] = allocator.allocate(size: 1024 * 1024)
            allocations[151] = allocator.allocate(size: 1024 * 1024 * 4)
            XCTAssertNotEqual(allocations[243].offset, Allocation.NO_SPACE)
            XCTAssertNotEqual(allocations[5].offset, Allocation.NO_SPACE)
            XCTAssertNotEqual(allocations[123].offset, Allocation.NO_SPACE)
            XCTAssertNotEqual(allocations[95].offset, Allocation.NO_SPACE)
            XCTAssertNotEqual(allocations[151].offset, Allocation.NO_SPACE)
            
            for i in 0..<256 {
                if i < 152 || i > 154 {
                    allocator.free(allocation: allocations[i])
                }
            }
            
            report = allocator.storageReport()
            XCTAssertEqual(report.totalFreeSpace, 1024 * 1024 * 256)
            XCTAssertEqual(report.largestFreeRegion, 1024 * 1024 * 256)
            
            let validateAll = allocator.allocate(size: 1024 * 1024 * 256)
            XCTAssertEqual(validateAll.offset, 0)
            allocator.free(allocation: validateAll)
        }
        
        testSimple()
        testMergeTrivial()
        testReuseTrivial()
        testReuseComplex()
        testZeroFragmentation()
    }
}
