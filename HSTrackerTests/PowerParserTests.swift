//
//  PowerParserTests.swift
//  HSTracker
//
//  Created by Istvan Fehervari on 28/03/2017.
//  Copyright © 2017 Benjamin Michotte. All rights reserved.
//

import XCTest
import Foundation

@testable import HSTracker

class PowerParserTests: HSTrackerTests {
	
	override func setUp() {
		super.setUp()
	}
	
	override func tearDown() {
		super.tearDown()
	}
	
	func testCreateGameEntity() {
		//let parser = PowerGameStateParser()
	}

    func testQuestDamageMetadataTargetsAndPacketBoundaries() throws {
        var parser = AccountQuestDamageMetadata()
        XCTAssertNil(parser.read("TAG_CHANGE Entity=20 tag=PREDAMAGE value=0"))
        XCTAssertNil(parser.read("META_DATA - Meta=DAMAGE Data=6 InfoCount=2"))
        let first = try XCTUnwrap(parser.read("Info[0] = [entityName=Hero id=20 zone=PLAY zonePos=0 cardId=HERO_01 player=2]"))
        XCTAssertEqual(first.entityID, 20)
        XCTAssertEqual(first.amount, 6)
        XCTAssertNil(parser.read("Info[0] = 20")) // Duplicate within one metadata packet.
        XCTAssertEqual(parser.read("Info[1] = 21")?.entityID, 21)
        XCTAssertNil(parser.read("Info[2] = 22")) // Outside InfoCount.
        XCTAssertNil(parser.read("TAG_CHANGE Entity=20 tag=DAMAGE value=6"))
        XCTAssertNil(parser.read("Info[0] = 20"))
        XCTAssertNil(parser.read("META_DATA - Meta=DAMAGE Data=0 InfoCount=1"))
        XCTAssertNil(parser.read("Info[0] = 20"))
        XCTAssertNil(parser.read("META_DATA - Meta=DAMAGE Data=4 Info=1"))
        XCTAssertEqual(parser.read("Info[0] = 20")?.amount, 4)
        XCTAssertNil(parser.read("META_DATA - Meta=HEALING Data=4 InfoCount=1"))
        XCTAssertNil(parser.read("Info[0] = 20"))
    }
}
