import Foundation
import Testing

/// Reads every benchmark threshold from `Scripts/quality-gates.json` at run time (SPEC §6, ADR-010): benchmark code
/// never holds a literal threshold. Located through `#filePath`, so it works from any working directory.
///
/// Memory-measurement helpers for P-6/P-7 (`task_info` / `mach_task_basic_info`, which need a mutable pointer)
/// live **in this target**, never in `Sources/`, so they do not count against the 3-escape unsafe gate (ADR-040).
struct QualityBudgets {
    private let budgets: [String: [String: Double]]

    init(filePath: String = #filePath) throws {
        let root = URL(fileURLWithPath: filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Scripts/quality-gates.json"))
        let object = try JSONSerialization.jsonObject(with: data)
        guard let top = object as? [String: Any], let section = top["budgets"] as? [String: Any] else {
            throw CocoaError(.coderReadCorrupt)
        }
        var budgets: [String: [String: Double]] = [:]
        for (id, value) in section where id.hasPrefix("P-") {
            guard let fields = value as? [String: Any] else {
                continue
            }
            var numbers: [String: Double] = [:]
            for (key, number) in fields {
                if let number = number as? NSNumber {
                    numbers[key] = number.doubleValue
                }
            }
            budgets[id] = numbers
        }
        self.budgets = budgets
    }

    /// The budget identifiers present.
    var identifiers: Set<String> {
        Set(self.budgets.keys)
    }

    /// One threshold; `nil` when absent.
    func value(_ budget: String, _ key: String) -> Double? {
        self.budgets[budget]?[key]
    }

    /// Every field of one budget.
    func fields(_ budget: String) -> [String: Double] {
        self.budgets[budget] ?? [:]
    }
}

@Suite("BudgetsBenchmarks")
struct BudgetsBenchmarks {
    @Test("every budget in quality-gates.json is present with numeric thresholds the benchmarks can read")
    func budgetsAreReadable() throws {
        let budgets = try QualityBudgets()
        let expected = Set((1...14).map { "P-\($0)" })
        #expect(budgets.identifiers == expected)
        for id in expected {
            let fields = budgets.fields(id)
            #expect(!fields.isEmpty, "\(id) has no numeric threshold")
            for (key, value) in fields {
                #expect(value >= 0, "\(id).\(key)")
            }
        }
        #expect(budgets.value("P-1", "lookup_p99_us") != nil)
        #expect(budgets.value("P-14", "idle_tasks_max") != nil)
    }
}
