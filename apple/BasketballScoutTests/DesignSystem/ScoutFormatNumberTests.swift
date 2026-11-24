import Testing
@testable import BasketballScout

/// Expected strings come from the web's own functions (`ui.js`, `toFixed`) run in Node.
@Suite("ScoutFormat numbers")
struct ScoutFormatNumberTests {
    // MARK: toFixed

    @Test("toFixed matches JavaScript on spec examples and edge cases")
    func toFixedExamples() {
        let cases: [(Double, Int, String)] = [
            (1.125, 2, "1.13"), (1.005, 2, "1.00"), (1.255, 2, "1.25"), (8.345, 2, "8.35"),
            (2.5, 0, "3"), (3.5, 0, "4"), (-2.5, 0, "-3"), (-1.5, 0, "-2"), (0.5, 0, "1"), (-0.5, 0, "-1"),
            (-0.4, 0, "-0"), (-0.04, 1, "-0.0"), (-0.0, 1, "0.0"), (0, 0, "0"), (0, 2, "0.00"),
            (1234567.891, 2, "1234567.89"), (123456789012, 0, "123456789012"),
            (4.35, 1, "4.3"), (4.45, 1, "4.5"), (1.45, 1, "1.4"), (0.05, 1, "0.1"), (0.15, 1, "0.1"),
            (0.25, 1, "0.3"), (0.35, 1, "0.3"), (10.25, 1, "10.3"), (2.675, 2, "2.67"), (17.5, 0, "18"),
            (0.000001, 2, "0.00"), (5e-7, 6, "0.000000"), (123.456, 10, "123.4560000000"),
            (9.995, 2, "9.99"), (99.95, 1, "100.0"), (-9.995, 2, "-9.99"), (1.5, 20, "1.50000000000000000000"),
            (0.125, 2, "0.13"), (12.5, 0, "13"), (6.25, 1, "6.3"), (0.375, 2, "0.38"),
            (1e21, 2, "1e+21"),
        ]
        for (value, digits, expected) in cases {
            #expect(ScoutFormat.toFixed(value, digits: digits) == expected, "toFixed(\(value), \(digits))")
        }
    }

    @Test("toFixed matches a JavaScript-generated table of ties, near-ties and negatives")
    func toFixedTable() {
        let rows: [(Double, Int, String)] = [
            (1618.5, 0, "1619"),
            (119.05, 1, "119.0"),
            (9.185, 2, "9.19"),
            (17.855, 2, "17.86"),
            (18.805, 2, "18.80"),
            (1977.5, 0, "1978"),
            (1279.5, 0, "1280"),
            (11.55, 1, "11.6"),
            (71.15, 1, "71.2"),
            (1178.5, 0, "1179"),
            (19.955, 2, "19.95"),
            (17.505, 2, "17.50"),
            (2.455, 2, "2.46"),
            (364.5, 0, "365"),
            (82.25, 1, "82.3"),
            (17.735, 2, "17.73"),
            (162.35, 1, "162.3"),
            (10.855, 2, "10.86"),
            (10.25, 1, "10.3"),
            (15.965, 2, "15.96"),
            (1987.5, 0, "1988"),
            (11.415, 2, "11.41"),
            (101.05, 1, "101.0"),
            (333.5, 0, "334"),
            (5.815, 2, "5.82"),
            (57.15, 1, "57.1"),
            (18.955, 2, "18.95"),
            (12.405, 2, "12.40"),
            (104.75, 1, "104.8"),
            (7.125, 2, "7.13"),
            (914.5, 0, "915"),
            (929.5, 0, "930"),
            (29.95, 1, "29.9"),
            (710.5, 0, "711"),
            (473.5, 0, "474"),
            (382.5, 0, "383"),
            (0.045, 2, "0.04"),
            (1868.5, 0, "1869"),
            (167.55, 1, "167.6"),
            (150.65, 1, "150.7"),
            (26.053, 2, "26.05"),
            (82.728, 2, "82.73"),
            (54.575, 2, "54.58"),
            (53.055, 2, "53.05"),
            (75.473, 2, "75.47"),
            (82.312, 2, "82.31"),
            (18.337, 1, "18.3"),
            (16.164, 1, "16.2"),
            (92.727, 2, "92.73"),
            (54.317, 1, "54.3"),
            (46.15, 1, "46.1"),
            (68.024, 1, "68.0"),
            (76.863, 2, "76.86"),
            (3.828, 2, "3.83"),
            (7.551, 1, "7.6"),
            (75.54, 2, "75.54"),
            (92.933, 1, "92.9"),
            (56.614, 2, "56.61"),
            (90.171, 1, "90.2"),
            (86.189, 1, "86.2"),
            (77.383, 2, "77.38"),
            (52.844, 2, "52.84"),
            (59.687, 1, "59.7"),
            (65.155, 2, "65.16"),
            (95.327, 2, "95.33"),
            (79.262, 2, "79.26"),
            (83.764, 2, "83.76"),
            (63.771, 1, "63.8"),
            (96.397, 1, "96.4"),
            (99.151, 2, "99.15"),
            (-1418.5, 0, "-1419"),
            (-13.055, 2, "-13.05"),
            (-10.05, 1, "-10.1"),
            (-3402.5, 0, "-3403"),
            (-386.25, 1, "-386.3"),
            (-88.05, 1, "-88.0"),
            (-102.15, 1, "-102.2"),
            (-313.25, 1, "-313.3"),
            (-1726.5, 0, "-1727"),
            (-584.5, 0, "-585"),
            (-24.875, 2, "-24.88"),
            (-353.45, 1, "-353.4"),
            (-358.35, 1, "-358.4"),
            (-599.5, 0, "-600"),
            (-30.115, 2, "-30.11"),
            (-22.215, 2, "-22.21"),
            (-229.15, 1, "-229.2"),
            (-319.85, 1, "-319.9"),
            (-248.15, 1, "-248.2"),
            (-17.415, 2, "-17.41"),
            (36.720991134643555, 1, "36.7"),
            (28.589582443237305, 1, "28.6"),
            (74.29728507995605, 1, "74.3"),
            (47.843122482299805, 1, "47.8"),
            (27.620649337768555, 1, "27.6"),
            (21.027326583862305, 1, "21.0"),
            (46.88639938831329, 1, "46.9"),
            (8.162963390350342, 1, "8.2"),
            (45.62906324863434, 1, "45.6"),
            (9.937787055969238, 1, "9.9"),
            (17.826297879219055, 1, "17.8"),
            (71.62997126579285, 1, "71.6"),
            (90.71493148803711, 1, "90.7"),
            (46.180057525634766, 1, "46.2"),
            (94.5155143737793, 1, "94.5"),
            (0.4826545715332031, 1, "0.5"),
            (77.7564074844122, 1, "77.8"),
            (55.481529235839844, 1, "55.5"),
            (27.663040161132812, 1, "27.7"),
            (40.857887268066406, 1, "40.9"),
            (68.18181818181817, 1, "68.2"),
            (68.18181818181817, 0, "68"),
            (34.48275862068966, 1, "34.5"),
            (34.48275862068966, 0, "34"),
            (42.10526315789473, 1, "42.1"),
            (42.10526315789473, 0, "42"),
            (52, 1, "52.0"),
            (52, 0, "52"),
            (56.00000000000001, 1, "56.0"),
            (56.00000000000001, 0, "56"),
            (42.857142857142854, 1, "42.9"),
            (42.857142857142854, 0, "43"),
            (86.36363636363636, 1, "86.4"),
            (86.36363636363636, 0, "86"),
            (56.52173913043478, 1, "56.5"),
            (56.52173913043478, 0, "57"),
            (53.333333333333336, 1, "53.3"),
            (53.333333333333336, 0, "53"),
            (11.11111111111111, 1, "11.1"),
            (11.11111111111111, 0, "11"),
        ]
        for (value, digits, expected) in rows {
            #expect(ScoutFormat.toFixed(value, digits: digits) == expected, "toFixed(\(value), \(digits))")
        }
    }

    @Test("toFixed of non-finite values")
    func toFixedNonFinite() {
        #expect(ScoutFormat.toFixed(.nan, digits: 1) == "NaN")
        #expect(ScoutFormat.toFixed(.infinity, digits: 1) == "Infinity")
        #expect(ScoutFormat.toFixed(-.infinity, digits: 1) == "-Infinity")
    }

    @Test("roundHalfUp is JavaScript Math.round")
    func roundHalfUp() {
        #expect(ScoutFormat.roundHalfUp(2.5) == 3)
        #expect(ScoutFormat.roundHalfUp(-2.5) == -2)
        #expect(ScoutFormat.roundHalfUp(0.49999999999999994) == 0)
        #expect(ScoutFormat.roundHalfUp(89.5) == 90)
        #expect(ScoutFormat.roundHalfUp(-0.6) == -1)
        #expect(ScoutFormat.roundHalfUp(4_503_599_627_370_497) == 4_503_599_627_370_497)
    }

    // MARK: Percent and number

    @Test("percent: formatPct examples")
    func percent() {
        #expect(ScoutFormat.percent(0.456) == "45.6%")
        #expect(ScoutFormat.percent(0.456, digits: 0) == "46%")
        #expect(ScoutFormat.percent(0.4567) == "45.7%")
        #expect(ScoutFormat.percent(0.4) == "40.0%")
        #expect(ScoutFormat.percent(0.125, digits: 0) == "13%")
        #expect(ScoutFormat.percent(0.0625) == "6.3%")
        #expect(ScoutFormat.percent(0.005, digits: 0) == "1%")
        #expect(ScoutFormat.percent(0.015) == "1.5%")
        #expect(ScoutFormat.percent(0.285) == "28.5%")
        #expect(ScoutFormat.percent(0.145) == "14.5%")
        #expect(ScoutFormat.percent(0.2445, digits: 2) == "24.45%")
        #expect(ScoutFormat.percent(1) == "100.0%")
        #expect(ScoutFormat.percent(0) == "0.0%")
        #expect(ScoutFormat.percent(0, digits: 0) == "0%")
        #expect(ScoutFormat.percent(0.999, digits: 0) == "100%")
        #expect(ScoutFormat.percent(0.9995) == "100.0%")
        #expect(ScoutFormat.percent(1.5, digits: 0) == "150%")
        #expect(ScoutFormat.percent(12.345) == "1234.5%")
        #expect(ScoutFormat.percent(-0.001) == "-0.1%")
        #expect(ScoutFormat.percent(-0.0001) == "-0.0%")
        #expect(ScoutFormat.percent(-0.125, digits: 0) == "-13%")
    }

    @Test("percent and number show the placeholder for unknown values")
    func unknownValues() {
        #expect(ScoutFormat.percent(nil) == "\u{2013}")
        #expect(ScoutFormat.percent(.nan) == "\u{2013}")
        #expect(ScoutFormat.percent(.infinity) == "\u{2013}")
        #expect(ScoutFormat.number(nil, digits: 1) == "\u{2013}")
        #expect(ScoutFormat.number(.nan) == "\u{2013}")
        #expect(ScoutFormat.number(Int?.none) == "\u{2013}")
        #expect(ScoutFormat.placeholder == "\u{2013}")
        #expect(ScoutFormat.separator == " \u{00B7} ")
    }

    @Test("number: formatNumber examples")
    func number() {
        #expect(ScoutFormat.number(1.125, digits: 2) == "1.13")
        #expect(ScoutFormat.number(0.95, digits: 2) == "0.95")
        #expect(ScoutFormat.number(12.0, digits: 1) == "12.0")
        #expect(ScoutFormat.number(29.97, digits: 0) == "30")
        #expect(ScoutFormat.number(1234567.891, digits: 2) == "1234567.89")
        #expect(ScoutFormat.number(Int?.some(54)) == "54")
        #expect(ScoutFormat.number(Int?.some(-3)) == "-3")
    }

    // MARK: Stats helpers

    @Test("job progress rounds like Math.round(progress || 0)")
    func roundedPercent() {
        #expect(ScoutFormat.roundedPercent(42.0) == 42)
        #expect(ScoutFormat.roundedPercent(42.5) == 43)
        #expect(ScoutFormat.roundedPercent(99.4) == 99)
        #expect(ScoutFormat.roundedPercent(nil) == 0)
        #expect(ScoutFormat.roundedPercent(.nan) == 0)
        #expect(ScoutFormat.roundedPercent(0) == 0)
        #expect(ScoutFormat.roundedPercent(100) == 100)
    }

    @Test("confidence is round(c × 100)%")
    func confidence() {
        #expect(ScoutFormat.confidence(0.87) == "87%")
        #expect(ScoutFormat.confidence(0.875) == "88%")
        #expect(ScoutFormat.confidence(0.005) == "1%")
        #expect(ScoutFormat.confidence(1) == "100%")
        #expect(ScoutFormat.confidence(nil) == "0%")
        #expect(ScoutFormat.confidence(0) == "0%")
    }

    @Test("box score helpers")
    func boxScore() {
        #expect(ScoutFormat.madeAttempted(made: 5, attempts: 12) == "5-12")
        #expect(ScoutFormat.madeAttempted(made: 0, attempts: 0) == "0-0")
        #expect(ScoutFormat.shootingSplit(made: 5, attempts: 12, fraction: 5.0 / 12.0) == "5-12 (42%)")
        #expect(ScoutFormat.shootingSplit(made: 1, attempts: 8, fraction: 0.125) == "1-8 (13%)")
        #expect(ScoutFormat.shootingSplit(made: 0, attempts: 0, fraction: nil) == "\u{2013}")
        #expect(ScoutFormat.plusMinus(3) == "+3")
        #expect(ScoutFormat.plusMinus(0) == "0")
        #expect(ScoutFormat.plusMinus(-2) == "-2")
        #expect(ScoutFormat.plusMinus(nil) == "\u{2013}")
        #expect(ScoutFormat.jersey("14") == "#14")
        #expect(ScoutFormat.jersey("0") == "#0")
        #expect(ScoutFormat.jersey("00") == "#00")
        #expect(ScoutFormat.jersey(nil) == "")
        #expect(ScoutFormat.jersey("") == "")
    }

    @Test("feet and counts")
    func feetAndCounts() {
        #expect(ScoutFormat.feet(1.25) == "1.3 ft")
        #expect(ScoutFormat.feet(1.2) == "1.2 ft")
        #expect(ScoutFormat.feet(0) == "0.0 ft")
        #expect(ScoutFormat.feet(nil) == "\u{2013}")
        #expect(ScoutFormat.count(1, singular: "event type", plural: "event types") == "1 event type")
        #expect(ScoutFormat.count(3, singular: "event type", plural: "event types") == "3 event types")
        #expect(ScoutFormat.count(0, singular: "shot", plural: "shots") == "0 shots")
    }
}
