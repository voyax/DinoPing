import Foundation

/// Aggregated token + cost totals for a Claude Code session, computed by
/// scanning its transcript JSONL for `message.usage` blocks. Cache reads
/// are included in `totalTokens` because they're real tokens that the
/// model processed (just charged at a discount); the cost is computed
/// against a per-model pricing table.
public struct SessionUsage: Sendable, Equatable {
    public var inputTokens: Int = 0
    public var outputTokens: Int = 0
    public var cacheCreationTokens: Int = 0
    public var cacheReadTokens: Int = 0
    /// Estimated USD cost of the tokens above. `nil` when ANY model in the
    /// transcript falls outside the known pricing table — the caller
    /// should hide the cost field rather than show a wildly-wrong number.
    public var estimatedCostUSD: Double?

    public var totalTokens: Int {
        inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
    }
}

/// Computes `SessionUsage` for a session by streaming through its
/// transcript JSONL. Self-contained: doesn't need any prior state.
public struct SessionUsageAggregator: Sendable {

    public init() {}

    /// Compute the running totals for `(cwd, sessionId)`. Returns `nil`
    /// when the transcript file can't be found / opened. Reads the full
    /// file because tokens accumulate across every turn and skipping
    /// older turns would undercount.
    public func aggregate(cwd: String, sessionId: String) -> SessionUsage? {
        let reader = TranscriptReader()
        guard let url = reader.transcriptURL(cwd: cwd, sessionId: sessionId),
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var usage = SessionUsage()
        var cost: Double = 0
        var anyUnknownModel = false

        // Stream line-by-line by reading the whole file then splitting.
        // For typical transcripts (5–10 MB) this is fast enough that the
        // SessionCard cache below absorbs any UI cost.
        let data = handle.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains("\"usage\"") else { continue }
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = json["message"] as? [String: Any],
                  let usageBlock = message["usage"] as? [String: Any]
            else { continue }

            let inTok  = (usageBlock["input_tokens"]              as? Int) ?? 0
            let outTok = (usageBlock["output_tokens"]             as? Int) ?? 0
            let cCre   = (usageBlock["cache_creation_input_tokens"] as? Int) ?? 0
            let cRead  = (usageBlock["cache_read_input_tokens"]   as? Int) ?? 0

            usage.inputTokens          += inTok
            usage.outputTokens         += outTok
            usage.cacheCreationTokens  += cCre
            usage.cacheReadTokens      += cRead

            // Cost — look up the model family. Anthropic pricing is per
            // 1M tokens; we accumulate fractional dollars and round once
            // at display time.
            let modelName = (message["model"] as? String) ?? ""
            if let pricing = ModelPricing.lookup(modelName) {
                cost += Double(inTok)  / 1_000_000 * pricing.inputPerMillion
                cost += Double(outTok) / 1_000_000 * pricing.outputPerMillion
                cost += Double(cCre)   / 1_000_000 * pricing.cacheCreatePerMillion
                cost += Double(cRead)  / 1_000_000 * pricing.cacheReadPerMillion
            } else if !modelName.isEmpty {
                anyUnknownModel = true
            }
        }

        // Only surface cost if we recognized every model encountered —
        // mixing known and unknown pricing would silently understate cost.
        usage.estimatedCostUSD = anyUnknownModel ? nil : cost
        return usage
    }
}

// MARK: - Pricing

/// Anthropic Claude model pricing in USD per 1M tokens, separated by
/// the four meaningful buckets (input / output / cache-create / cache-read).
/// Pricing is published by Anthropic and rarely changes mid-version —
/// update this table when a new model family ships.
struct ModelPricing {
    let inputPerMillion: Double
    let outputPerMillion: Double
    let cacheCreatePerMillion: Double
    let cacheReadPerMillion: Double

    /// Look up pricing by matching the model name to a known family
    /// (substring match: "claude-opus-4-7" → opus). Returns `nil` for
    /// unrecognized models so the caller can hide cost rather than
    /// estimate at the wrong rate.
    static func lookup(_ modelName: String) -> ModelPricing? {
        let name = modelName.lowercased()
        if name.contains("opus")    { return opus }
        if name.contains("sonnet")  { return sonnet }
        if name.contains("haiku")   { return haiku }
        return nil
    }

    // Pricing as of Claude 4.x family (May 2026 catalog).
    static let opus = ModelPricing(
        inputPerMillion: 15.00,
        outputPerMillion: 75.00,
        cacheCreatePerMillion: 18.75,
        cacheReadPerMillion: 1.50
    )
    static let sonnet = ModelPricing(
        inputPerMillion: 3.00,
        outputPerMillion: 15.00,
        cacheCreatePerMillion: 3.75,
        cacheReadPerMillion: 0.30
    )
    static let haiku = ModelPricing(
        inputPerMillion: 1.00,
        outputPerMillion: 5.00,
        cacheCreatePerMillion: 1.25,
        cacheReadPerMillion: 0.10
    )
}
