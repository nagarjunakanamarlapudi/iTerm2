//
//  IntervalTreeSmallestLocationBugTests.swift
//  iTerm2
//
//  Created by George Nachman on 3/20/26.
//
//  Test demonstrating bug in objectsWithSmallestLocation where it incorrectly
//  calls objectsWithSmallestLimitFromNode: instead of recursing with
//  objectsWithSmallestLocationFromNode:.
//

import XCTest
@testable import iTerm2SharedARC

final class IntervalTreeSmallestLocationBugTests: XCTestCase {

    /// Test that objectsWithSmallestLocation returns the object with the smallest
    /// interval location, NOT the smallest limit.
    ///
    /// Bug: In objectsWithSmallestLocationFromNode:, lines 778 and 790 call
    /// objectsWithSmallestLimitFromNode: instead of recursing with
    /// objectsWithSmallestLocationFromNode:. This causes the function to return
    /// objects with the smallest LIMIT rather than the smallest LOCATION when
    /// the tree has a left subtree with multiple nodes.
    ///
    /// This test creates a tree with enough objects to ensure the left subtree
    /// has multiple nodes where smallest location ≠ smallest limit:
    /// - Object A at location=1, limit=200 (smallest location, large limit)
    /// - Object B at location=2, limit=5 (smallest limit)
    /// - Plus additional objects to create a balanced tree
    ///
    /// Expected: objectsWithSmallestLocation should return A (location 1)
    /// Bug behavior: Returns B (limit 5 is smallest, but location 2 is NOT smallest)
    func testObjectsWithSmallestLocationReturnsSmallestLocationNotSmallestLimit() {
        let tree = IntervalTree()

        // Create objects where smallest location has a large limit,
        // and another object has a smaller limit but larger location
        let annotations: [(String, Int64, Int64)] = [
            ("A", 1, 199),   // loc=1, limit=200 - smallest location
            ("B", 2, 3),     // loc=2, limit=5 - smallest limit
            ("C", 3, 97),    // loc=3, limit=100
            ("D", 4, 46),    // loc=4, limit=50
            ("E", 10, 10),   // loc=10, limit=20
            ("F", 20, 10),   // loc=20, limit=30
            ("G", 30, 10),   // loc=30, limit=40
            ("H", 100, 50),  // loc=100, limit=150
        ]

        for (name, loc, len) in annotations {
            let ann = PTYAnnotation()
            ann.stringValue = name
            tree.add(ann, with: Interval(location: loc, length: len))
        }

        let result = tree.objectsWithSmallestLocation()
        let name = (result?.first as? PTYAnnotation)?.stringValue
        let loc = (result?.first as? PTYAnnotation)?.entry?.interval.location

        // If the bug exists, this returns B (smallest limit=5) instead of A (smallest location=1)
        XCTAssertEqual(name, "A",
                       "Should return A with smallest location (1), not B with smallest limit (5)")
        XCTAssertEqual(loc, 1,
                       "Returned object should have location 1")
    }
}
