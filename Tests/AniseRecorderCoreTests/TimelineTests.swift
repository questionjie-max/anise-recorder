import XCTest
@testable import AniseRecorderCore

final class TimelineTests: XCTestCase {
    func testInitialTimelineMapsSourceAndOutputTime() throws {
        let timeline = ProjectTimeline(sourceStart: 2, sourceEnd: 8)

        XCTAssertEqual(timeline.duration, 6, accuracy: 0.000_001)
        XCTAssertEqual(
            try XCTUnwrap(timeline.sourceTime(atOutput: 1.5)),
            3.5,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(timeline.outputTime(forSource: 5)),
            3,
            accuracy: 0.000_001
        )
        XCTAssertNil(timeline.outputTime(forSource: 1.9))
    }

    func testSplitPreservesSourceMappingAndRippleOrder() throws {
        var timeline = ProjectTimeline(sourceStart: 0, sourceEnd: 12)
        let firstID = try XCTUnwrap(timeline.clips.first?.id)

        XCTAssertTrue(timeline.split(atOutput: 4))
        XCTAssertEqual(timeline.clips.count, 2)
        XCTAssertEqual(timeline.duration, 12, accuracy: 0.000_001)
        XCTAssertEqual(timeline.clips[0].id, firstID)
        XCTAssertEqual(timeline.clips[0].sourceEnd, 4, accuracy: 0.000_001)
        XCTAssertEqual(timeline.clips[1].sourceStart, 4, accuracy: 0.000_001)
        XCTAssertEqual(
            try XCTUnwrap(timeline.sourceTime(atOutput: 6)),
            6,
            accuracy: 0.000_001
        )

        let secondID = timeline.clips[1].id
        XCTAssertTrue(timeline.deleteClip(id: secondID))
        XCTAssertEqual(timeline.duration, 4, accuracy: 0.000_001)
        XCTAssertNil(timeline.sourceTime(atOutput: 4.1))
    }

    func testPlaybackRateChangesEditedDurationAndMapping() throws {
        var timeline = ProjectTimeline(sourceStart: 0, sourceEnd: 10)
        let clipID = try XCTUnwrap(timeline.clips.first?.id)

        XCTAssertTrue(timeline.setPlaybackRate(2, for: clipID))
        XCTAssertEqual(timeline.duration, 5, accuracy: 0.000_001)
        XCTAssertEqual(
            try XCTUnwrap(timeline.sourceTime(atOutput: 2)),
            4,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(timeline.outputTime(forSource: 4)),
            2,
            accuracy: 0.000_001
        )
    }

    func testBoundaryBelongsToFollowingClip() throws {
        let timeline = ProjectTimeline(clips: [
            TimelineClip(sourceStart: 0, sourceEnd: 1),
            TimelineClip(sourceStart: 4, sourceEnd: 6)
        ])

        XCTAssertEqual(timeline.clipIndex(atOutput: 1), 1)
        XCTAssertEqual(
            try XCTUnwrap(timeline.sourceTime(atOutput: 1)),
            4,
            accuracy: 0.000_001
        )
        XCTAssertEqual(timeline.clipIndex(atOutput: timeline.duration), 1)
        XCTAssertEqual(
            try XCTUnwrap(timeline.sourceTime(atOutput: timeline.duration)),
            6,
            accuracy: 0.000_001
        )
    }

    func testSplitRejectsSegmentsBelowMinimumDuration() {
        let timeline = ProjectTimeline(sourceStart: 0, sourceEnd: 1)
        var tooEarly = timeline
        var tooLate = timeline

        XCTAssertFalse(tooEarly.split(atOutput: 0.01))
        XCTAssertFalse(tooLate.split(atOutput: 0.99))
        XCTAssertEqual(tooEarly.clips.count, 1)
        XCTAssertEqual(tooLate.clips.count, 1)
    }

    func testTimelineDecodesMissingPlaybackRate() throws {
        let json = """
        {
          "clips": [
            {
              "id": "E5D4D22A-40B7-45B0-9484-1322E7B8FA4B",
              "sourceStart": 1,
              "sourceEnd": 3
            }
          ]
        }
        """
        let timeline = try JSONDecoder().decode(
            ProjectTimeline.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(timeline.clips.count, 1)
        XCTAssertEqual(timeline.clips[0].playbackRate, 1)
        XCTAssertEqual(timeline.duration, 2, accuracy: 0.000_001)
    }
}
