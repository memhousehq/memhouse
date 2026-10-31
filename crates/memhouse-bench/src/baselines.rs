//! Published reference results, with sources. Most memory-vendor numbers are self-reported and
//! were produced with different answer and judge models; they are context, not a leaderboard.
//! Collected October 2026.

pub struct RetrievalRef {
    pub dataset: &'static str,
    pub system: &'static str,
    pub granularity: &'static str,
    pub r5: f64,
    pub n5: f64,
    pub r10: f64,
    pub n10: f64,
    pub source: &'static str,
}

/// LongMemEval paper, Table 9 (LongMemEval_M; key = value, and key = value + extracted facts).
pub const RETRIEVAL: &[RetrievalRef] = &[
    RetrievalRef { dataset: "longmemeval-m", system: "BM25", granularity: "session", r5: 0.634, n5: 0.516, r10: 0.710, n10: 0.540, source: "LongMemEval paper T9" },
    RetrievalRef { dataset: "longmemeval-m", system: "Contriever", granularity: "session", r5: 0.723, n5: 0.634, r10: 0.823, n10: 0.663, source: "LongMemEval paper T9" },
    RetrievalRef { dataset: "longmemeval-m", system: "Stella V5 1.5B", granularity: "session", r5: 0.720, n5: 0.594, r10: 0.794, n10: 0.615, source: "LongMemEval paper T9" },
    RetrievalRef { dataset: "longmemeval-m", system: "Contriever + fact keys (LLM-extracted)", granularity: "session", r5: 0.762, n5: 0.632, r10: 0.862, n10: 0.658, source: "LongMemEval paper T9" },
    RetrievalRef { dataset: "longmemeval-m", system: "Stella V5 1.5B + fact keys (LLM-extracted)", granularity: "session", r5: 0.732, n5: 0.520, r10: 0.862, n10: 0.552, source: "LongMemEval paper T9" },
    RetrievalRef { dataset: "longmemeval-m", system: "BM25", granularity: "round", r5: 0.472, n5: 0.352, r10: 0.538, n10: 0.372, source: "LongMemEval paper T9" },
    RetrievalRef { dataset: "longmemeval-m", system: "Contriever", granularity: "round", r5: 0.589, n5: 0.454, r10: 0.747, n10: 0.495, source: "LongMemEval paper T9" },
    RetrievalRef { dataset: "longmemeval-m", system: "Stella V5 1.5B", granularity: "round", r5: 0.660, n5: 0.498, r10: 0.784, n10: 0.528, source: "LongMemEval paper T9" },
    RetrievalRef { dataset: "longmemeval-m", system: "Stella V5 1.5B + fact keys (LLM-extracted)", granularity: "round", r5: 0.644, n5: 0.498, r10: 0.784, n10: 0.536, source: "LongMemEval paper T9" },
];

pub struct QaRef {
    pub dataset: &'static str,
    pub system: &'static str,
    pub score: f64,
    pub models: &'static str,
    pub who: &'static str,
    pub source: &'static str,
}

pub const QA: &[QaRef] = &[
    QaRef { dataset: "longmemeval-s", system: "Full context (no memory system)", score: 60.2, models: "GPT-4o", who: "Zep paper", source: "https://arxiv.org/abs/2501.13956" },
    QaRef { dataset: "longmemeval-s", system: "Zep", score: 71.2, models: "GPT-4o", who: "vendor", source: "https://arxiv.org/abs/2501.13956" },
    QaRef { dataset: "longmemeval-s", system: "Bedrock AgentCore memory", score: 77.0, models: "GPT-4o", who: "Redis re-run", source: "https://redis.io/resources/agent-memory-benchmark-report/" },
    QaRef { dataset: "longmemeval-s", system: "MemOS", score: 77.8, models: "GPT-4o-mini", who: "vendor", source: "https://huggingface.co/datasets/MemTensor/MemOS_eval_result" },
    QaRef { dataset: "longmemeval-s", system: "Emergence (fast)", score: 81.3, models: "GPT-4o", who: "Redis re-run", source: "https://redis.io/resources/agent-memory-benchmark-report/" },
    QaRef { dataset: "longmemeval-s", system: "Supermemory", score: 81.6, models: "GPT-4o", who: "vendor", source: "https://supermemory.ai/research" },
    QaRef { dataset: "longmemeval-s", system: "Hindsight", score: 83.6, models: "GPT-OSS-20B answer, GPT-OSS-120B judge", who: "vendor", source: "https://arxiv.org/abs/2512.12818" },
    QaRef { dataset: "longmemeval-s", system: "Mastra Observational Memory", score: 84.2, models: "GPT-4o", who: "vendor; Redis reproduced 84.2", source: "https://mastra.ai/research/observational-memory" },
    QaRef { dataset: "longmemeval-s", system: "Mem0 (2026 algorithm)", score: 94.4, models: "not fully disclosed", who: "vendor", source: "https://github.com/mem0ai/memory-benchmarks" },
    QaRef { dataset: "locomo", system: "OpenAI memory", score: 52.9, models: "GPT-4o-mini", who: "Mem0 paper", source: "https://arxiv.org/abs/2504.19413" },
    QaRef { dataset: "locomo", system: "LangMem", score: 58.1, models: "GPT-4o-mini", who: "Mem0 paper", source: "https://arxiv.org/abs/2504.19413" },
    QaRef { dataset: "locomo", system: "Best plain RAG", score: 61.0, models: "GPT-4o-mini", who: "Mem0 paper", source: "https://arxiv.org/abs/2504.19413" },
    QaRef { dataset: "locomo", system: "Mem0 (2025 paper)", score: 66.9, models: "GPT-4o-mini", who: "vendor", source: "https://arxiv.org/abs/2504.19413" },
    QaRef { dataset: "locomo", system: "Full context", score: 72.9, models: "GPT-4o-mini", who: "Mem0 paper", source: "https://arxiv.org/abs/2504.19413" },
    QaRef { dataset: "locomo", system: "Letta (filesystem)", score: 74.0, models: "GPT-4o-mini", who: "vendor", source: "https://www.letta.com/blog/benchmarking-ai-agent-memory" },
    QaRef { dataset: "locomo", system: "Zep (disputed: Mem0 measured 66.0)", score: 75.1, models: "GPT-4o-mini", who: "vendor", source: "https://www.getzep.com/blog/lies-damn-lies-statistics-is-mem0-really-sota-in-agent-memory/" },
    QaRef { dataset: "locomo", system: "MemOS", score: 75.8, models: "GPT-4o-mini", who: "vendor", source: "https://huggingface.co/datasets/MemTensor/MemOS_eval_result" },
    QaRef { dataset: "locomo", system: "Hindsight", score: 83.2, models: "GPT-OSS-20B answer, GPT-OSS-120B judge", who: "vendor", source: "https://arxiv.org/abs/2512.12818" },
    QaRef { dataset: "locomo", system: "EverMemOS", score: 92.3, models: "GPT-4.1-mini", who: "vendor", source: "https://www.evermind.ai/blogs/everos-hits-sota-performance-on-locomo" },
];

pub struct LatencyRef {
    pub system: &'static str,
    pub p50_ms: f64,
    pub p95_ms: f64,
    pub source: &'static str,
}

/// Search latency on LoCoMo as measured in the Mem0 paper (Table 2); hosted services include network time.
pub const LATENCY: &[LatencyRef] = &[
    LatencyRef { system: "Mem0", p50_ms: 148.0, p95_ms: 200.0, source: "Mem0 paper T2" },
    LatencyRef { system: "Mem0 graph", p50_ms: 476.0, p95_ms: 657.0, source: "Mem0 paper T2" },
    LatencyRef { system: "Zep (measured by Mem0)", p50_ms: 513.0, p95_ms: 778.0, source: "Mem0 paper T2" },
    LatencyRef { system: "A-Mem", p50_ms: 668.0, p95_ms: 1485.0, source: "Mem0 paper T2" },
    LatencyRef { system: "LangMem", p50_ms: 17990.0, p95_ms: 59820.0, source: "Mem0 paper T2" },
];
