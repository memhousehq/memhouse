// SPDX-License-Identifier: Apache-2.0
//! Ready-made use-case templates (TPL). A template sets how subjects are named, which kinds of
//! memory matter, governance defaults and the guidance given to the agent over MCP.

use crate::config::Config;

#[derive(Debug, Clone)]
pub struct Template {
    pub name: &'static str,
    pub title: &'static str,
    pub subject_hint: &'static str,
    pub default_subject: &'static str,
    pub redact: &'static [&'static str],
    pub recency_weight: f32,
    pub tags: &'static [&'static str],
    pub guidance: &'static str,
}

pub const TEMPLATES: &[Template] = &[
    Template {
        name: "personal",
        title: "Personal assistant",
        subject_hint: "user:<id>",
        default_subject: "user:default",
        redact: &["secret", "card", "ssn", "iban"],
        recency_weight: 0.0,
        tags: &[],
        guidance: "Remember stable facts about the user (identity, people, places, plans, decisions) as `semantic`, likes and dislikes as `preference`. Before answering anything personal, recall first.",
    },
    Template {
        name: "coding",
        title: "Coding agent",
        subject_hint: "repo:<name>",
        default_subject: "repo:default",
        redact: &["secret", "card", "ssn", "iban"],
        recency_weight: 0.0,
        tags: &["convention", "decision", "gotcha", "command", "architecture"],
        guidance: "The subject is the repository. Remember conventions, build and test commands, architecture decisions and gotchas as `procedural` or `semantic` with tags. When a remembered fact turns out to be wrong, call revise instead of storing a contradicting memory. Recall at the start of a task and before editing an unfamiliar area.",
    },
    Template {
        name: "support",
        title: "Customer support",
        subject_hint: "customer:<account-or-contact-id>",
        default_subject: "customer:unknown",
        redact: &["secret", "card", "ssn", "iban"],
        recency_weight: 0.05,
        tags: &["issue", "resolution", "plan", "sentiment", "environment", "escalation"],
        guidance: "The subject is the customer. Recall before replying. Remember the customer's environment and plan as `semantic`, communication preferences as `preference`, every promise made to the customer as `commitment` (with the due date in the text), and issue/resolution pairs tagged `issue` and `resolution`. Never store payment details or passwords. When an issue is resolved or a plan changes, supersede the old memory with revise.",
    },
    Template {
        name: "sales",
        title: "Sales",
        subject_hint: "account:<crm-account-id> or contact:<id>",
        default_subject: "account:unknown",
        redact: &["secret", "card", "ssn", "iban"],
        recency_weight: 0.05,
        tags: &["stakeholder", "pain", "budget", "timeline", "competitor", "objection", "next-step"],
        guidance: "The subject is the account. Remember stakeholders and their roles, pains, budget, timeline, competitors and objections as `semantic` with tags; agreed next steps as `commitment`. Keep facts attributed (\"the CFO said...\"). Supersede outdated deal facts instead of adding contradicting ones.",
    },
    Template {
        name: "success",
        title: "Customer success",
        subject_hint: "account:<id>",
        default_subject: "account:unknown",
        redact: &["secret", "card", "ssn", "iban"],
        recency_weight: 0.05,
        tags: &["goal", "adoption", "risk", "renewal", "expansion", "health", "stakeholder"],
        guidance: "The subject is the account. Remember the customer's goals and success criteria, adoption milestones, health risks, renewal and expansion signals and stakeholder changes. Record follow-ups as `commitment`. Recall before every QBR, renewal or escalation conversation.",
    },
];

pub fn find(name: &str) -> Option<&'static Template> {
    TEMPLATES.iter().find(|t| t.name.eq_ignore_ascii_case(name))
}

/// Apply a template's defaults to a configuration.
pub fn apply(cfg: &mut Config, t: &Template) {
    cfg.memory.template = Some(t.name.to_string());
    cfg.memory.default_subject = t.default_subject.to_string();
    cfg.memory.recency_weight = t.recency_weight;
    cfg.governance.redact = t.redact.iter().map(|s| s.to_string()).collect();
}

pub fn guidance(cfg: &Config) -> String {
    let t = cfg.memory.template.as_deref().and_then(find).unwrap_or(&TEMPLATES[0]);
    let tags = if t.tags.is_empty() { String::new() } else { format!(" Suggested tags: {}.", t.tags.join(", ")) };
    format!(
        "MemHouse is long-term memory shared across sessions and agents. Template: {} . Subjects look like `{}`; the default subject is `{}`. {}{} Use recall before answering questions that may depend on the past, remember for durable facts (one fact per call, written so it makes sense on its own, with dates when known), revise to correct a fact, forget when asked to forget.",
        t.title, t.subject_hint, cfg.memory.default_subject, t.guidance, tags
    )
}
