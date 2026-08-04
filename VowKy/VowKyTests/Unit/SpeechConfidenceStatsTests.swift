import XCTest
@testable import VowKy

/// 极速引擎置信度聚合(时长加权 mean + P10)。
final class SpeechConfidenceStatsTests: XCTestCase {

    func test01_empty_returnsNil() {
        XCTAssertNil(SpeechConfidenceAggregator.aggregate([]))
    }

    func test02_zeroWeightOnly_returnsNil() {
        XCTAssertNil(SpeechConfidenceAggregator.aggregate([(0.9, 0)]))
    }

    func test03_singleRun_meanEqualsP10() {
        let stats = SpeechConfidenceAggregator.aggregate([(0.8, 2.0)])
        XCTAssertEqual(stats?.mean ?? 0, 0.8, accuracy: 1e-9)
        XCTAssertEqual(stats?.p10 ?? 0, 0.8, accuracy: 1e-9)
        XCTAssertEqual(stats?.totalWeight ?? 0, 2.0, accuracy: 1e-9)
    }

    func test04_weightedMean() {
        // 0.9×3s + 0.5×1s → (2.7+0.5)/4 = 0.8
        let stats = SpeechConfidenceAggregator.aggregate([(0.9, 3.0), (0.5, 1.0)])
        XCTAssertEqual(stats?.mean ?? 0, 0.8, accuracy: 1e-9)
    }

    func test05_p10_capturesLowConfidenceRunWithEnoughWeight() {
        // 低置信 run 占 25% 权重(≥10%)→ p10 = 0.2,均值仍高——p10 才能暴露局部差
        let stats = SpeechConfidenceAggregator.aggregate([(0.95, 3.0), (0.2, 1.0)])
        XCTAssertEqual(stats?.p10 ?? 0, 0.2, accuracy: 1e-9)
        XCTAssertGreaterThan(stats?.mean ?? 0, 0.7)
    }

    func test06_p10_walksPastTinyLowRun() {
        // 最低 run 只占 4% 权重(<10%),累计要跨到下一档 → p10 = 0.6
        let stats = SpeechConfidenceAggregator.aggregate([(0.1, 0.4), (0.6, 1.0), (0.9, 8.6)])
        XCTAssertEqual(stats?.p10 ?? 0, 0.6, accuracy: 1e-9)
    }

    func test07_nonFiniteConfidence_filtered() {
        let stats = SpeechConfidenceAggregator.aggregate([(Double.nan, 5.0), (0.7, 1.0)])
        XCTAssertEqual(stats?.mean ?? 0, 0.7, accuracy: 1e-9)
        XCTAssertEqual(stats?.totalWeight ?? 0, 1.0, accuracy: 1e-9)
    }
}
