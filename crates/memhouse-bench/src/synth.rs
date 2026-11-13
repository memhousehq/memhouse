// SPDX-License-Identifier: Apache-2.0
//! `memhouse bench synth`: the synthetic timeline generator (roadmap G13, QUAL-03).
//!
//! A scripted world model holds the true state of a subject (what is true of it at each step)
//! and writes conversations from it: facts, corrections, plans that are later carried out or
//! dropped, guesses, and small talk that should leave no memory. Each turn carries its ground
//! truth (`expect`, `key`), and each session ends with a checkpoint of questions about the
//! state at that point. The output is an ordinary evaluation suite
//! ([`memhouse_core::eval::Suite`]).
//!
//! The generator is deterministic: the same profile, seed and size give the same suite, byte
//! for byte, on every machine and release (it has its own small generator of random numbers, so
//! a dependency upgrade can't change a suite).

use chrono::{DateTime, Duration, TimeZone, Utc};
use memhouse_core::eval::{Expect, Suite, SuiteConversation, SuiteQuestion, SuiteSession, SuiteTurn, SUITE_FORMAT};
use memhouse_core::types::MemoryKind;

/// SplitMix64: small, fast and fixed for good.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9e37_79b9_7f4a_7c15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
        z ^ (z >> 31)
    }

    fn below(&mut self, n: usize) -> usize {
        (self.next() % n.max(1) as u64) as usize
    }

    fn pick<'a, T: ?Sized>(&mut self, items: &[&'a T]) -> &'a T {
        items[self.below(items.len())]
    }

    fn chance(&mut self, percent: usize) -> bool {
        self.below(100) < percent
    }
}

/// One thing that can be true of a subject, and the ways it is talked about. `{v}` is the value,
/// `{old}` the value it replaces.
struct Attribute {
    key: &'static str,
    question: &'static str,
    values: &'static [&'static str],
    /// Stating it.
    fact: &'static [&'static str],
    /// Correcting it.
    change: &'static [&'static str],
    /// Intending it: not a fact yet.
    plan: &'static [&'static str],
    /// Wondering about it: not a fact.
    guess: &'static [&'static str],
    /// Having done what was planned: a fact from then on.
    outcome: &'static [&'static str],
    kind: Option<MemoryKind>,
}

/// A vocabulary for one kind of deployment.
struct Profile {
    name: &'static str,
    attributes: &'static [Attribute],
    /// Said in passing; nothing to remember.
    small_talk: &'static [&'static str],
}

const PERSONAL: Profile = Profile {
    name: "personal",
    attributes: &[
        Attribute {
            key: "city",
            question: "Which city do I live in?",
            values: &["Lisbon", "Porto", "Berlin", "Vienna", "Tallinn", "Dublin", "Kraków", "Lyon", "Bologna", "Utrecht"],
            fact: &["I live in {v}.", "My home is in {v}.", "I'm based in {v} these days."],
            change: &["I no longer live in {old}; I now live in {v}.", "Correction: I live in {v}, not in {old}.", "Actually I moved, I live in {v} now, not {old}."],
            plan: &["I plan to move to {v} next year.", "I'm going to relocate to {v} in the spring.", "We intend to move to {v} once the lease ends."],
            guess: &["I might move to {v} someday, maybe.", "Perhaps I'll end up living in {v}, who knows."],
            outcome: &["I moved to {v} last week.", "The move is done: I live in {v} now."],
            kind: None,
        },
        Attribute {
            key: "employer",
            question: "Which company do I work for?",
            values: &["Northwind", "Globex", "Initech", "Umbra Labs", "Fenwhistle", "Brightwater", "Kestrel Works", "Halcyon"],
            fact: &["I work at {v}.", "My employer is {v}.", "I'm employed by {v}."],
            change: &["I no longer work at {old}; I work at {v} now.", "Correction: my employer is {v}, not {old}.", "Actually I left {old} and I work at {v} now."],
            plan: &["I plan to join {v} in the autumn.", "I'm going to start at {v} next quarter.", "I intend to take the offer from {v}."],
            guess: &["I might apply to {v}, not sure yet.", "Maybe I'll work for {v} one day."],
            outcome: &["I started at {v} on Monday.", "I signed the contract: I work at {v} now."],
            kind: None,
        },
        Attribute {
            key: "pet",
            question: "What is my pet called?",
            values: &["Rex", "Miso", "Biscuit", "Nala", "Pixel", "Olive", "Bruno", "Tofu"],
            fact: &["My dog is called {v}.", "I have a dog named {v}.", "Our dog's name is {v}."],
            change: &["Correction: the dog is called {v}, not {old}.", "Actually we renamed the dog, it is {v} now and no longer {old}."],
            plan: &["I plan to rename the dog to {v}.", "We are going to rename the dog to {v} next month."],
            guess: &["I might rename the dog to {v}, maybe.", "Perhaps {v} would be a better name for the dog."],
            outcome: &["We renamed the dog: it is called {v} now.", "The dog has its new name; it is called {v} now."],
            kind: None,
        },
        Attribute {
            key: "diet",
            question: "What diet do I follow?",
            values: &["vegetarian", "vegan", "pescatarian", "gluten-free", "low-carb", "dairy-free"],
            fact: &["I eat {v}.", "I follow a {v} diet.", "My diet is {v}."],
            change: &["I no longer eat {old}; my diet is {v} now.", "Correction: my diet is {v}, not {old}."],
            plan: &["I plan to go {v} in January.", "I'm going to switch to a {v} diet next month."],
            guess: &["I might try a {v} diet sometime, maybe.", "Perhaps going {v} would suit me."],
            outcome: &["I switched to a {v} diet this week.", "It's done: I eat {v} now."],
            kind: Some(MemoryKind::Preference),
        },
        Attribute {
            key: "hobby",
            question: "What is my main hobby?",
            values: &["bouldering", "pottery", "birdwatching", "fencing", "woodworking", "sailing", "beekeeping", "calligraphy"],
            fact: &["My main hobby is {v}.", "I spend my weekends on {v}.", "I do {v} as a hobby."],
            change: &["I no longer do {old}; my hobby is {v} now.", "Correction: my hobby is {v}, not {old}."],
            plan: &["I plan to take up {v} this summer.", "I'm going to start {v} lessons soon."],
            guess: &["I might try {v} one day, maybe.", "Perhaps {v} would be fun to try."],
            outcome: &["I took up {v} last month.", "I started {v} and I do it every weekend now."],
            kind: None,
        },
        Attribute {
            key: "phone",
            question: "Which phone do I use?",
            values: &["a Fairphone 5", "a Pixel 9", "an iPhone 16", "a Galaxy S25", "a Nothing Phone 3", "a Xperia 1"],
            fact: &["I use {v}.", "My phone is {v}.", "I carry {v}."],
            change: &["I no longer use {old}; my phone is {v} now.", "Correction: my phone is {v}, not {old}."],
            plan: &["I plan to buy {v} when my contract ends.", "I'm going to switch to {v} next month."],
            guess: &["I might get {v}, not sure.", "Maybe {v} would be a good next phone."],
            outcome: &["I bought {v} yesterday.", "I switched phones: I use {v} now."],
            kind: None,
        },
    ],
    small_talk: &[
        "Thanks, that helps a lot.",
        "What's the weather like tomorrow?",
        "Can you recommend a good book?",
        "Sorry, I got distracted for a moment.",
        "That makes sense.",
        "How long does it take to boil an egg?",
    ],
};

const SUPPORT: Profile = Profile {
    name: "support",
    attributes: &[
        Attribute {
            key: "plan",
            question: "Which plan is the customer on?",
            values: &["Starter", "Team", "Business", "Enterprise", "Enterprise Plus"],
            fact: &["The customer is on the {v} plan.", "Their subscription is the {v} plan.", "The account runs on the {v} plan."],
            change: &["The customer is no longer on the {old} plan; they are on the {v} plan now.", "Correction: the account is on the {v} plan, not {old}."],
            plan: &["They plan to upgrade to the {v} plan next quarter.", "The customer is going to move to the {v} plan at renewal."],
            guess: &["They might consider the {v} plan, maybe.", "Perhaps the {v} plan would fit them."],
            outcome: &["They upgraded to the {v} plan today.", "The change went through: the account is on the {v} plan now."],
            kind: None,
        },
        Attribute {
            key: "contact",
            question: "Who is the customer's billing contact?",
            values: &["Priya Raman", "Tom Becker", "Ana Sousa", "Jonas Lind", "Mei Tanaka", "Olu Adeyemi", "Clara Novak"],
            fact: &["The billing contact is {v}.", "Billing questions go to {v}.", "Their billing contact is {v}."],
            change: &["The billing contact is no longer {old}; it is {v} now.", "Correction: the billing contact is {v}, not {old}."],
            plan: &["They plan to hand billing over to {v} next month.", "{v} is going to take over billing after the reorganisation."],
            guess: &["{v} might become the billing contact, not confirmed.", "Perhaps {v} will handle billing later."],
            outcome: &["{v} took over as billing contact this week.", "The handover is done: {v} is the billing contact now."],
            kind: None,
        },
        Attribute {
            key: "seats",
            question: "How many seats does the customer have?",
            values: &["25 seats", "40 seats", "60 seats", "85 seats", "120 seats", "200 seats"],
            fact: &["The account has {v}.", "They are licensed for {v}.", "Their contract covers {v}."],
            change: &["The account no longer has {old}; it has {v} now.", "Correction: the contract covers {v}, not {old}."],
            plan: &["They plan to grow to {v} next year.", "The customer is going to add licences, up to {v}."],
            guess: &["They might need {v} eventually, maybe.", "Perhaps they will want {v} later."],
            outcome: &["They expanded to {v} this month.", "The order was processed: the account has {v} now."],
            kind: None,
        },
        Attribute {
            key: "region",
            question: "Which data region is the customer hosted in?",
            values: &["Frankfurt", "Dublin", "Paris", "Stockholm", "Milan", "Warsaw"],
            fact: &["Their data is hosted in the {v} region.", "The account is in the {v} region.", "They are hosted in {v}."],
            change: &["The account is no longer hosted in {old}; it is in the {v} region now.", "Correction: they are hosted in {v}, not in {old}."],
            plan: &["They plan to migrate to the {v} region in the summer.", "The customer is going to move their data to {v}."],
            guess: &["They might move to the {v} region, not decided.", "Perhaps {v} would be closer to their users."],
            outcome: &["The migration finished: they are hosted in the {v} region now.", "They moved to the {v} region last night."],
            kind: None,
        },
        Attribute {
            key: "channel",
            question: "How does the customer prefer to be contacted?",
            values: &["email", "phone", "a shared chat channel", "a weekly call", "the ticket portal"],
            fact: &["They prefer to be contacted by {v}.", "The customer prefers {v} for updates.", "Their preferred channel is {v}."],
            change: &["They no longer prefer {old}; they prefer {v} now.", "Correction: their preferred channel is {v}, not {old}."],
            plan: &["They plan to move updates to {v} next month.", "The team is going to switch to {v} for updates."],
            guess: &["They might prefer {v} later, maybe.", "Perhaps {v} would work better for them."],
            outcome: &["They switched to {v} for all updates.", "From this week on they prefer {v}."],
            kind: Some(MemoryKind::Preference),
        },
    ],
    small_talk: &["Thanks for the quick reply.", "Is there a status page I can check?", "Let me get back to you on that.", "Have a good weekend.", "Could you resend the link?"],
};

const CODING: Profile = Profile {
    name: "coding",
    attributes: &[
        Attribute {
            key: "tests",
            question: "Which test runner does this repository use?",
            values: &["pytest", "vitest", "jest", "cargo nextest", "go test", "rspec"],
            fact: &["This repository runs its tests with {v}.", "Tests here are run with {v}.", "The test runner is {v}."],
            change: &["The repository no longer uses {old}; tests run with {v} now.", "Correction: the test runner is {v}, not {old}."],
            plan: &["We plan to migrate the tests to {v} next sprint.", "We are going to switch the test runner to {v}."],
            guess: &["We might try {v} for the tests, maybe.", "Perhaps {v} would be faster for the tests."],
            outcome: &["The migration is merged: tests run with {v} now.", "We switched the test runner to {v} yesterday."],
            kind: None,
        },
        Attribute {
            key: "formatter",
            question: "Which formatter does this repository use?",
            values: &["ruff format", "prettier", "biome", "rustfmt", "gofmt", "black"],
            fact: &["Code here is formatted with {v}.", "The formatter is {v}.", "We format the code with {v}."],
            change: &["We no longer format with {old}; the formatter is {v} now.", "Correction: the formatter is {v}, not {old}."],
            plan: &["We plan to adopt {v} as the formatter next month.", "We are going to move the formatter to {v}."],
            guess: &["We might switch the formatter to {v}, not decided.", "Perhaps {v} would be a better formatter."],
            outcome: &["We adopted {v} as the formatter this week.", "The formatter was switched to {v} in the last release."],
            kind: None,
        },
        Attribute {
            key: "packages",
            question: "Which package manager does this repository use?",
            values: &["pnpm", "uv", "poetry", "yarn", "npm", "bun"],
            fact: &["Dependencies are managed with {v}.", "The package manager is {v}.", "We install dependencies with {v}."],
            change: &["We no longer use {old}; the package manager is {v} now.", "Correction: the package manager is {v}, not {old}."],
            plan: &["We plan to move the dependencies to {v} after the release.", "We are going to switch the package manager to {v}."],
            guess: &["We might move to {v} for the dependencies, maybe.", "Perhaps {v} would install faster."],
            outcome: &["The lockfile was migrated: the package manager is {v} now.", "We switched the package manager to {v} last week."],
            kind: None,
        },
        Attribute {
            key: "branch",
            question: "What is the default branch called?",
            values: &["main", "trunk", "develop", "master", "stable"],
            fact: &["The default branch is {v}.", "Pull requests target the {v} branch.", "We merge into the {v} branch."],
            change: &["The default branch is no longer {old}; it is {v} now.", "Correction: the default branch is {v}, not {old}."],
            plan: &["We plan to rename the default branch to {v}.", "We are going to make {v} the default branch."],
            guess: &["We might rename the default branch to {v}, maybe.", "Perhaps {v} would be a clearer branch name."],
            outcome: &["The default branch was renamed to {v}.", "We made {v} the default branch today."],
            kind: None,
        },
        Attribute {
            key: "review",
            question: "How many approvals does a pull request need?",
            values: &["one approval", "two approvals", "three approvals", "an approval from a code owner"],
            fact: &["A pull request needs {v} before it merges.", "Merging requires {v}.", "The rule is {v} for every pull request."],
            change: &["A pull request no longer needs {old}; it needs {v} now.", "Correction: merging requires {v}, not {old}."],
            plan: &["We plan to require {v} from next quarter.", "We are going to change the rule to {v}."],
            guess: &["We might require {v} later, maybe.", "Perhaps {v} would be enough."],
            outcome: &["The rule changed: a pull request needs {v} now.", "We now require {v} for every pull request."],
            kind: Some(MemoryKind::Procedural),
        },
    ],
    small_talk: &["Thanks, that fixed it.", "Why is the build so slow today?", "Give me a minute to pull the latest changes.", "Looks good to me.", "Can you show the diff again?"],
};

const SALES: Profile = Profile {
    name: "sales",
    attributes: &[
        Attribute {
            key: "champion",
            question: "Who is our champion at the account?",
            values: &["Dana Whitfield", "Marco Bellini", "Sofia Lindqvist", "Arjun Mehta", "Elena Petrova", "Kwame Asante"],
            fact: &["Our champion at the account is {v}.", "The deal's champion is {v}.", "{v} is our champion there."],
            change: &["Our champion is no longer {old}; it is {v} now.", "Correction: the champion is {v}, not {old}."],
            plan: &["{v} is going to take over as champion next month.", "They plan to make {v} our main contact."],
            guess: &["{v} might become our champion, not sure.", "Perhaps {v} will champion the deal."],
            outcome: &["{v} took over as our champion this week.", "It's confirmed: {v} is our champion now."],
            kind: None,
        },
        Attribute {
            key: "budget",
            question: "What budget did the account confirm?",
            values: &["40,000 euros", "75,000 euros", "120,000 euros", "200,000 euros", "350,000 euros"],
            fact: &["They confirmed a budget of {v}.", "The approved budget is {v}.", "Their budget for this is {v}."],
            change: &["The budget is no longer {old}; it is {v} now.", "Correction: the approved budget is {v}, not {old}."],
            plan: &["They plan to raise the budget to {v} next fiscal year.", "Finance is going to approve {v} in the next cycle."],
            guess: &["The budget might reach {v}, maybe.", "Perhaps they can stretch to {v}."],
            outcome: &["Finance approved {v} this morning.", "The new budget was signed off: {v}."],
            kind: None,
        },
        Attribute {
            key: "competitor",
            question: "Which competitor is the account also evaluating?",
            values: &["Corvid", "Lumenstack", "Parallax", "Quillon", "Tessera"],
            fact: &["The one competitor they are evaluating is {v}.", "The competitor in this deal is {v}.", "{v} is the only other vendor on their shortlist."],
            change: &["They are no longer evaluating {old}; the competitor is {v} now.", "Correction: the competitor is {v}, not {old}."],
            plan: &["They plan to replace the competing vendor with {v} next month.", "Procurement is going to swap the other vendor for {v}."],
            guess: &["They might swap the other vendor for {v}, maybe.", "Perhaps {v} will replace the competitor in the deal."],
            outcome: &["They replaced the competing vendor: the competitor is {v} now.", "The other vendor was swapped out; the competitor in the deal is {v} now."],
            kind: None,
        },
        Attribute {
            key: "close",
            question: "When is the deal expected to close?",
            values: &["the end of March", "mid June", "the end of September", "early December", "the end of January"],
            fact: &["The deal is expected to close by {v}.", "Their target close date is {v}.", "They want to sign by {v}."],
            change: &["The close date is no longer {old}; it is {v} now.", "Correction: they want to sign by {v}, not {old}."],
            plan: &["They plan to move the signature to {v}.", "Legal is going to push the close to {v}."],
            guess: &["It might slip to {v}, not sure.", "Perhaps they will sign by {v}."],
            outcome: &["The close date was moved to {v}.", "They confirmed today that they sign by {v}."],
            kind: Some(MemoryKind::Commitment),
        },
    ],
    small_talk: &["Thanks for the update.", "Shall we find a slot next week?", "I'll send the notes after the call.", "Good talking to you.", "Can you share the deck again?"],
};

const SUCCESS: Profile = Profile {
    name: "success",
    attributes: &[
        Attribute {
            key: "owner",
            question: "Who owns the rollout at the customer?",
            values: &["Hana Kovacs", "Liam O'Brien", "Noor Haddad", "Pavel Dvorak", "Ines Carvalho", "Tariq Aziz"],
            fact: &["The rollout is owned by {v}.", "{v} owns the rollout on their side.", "Their rollout owner is {v}."],
            change: &["The rollout is no longer owned by {old}; it is owned by {v} now.", "Correction: the rollout owner is {v}, not {old}."],
            plan: &["{v} is going to take over the rollout next month.", "They plan to hand the rollout to {v}."],
            guess: &["{v} might take over the rollout, maybe.", "Perhaps {v} will own it later."],
            outcome: &["{v} took over the rollout this week.", "The handover is done: {v} owns the rollout now."],
            kind: None,
        },
        Attribute {
            key: "goal",
            question: "What is the customer's main goal this year?",
            values: &["cutting onboarding time in half", "retiring the legacy portal", "consolidating three regions", "passing the security audit", "doubling weekly active users"],
            fact: &["Their main goal this year is {v}.", "The customer's goal is {v}.", "What they want most this year is {v}."],
            change: &["Their goal is no longer {old}; it is {v} now.", "Correction: the main goal is {v}, not {old}."],
            plan: &["They plan to make {v} the goal for next year.", "Leadership is going to set {v} as the next goal."],
            guess: &["The goal might become {v}, not decided.", "Perhaps {v} will matter more to them."],
            outcome: &["Leadership confirmed the new goal: {v}.", "They announced {v} as the goal this quarter."],
            kind: None,
        },
        Attribute {
            key: "health",
            question: "What is the account's health status?",
            values: &["green", "amber", "red"],
            fact: &["The account's health is {v}.", "We rate the account {v}.", "Account health is {v} at the moment."],
            change: &["The account's health is no longer {old}; it is {v} now.", "Correction: account health is {v}, not {old}."],
            plan: &["We plan to move the account to {v} after the review.", "We are going to rate the account {v} next month."],
            guess: &["The account might turn {v}, maybe.", "Perhaps the health will be {v} by summer."],
            outcome: &["After the review the account's health is {v}.", "We moved the account to {v} today."],
            kind: None,
        },
        Attribute {
            key: "cadence",
            question: "How often do we meet the customer?",
            values: &["weekly", "every two weeks", "monthly", "quarterly"],
            fact: &["We meet the customer {v}.", "The check-in cadence is {v}.", "Our sync with them is {v}."],
            change: &["We no longer meet {old}; the cadence is {v} now.", "Correction: the check-in cadence is {v}, not {old}."],
            plan: &["We plan to move the check-ins to {v}.", "We are going to meet {v} from next quarter."],
            guess: &["We might meet {v} later, maybe.", "Perhaps {v} would be enough."],
            outcome: &["We agreed to meet {v} from now on.", "The cadence changed: we meet {v} now."],
            kind: Some(MemoryKind::Preference),
        },
    ],
    small_talk: &["Thanks, speak soon.", "Did the invite reach everyone?", "Let me check my calendar.", "Great, that works.", "Could you repeat the last point?"],
};

const PROFILES: &[&Profile] = &[&PERSONAL, &SUPPORT, &CODING, &SALES, &SUCCESS];

pub fn profiles() -> Vec<&'static str> {
    PROFILES.iter().map(|p| p.name).collect()
}

fn fill(template: &str, value: &str, old: Option<&str>) -> String {
    template.replace("{v}", value).replace("{old}", old.unwrap_or(""))
}

/// What a generated suite holds, for the report.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Shape {
    pub conversations: usize,
    pub sessions: usize,
    pub turns: usize,
    pub facts: usize,
    pub corrections: usize,
    pub plans: usize,
    pub guesses: usize,
    pub outcomes: usize,
    pub small_talk: usize,
    pub questions: usize,
}

/// The state of one attribute in the world model.
#[derive(Clone)]
struct Slot {
    attr: usize,
    /// The value that is true now, if one was stated.
    value: Option<&'static str>,
    /// A value planned and not yet carried out, and the id of the turn that planned it.
    planned: Option<(&'static str, String)>,
    /// Corrected at least once: its questions measure the stale-fact rate.
    corrected: bool,
}

/// Generate `conversations` conversations of `profile` from `seed`.
pub fn generate(profile: &str, seed: u64, conversations: usize, name: Option<&str>) -> anyhow::Result<(Suite, Shape)> {
    let p = PROFILES.iter().find(|p| p.name == profile).ok_or_else(|| anyhow::anyhow!("unknown profile '{profile}' (one of: {})", profiles().join(", ")))?;
    anyhow::ensure!((1..=20_000).contains(&conversations), "conversations must be 1 to 20000");
    let mut shape = Shape { conversations, ..Default::default() };
    let start: DateTime<Utc> = Utc.with_ymd_and_hms(2026, 1, 5, 9, 0, 0).single().expect("a valid date");
    let mut out = Vec::with_capacity(conversations);
    for c in 0..conversations {
        // One stream per conversation: adding conversations never changes the earlier ones.
        let mut rng = Rng(seed ^ (c as u64 + 1).wrapping_mul(0xa076_1d64_78bd_642f));
        let mut slots: Vec<Slot> = (0..p.attributes.len()).map(|attr| Slot { attr, value: None, planned: None, corrected: false }).collect();
        // A fresh value for a slot: never the current one, nor the one planned.
        let fresh = |rng: &mut Rng, s: &Slot| loop {
            let v = rng.pick(p.attributes[s.attr].values);
            if Some(v) != s.value && Some(v) != s.planned.as_ref().map(|p| p.0) {
                return v;
            }
        };
        let mut at = start + Duration::days(rng.below(60) as i64) + Duration::minutes(rng.below(480) as i64);
        let n_sessions = 4 + rng.below(3);
        let mut sessions = Vec::with_capacity(n_sessions);
        for s in 0..n_sessions {
            let mut turns: Vec<SuiteTurn> = vec![];
            let mut touched: Vec<usize> = vec![];
            let n_events = if s == 0 { 3 } else { 2 + rng.below(3) };
            for e in 0..n_events {
                let i = rng.below(slots.len());
                let a = &p.attributes[slots[i].attr];
                let slot = slots[i].clone();
                // The first session states facts; later ones mix every kind of event.
                let roll = if s == 0 && e < 3 { 0 } else { rng.below(100) };
                let (mut plan_id, mut confirms) = (None, None);
                let (say, expect, key) = match (slot.value, slot.planned.clone()) {
                    (None, None) if roll < 70 => {
                        let v = fresh(&mut rng, &slot);
                        slots[i].value = Some(v);
                        shape.facts += 1;
                        (fill(rng.pick(a.fact), v, None), Expect::Commit, true)
                    }
                    (_, Some((planned, planned_by))) if roll < 45 => {
                        // The plan is carried out: a fact from now on, and the plan's own record
                        // may rightly be committed with it.
                        confirms = Some(planned_by);
                        let had = slot.value.is_some();
                        slots[i].value = Some(planned);
                        slots[i].planned = None;
                        slots[i].corrected |= had;
                        shape.outcomes += 1;
                        (fill(rng.pick(a.outcome), planned, slot.value), Expect::Commit, true)
                    }
                    (Some(old), _) if roll < 35 => {
                        let v = fresh(&mut rng, &slot);
                        slots[i].value = Some(v);
                        slots[i].corrected = true;
                        shape.corrections += 1;
                        (fill(rng.pick(a.change), v, Some(old)), Expect::Commit, true)
                    }
                    (_, None) if roll < 60 => {
                        let v = fresh(&mut rng, &slot);
                        let id = format!("plan-{}", shape.plans + 1);
                        slots[i].planned = Some((v, id.clone()));
                        plan_id = Some(id);
                        shape.plans += 1;
                        (fill(rng.pick(a.plan), v, None), Expect::Hold, false)
                    }
                    _ if roll < 80 => {
                        let v = fresh(&mut rng, &slot);
                        shape.guesses += 1;
                        (fill(rng.pick(a.guess), v, None), Expect::Hold, false)
                    }
                    _ => {
                        shape.small_talk += 1;
                        (rng.pick(p.small_talk).to_string(), Expect::Ignore, false)
                    }
                };
                if key {
                    touched.push(i);
                }
                turns.push(SuiteTurn { say, expect, key: key.then(|| a.key.to_string()), kind: a.kind.filter(|_| expect == Expect::Commit), id: plan_id, confirms });
            }
            if rng.chance(40) {
                shape.small_talk += 1;
                let at_turn = rng.below(turns.len() + 1);
                turns.insert(at_turn, SuiteTurn { say: rng.pick(p.small_talk).to_string(), expect: Expect::Ignore, key: None, kind: None, id: None, confirms: None });
            }
            // The checkpoint: what changed in this session, then what was corrected before,
            // then anything known, up to three questions.
            let mut ask: Vec<usize> = touched.clone();
            ask.extend(slots.iter().enumerate().filter(|(_, x)| x.corrected && x.value.is_some()).map(|(i, _)| i));
            ask.extend(slots.iter().enumerate().filter(|(_, x)| x.value.is_some()).map(|(i, _)| i));
            let mut seen = std::collections::HashSet::new();
            let ask: Vec<SuiteQuestion> = ask
                .into_iter()
                .filter(|i| seen.insert(*i))
                .take(3)
                .map(|i| SuiteQuestion { q: p.attributes[slots[i].attr].question.to_string(), key: p.attributes[slots[i].attr].key.to_string() })
                .collect();
            shape.turns += turns.len();
            shape.questions += ask.len();
            sessions.push(SuiteSession { at: Some(at), turns, ask });
            at += Duration::days(3 + rng.below(40) as i64) + Duration::minutes(rng.below(600) as i64);
        }
        shape.sessions += sessions.len();
        out.push(SuiteConversation { id: format!("{}-{seed}-{c:05}", p.name), sessions });
    }
    let suite = Suite {
        format: SUITE_FORMAT,
        name: name.map(String::from).unwrap_or_else(|| format!("synth-{}-{seed}-{conversations}", p.name)),
        description: format!(
            "Synthetic {} timelines: {conversations} conversations from seed {seed} (memhouse bench synth --profile {} --seed {seed} --conversations {conversations}).",
            p.name, p.name
        ),
        k: 5,
        conversations: out,
    };
    suite.validate()?;
    Ok((suite, shape))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_same_seed_gives_the_same_suite_and_more_conversations_extend_it() {
        let (a, shape) = generate("personal", 7, 50, None).unwrap();
        let (b, _) = generate("personal", 7, 50, None).unwrap();
        assert_eq!(a, b);
        assert_eq!(a.hash(), b.hash());
        let (longer, _) = generate("personal", 7, 60, Some(&a.name)).unwrap();
        assert_eq!(longer.conversations[..50], a.conversations[..]);
        assert_ne!(generate("personal", 8, 50, None).unwrap().0.conversations, a.conversations);
        assert_eq!(shape.conversations, 50);
        assert!(shape.sessions >= 200 && shape.turns >= 600);
        // Every kind of event the gate must tell apart is there in number.
        for (what, n) in [
            ("facts", shape.facts),
            ("corrections", shape.corrections),
            ("plans", shape.plans),
            ("guesses", shape.guesses),
            ("outcomes", shape.outcomes),
            ("small talk", shape.small_talk),
        ] {
            assert!(n >= 20, "{what}: {n}");
        }
        assert!(shape.questions >= 400);
    }

    #[test]
    fn every_profile_generates_a_valid_suite_with_consistent_ground_truth() {
        for p in profiles() {
            let (suite, shape) = generate(p, 3, 30, None).unwrap();
            suite.validate().unwrap();
            assert_eq!(suite.turns(), shape.turns, "{p}");
            let carried_out = suite.conversations.iter().flat_map(|c| &c.sessions).flat_map(|s| &s.turns).filter(|t| t.confirms.is_some()).count();
            assert_eq!(carried_out, shape.outcomes, "{p}");
            for c in &suite.conversations {
                for s in &c.sessions {
                    assert!(s.at.is_some() && !s.turns.is_empty());
                    for t in &s.turns {
                        assert!(!t.say.contains('{') && !t.say.contains("  "), "{p}: {}", t.say);
                        // Only a turn that should commit sets a key; plans and guesses never do.
                        assert_eq!(t.key.is_some(), t.expect == Expect::Commit, "{p}: {}", t.say);
                        // A plan has an id; only a turn that carries one out refers to it.
                        assert!(t.id.is_none() || t.expect == Expect::Hold, "{p}: {}", t.say);
                        assert!(t.confirms.is_none() || t.expect == Expect::Commit, "{p}: {}", t.say);
                    }
                }
                let dates: Vec<_> = c.sessions.iter().filter_map(|s| s.at).collect();
                assert!(dates.windows(2).all(|w| w[0] < w[1]), "{p}: sessions out of order");
            }
        }
        assert!(generate("nope", 1, 1, None).is_err());
        assert!(generate("personal", 1, 0, None).is_err());
    }
}
