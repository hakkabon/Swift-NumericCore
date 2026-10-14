import XCTest
@testable import NumericCoreOptimization

final class TimeIntegrationTests: XCTestCase {
    func testRK45DenseOutputAndTerminalEvent() throws {
        let result = try TimeIntegrator.integrate(
            from: 0, to: 2, initialState: [1],
            events: [.init(direction: .falling, terminal: true)],
            eventFunction: { _, y in [y[0] - 0.5] },
            rightHandSide: { _, y in [-y[0]] })
        XCTAssertEqual(result.termination, .terminalEvent)
        XCTAssertEqual(result.events[0].time, log(2), accuracy: 2e-5)
        XCTAssertEqual(result.state(at: 0.25)![0], exp(-0.25), accuracy: 2e-5)
    }

    func testIndexOneDAE() throws {
        let options = TimeIntegrationOptions(absoluteTolerance: 1e-5, relativeTolerance: 1e-4,
                                             initialStep: 0.02, maximumStep: 0.05)
        let result = try TimeIntegrator.integrateDAE(
            from: 0, to: 1, initialState: [1, 0], initialDerivative: [-1, 1], options: options
        ) { _, y, yd in
            DAEEvaluation.massMatrix(
                [[1, 0], [0, 0]], rightHandSide: [-y[0], 1 - y[0] - y[1]],
                rightHandSideJacobian: [[-1, 0], [-1, -1]], derivative: yd)
        }
        XCTAssertEqual(result.termination, .reachedEnd)
        let state = result.points.last!.state
        XCTAssertEqual(state[0], exp(-1), accuracy: 3e-3)
        XCTAssertEqual(state[0] + state[1], 1, accuracy: 1e-8)
        XCTAssertGreaterThan(result.newtonIterations, 0)
    }

    func testRejectsInconsistentInitialDAEValues() {
        XCTAssertThrowsError(try TimeIntegrator.integrateDAE(
            from: 0, to: 1, initialState: [1], initialDerivative: [0]
        ) { _, y, yd in
            DAEEvaluation(residuals: [yd[0] + y[0]], jacobianState: [[1]],
                          jacobianDerivative: [[1]])
        })
    }

    func testReverseTimeAndCancellationAreExplicit() throws {
        let backward = try TimeIntegrator.integrate(
            from: 1, to: 0, initialState: [exp(1)], rightHandSide: { _, y in [y[0]] })
        XCTAssertEqual(backward.termination, .reachedEnd)
        XCTAssertEqual(backward.points.last!.state[0], 1, accuracy: 2e-6)

        let cancelled = try TimeIntegrator.integrate(
            from: 0, to: 1, initialState: [1], observer: { _ in false },
            rightHandSide: { _, y in [-y[0]] })
        XCTAssertEqual(cancelled.termination, .cancelled)
        XCTAssertEqual(cancelled.acceptedSteps, 1)
    }
}
