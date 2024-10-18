//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import WebRTC
import XCTest

@testable import Signal

final class TurnServerInfoTest: XCTestCase {
    func testParseTurnServers() throws {
        let testCases: [TestCase] = [
            .singleTurnServer,
            .hybridTurnServer,
            .multipleTurnServer,
            .nullableHostnameTurnServer,
        ]

        for (idx, testCase) in testCases.enumerated() {
            let parsedIceServers: [RTCIceServer] = RTCIceServerFetcher.parse(
                turnServerInfoJsonData: testCase.jsonData
            )

            let parsedIceServerUrls: [String] = try parsedIceServers.map { iceServer throws in
                guard iceServer.urlStrings.count == 1 else {
                    throw FailTestError("Unexpected number of URLs in ICE server in test case \(idx)!")
                }

                return iceServer.urlStrings.first!
            }

            XCTAssertEqual(
                parsedIceServerUrls,
                testCase.expectedUrls,
                "URL comparison failed for test case \(idx)"
            )
        }
    }
}

// MARK: -

private struct FailTestError: Error {
    init(_ message: String) {
        XCTFail(message)
    }
}

private struct TestCase {
    /// An ordered list of URLs, which should match those of the `RTCIceServer`s
    /// parsed from this test case.
    let expectedUrls: [String]
    let jsonData: Data

    init(expectedUrls: [String], jsonString: String) {
        self.expectedUrls = expectedUrls
        self.jsonData = jsonString.data(using: .utf8)!
    }

    static let singleTurnServer = TestCase(
        expectedUrls: [
            "turn:[1111:bbbb:cccc:0:0:0:0:1]",
            "turn:1.turn.signal.org",
        ],
        jsonString: """
        {
            "username": "user",
            "password": "pass",
            "urls": [
                "turn:1.turn.signal.org"
            ],
            "urlsWithIps": [
                "turn:[1111:bbbb:cccc:0:0:0:0:1]",
            ],
            "hostname": "1.voip.signal.org"
        }
        """
    )

    static let hybridTurnServer = TestCase(
        expectedUrls: [
            "turn:[2222:bbbb:cccc:0:0:0:0:1]",
            "turn:2.turn.signal.org",
            "turn:[3333:bbbb:cccc:0:0:0:0:1]",
            "turn:3.turn.signal.org",
        ],
        jsonString: """
        {
            "username": "user",
            "password": "pass",
            "urls": [
                "turn:2.turn.signal.org"
            ],
            "urlsWithIps": [
                "turn:[2222:bbbb:cccc:0:0:0:0:1]",
            ],
            "hostname": "2.voip.signal.org",
            "iceServers": [{
                "username": "user",
                "password": "pass",
                "urls": [
                    "turn:3.turn.signal.org"
                ],
                "urlsWithIps": [
                    "turn:[3333:bbbb:cccc:0:0:0:0:1]",
                ],
                "hostname": "3.voip.signal.org"
            }]
        }
        """
    )

    static let multipleTurnServer = TestCase(
        expectedUrls: [
            "turn:[4444:bbbb:cccc:0:0:0:0:1]",
            "turn:4.turn.signal.org",
            "turn:[5555:bbbb:cccc:0:0:0:0:1]",
            "turn:5.turn.signal.org",
        ],
        jsonString: """
        {
            "iceServers": [{
                "username": "user",
                "password": "pass",
                "urls": [
                    "turn:4.turn.signal.org"
                ],
                "urlsWithIps": [
                    "turn:[4444:bbbb:cccc:0:0:0:0:1]",
                ],
                "hostname": "4.voip.signal.org",
            }, {
                "username": "user",
                "password": "pass",
                "urls": [
                    "turn:5.turn.signal.org"
                ],
                "urlsWithIps": [
                    "turn:[5555:bbbb:cccc:0:0:0:0:1]",
                ],
                "hostname": "5.voip.signal.org"
            }]
        }
        """
    )

    static let nullableHostnameTurnServer = TestCase(
        expectedUrls: [
            "turn:[4444:bbbb:cccc:0:0:0:0:1]",
            "turn:4.turn.signal.org",
        ],
        jsonString: """
        {
            "iceServers": [{
                "username": "user",
                "password": "pass",
                "urls": [
                    "turn:4.turn.signal.org"
                ],
                "urlsWithIps": [
                    "turn:[4444:bbbb:cccc:0:0:0:0:1]",
                ]
            }]
        }
        """
    )
}