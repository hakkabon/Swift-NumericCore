import Foundation

public enum NumericalUtilityError: Error, Equatable, Sendable {
    case invalidArgument(String)
    case nonFiniteEvaluation
    case didNotConverge
}

public enum NumericalGrid {
    public static func logarithmic(
        from start: Double, through stop: Double, pointsPerOctave: Int
    ) throws -> [Double] {
        guard start.isFinite, stop.isFinite, start > 0, stop > start,
              pointsPerOctave > 0 else {
            throw NumericalUtilityError.invalidArgument("invalid logarithmic grid")
        }
        let intervals = max(1, Int(ceil(log2(stop / start) * Double(pointsPerOctave))))
        return (0...intervals).map {
            min(start * pow(2, Double($0) / Double(pointsPerOctave)), stop)
        }
    }
}

public enum NumericalInterpolation {
    public static func logarithmicFraction(
        value: Double, lower: Double, upper: Double
    ) throws -> Double {
        guard value.isFinite, lower.isFinite, upper.isFinite,
              lower > 0, value >= lower, value <= upper, lower < upper else {
            throw NumericalUtilityError.invalidArgument("invalid logarithmic interpolation interval")
        }
        return log(value / lower) / log(upper / lower)
    }

    public static func logarithmicMagnitude(
        lower: Double, upper: Double, fraction: Double
    ) throws -> Double {
        guard lower.isFinite, upper.isFinite, fraction.isFinite,
              lower > 0, upper > 0 else {
            throw NumericalUtilityError.invalidArgument("magnitudes must be finite and positive")
        }
        return exp(log(lower) + fraction * log(upper / lower))
    }

    public static func wrappedPhase(
        lower: Double, upper: Double, fraction: Double, period: Double = 2 * .pi
    ) throws -> Double {
        guard lower.isFinite, upper.isFinite, fraction.isFinite,
              period.isFinite, period > 0 else {
            throw NumericalUtilityError.invalidArgument("invalid wrapped-phase interpolation")
        }
        var difference = upper - lower
        let half = period / 2
        while difference > half { difference -= period }
        while difference < -half { difference += period }
        return lower + fraction * difference
    }
}

public enum DescriptiveStatistics {
    public static func quantile(_ values: [Double], probability: Double) throws -> Double {
        guard !values.isEmpty, values.allSatisfy(\.isFinite),
              probability.isFinite, (0...1).contains(probability) else {
            throw NumericalUtilityError.invalidArgument("invalid quantile input")
        }
        let sorted = values.sorted()
        guard sorted.count > 1 else { return sorted[0] }
        let position = probability * Double(sorted.count - 1)
        let lower = Int(floor(position)), upper = Int(ceil(position))
        return sorted[lower] + (position - Double(lower)) * (sorted[upper] - sorted[lower])
    }
}

public struct SplitMix64Generator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    public mutating func nextUnitInterval() -> Double {
        Double(next() >> 11) * 0x1.0p-53
    }
}

public enum StratifiedSampling {
    public static func unitInterval(
        sample: Int, count: Int, dimension: Int,
        generator: inout SplitMix64Generator
    ) throws -> Double {
        guard sample >= 0, sample < count, count > 0, dimension >= 0 else {
            throw NumericalUtilityError.invalidArgument("invalid stratified sample index")
        }
        let permutation = (sample &* 2_654_435_761 &+ dimension &* 1_013_904_223) % count
        return (Double(permutation) + generator.nextUnitInterval()) / Double(count)
    }
}

public struct FixedPointOptions: Sendable, Hashable {
    public var maximumIterations: Int
    public var absoluteTolerance: Double
    public var relaxation: Double

    public init(maximumIterations: Int = 100, absoluteTolerance: Double = 1e-10, relaxation: Double = 1) {
        self.maximumIterations = maximumIterations
        self.absoluteTolerance = absoluteTolerance
        self.relaxation = relaxation
    }
}

public struct FixedPointResult: Sendable, Hashable {
    public let value: Double
    public let residual: Double
    public let iterations: Int
}

public enum FixedPointSolver {
    public static func solve(
        initial: Double, options: FixedPointOptions = .init(),
        transform: (Double) throws -> Double
    ) throws -> FixedPointResult {
        guard initial.isFinite, options.maximumIterations > 0,
              options.absoluteTolerance.isFinite, options.absoluteTolerance > 0,
              options.relaxation.isFinite, options.relaxation > 0, options.relaxation <= 1 else {
            throw NumericalUtilityError.invalidArgument("invalid fixed-point configuration")
        }
        var value = initial
        for iteration in 1...options.maximumIterations {
            let transformed = try transform(value)
            guard transformed.isFinite else { throw NumericalUtilityError.nonFiniteEvaluation }
            let next = value + options.relaxation * (transformed - value)
            let residual = abs(next - value)
            if residual <= options.absoluteTolerance {
                return .init(value: next, residual: residual, iterations: iteration)
            }
            value = next
        }
        throw NumericalUtilityError.didNotConverge
    }
}

public enum SpecialFunctions {
    public static func besselJ1(_ x: Double) -> Double {
        guard x.isFinite else { return .nan }
        let sign = x < 0 ? -1.0 : 1.0
        let magnitude = abs(x)
        if magnitude <= 12 {
            var term = magnitude / 2
            var sum = term
            for k in 1...80 {
                term *= -(magnitude * magnitude / 4) / (Double(k) * Double(k + 1))
                sum += term
                if abs(term) < max(abs(sum), 1) * 1e-15 { break }
            }
            return sign * sum
        }
        let phase = magnitude - 3 * .pi / 4
        let approximation = sqrt(2 / (.pi * magnitude))
            * (cos(phase) - 3 * sin(phase) / (8 * magnitude))
        return sign * approximation
    }
}
