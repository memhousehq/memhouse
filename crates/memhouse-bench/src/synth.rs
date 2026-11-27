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
use memhouse_core::eval::{FileChangeKind, SuiteFileChange, SUITE_FORMAT_CODE};
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
    /// For a profile with code: the file of the repository each attribute is about, by key.
    /// A statement about the attribute is linked to the file; the file is then edited, renamed
    /// or deleted between sessions, and opened at checkpoints (suite format 2).
    files: &'static [(&'static str, &'static str)],
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
    files: &[],
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
    files: &[],
};

const CODING: Profile = Profile {
    name: "coding",
    // The template's memory categories (TPL-03): conventions (formatter, errors, branch,
    // review), architecture decisions (storage, jobs), pitfalls (flaky, blocking) and build or
    // test quirks (tests, packages, release). Corrections are the `change` lines of each.
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
            fact: &["A pull request needs {v} before it merges.", "Merging a pull request requires {v}.", "The rule is {v} for every pull request."],
            change: &["A pull request no longer needs {old}; it needs {v} now.", "Correction: merging a pull request requires {v}, not {old}."],
            plan: &["We plan to require {v} from next quarter.", "We are going to change the rule to {v}."],
            guess: &["We might require {v} later, maybe.", "Perhaps {v} would be enough."],
            outcome: &["The rule changed: a pull request needs {v} now.", "We now require {v} for every pull request."],
            kind: Some(MemoryKind::Procedural),
        },
        Attribute {
            key: "errors",
            question: "How does this codebase report errors?",
            values: &["typed error enums", "anyhow errors with context", "problem details responses", "result codes with a message table"],
            fact: &["This codebase reports errors as {v}.", "Errors in this codebase are reported as {v}.", "The convention is to report errors as {v}."],
            change: &["The codebase no longer reports errors as {old}; it reports them as {v} now.", "Correction: errors are reported as {v}, not as {old}."],
            plan: &["We plan to report errors as {v} from the next release.", "We are going to move the error handling to {v}."],
            guess: &["We might report errors as {v} someday, maybe.", "Perhaps {v} would make the errors clearer."],
            outcome: &["The refactoring is merged: errors are reported as {v} now.", "We moved the error handling to {v} this week."],
            kind: None,
        },
        Attribute {
            key: "storage",
            question: "Which database does the service store its data in?",
            values: &["Postgres", "SQLite", "DynamoDB", "FoundationDB", "CockroachDB"],
            fact: &["The service stores its data in {v}.", "We decided that the service stores its data in {v}.", "The database behind the service is {v}."],
            change: &["The service no longer stores its data in {old}; it uses {v} now.", "Correction: the service stores its data in {v}, not in {old}."],
            plan: &["We plan to move the service's data to {v} next year.", "We are going to migrate the database to {v}."],
            guess: &["We might move the data to {v} one day, maybe.", "Perhaps {v} would scale better for the data."],
            outcome: &["The migration is done: the service stores its data in {v} now.", "We moved the service's data to {v} last month."],
            kind: None,
        },
        Attribute {
            key: "jobs",
            question: "What do the background jobs run on?",
            values: &["a Postgres job table", "Redis streams", "an SQS queue", "NATS JetStream", "a cron container"],
            fact: &["Background jobs run on {v}.", "We decided that background jobs run on {v}.", "The background jobs of the service run on {v}."],
            change: &["Background jobs no longer run on {old}; they run on {v} now.", "Correction: background jobs run on {v}, not on {old}."],
            plan: &["We plan to move the background jobs to {v} after the release.", "We are going to run the background jobs on {v}."],
            guess: &["We might run the background jobs on {v}, maybe.", "Perhaps {v} would be simpler for the background jobs."],
            outcome: &["The switch is merged: background jobs run on {v} now.", "We moved the background jobs to {v} this sprint."],
            kind: None,
        },
        Attribute {
            key: "flaky",
            question: "Which integration test is known to be flaky?",
            values: &["sync_roundtrip", "upload_resume", "cache_eviction", "token_refresh", "webhook_retry"],
            fact: &["The integration test {v} is known to be flaky on CI.", "The flaky integration test is {v}.", "Of the integration tests, {v} is flaky and fails at random."],
            change: &["The integration test {old} is no longer flaky; the flaky one is {v} now.", "Correction: the flaky integration test is {v}, not {old}."],
            plan: &["We plan to quarantine the integration test {v} next week.", "We are going to mark the integration test {v} as flaky."],
            guess: &["The integration test {v} might be flaky too, maybe.", "Perhaps the integration test {v} is the flaky one."],
            outcome: &["We confirmed it: the flaky integration test is {v} now.", "The integration test {v} was marked as flaky today."],
            kind: None,
        },
        Attribute {
            key: "blocking",
            question: "What must the request handlers not call?",
            values: &["the PDF renderer", "the legacy billing client", "the full-text reindexer", "the image resizer", "the report exporter"],
            fact: &[
                "The request handlers must not call {v}: it blocks the event loop.",
                "Calling {v} from the request handlers blocks the event loop, so it is forbidden.",
                "A known pitfall: the request handlers must not call {v}.",
            ],
            change: &["The request handlers may call {old} again; what they must not call is {v} now.", "Correction: the request handlers must not call {v}, not {old}."],
            plan: &["We plan to forbid the request handlers from calling {v}.", "We are going to move {v} out of the request handlers."],
            guess: &["The request handlers might also be slowed down by {v}, maybe.", "Perhaps {v} is what blocks the request handlers."],
            outcome: &["It is settled: the request handlers must not call {v} now.", "We forbade the request handlers from calling {v} this week."],
            kind: None,
        },
        Attribute {
            key: "release",
            question: "Which flag does the release build need?",
            values: &["--locked", "--frozen", "--offline", "--no-default-features", "--all-features"],
            fact: &["The release build needs the flag {v}.", "The release build is run with the flag {v}.", "A build quirk: the release build needs the flag {v}."],
            change: &["The release build no longer needs the flag {old}; it needs {v} now.", "Correction: the release build needs the flag {v}, not {old}."],
            plan: &["We plan to build the release with the flag {v} from next month.", "We are going to add the flag {v} to the release build."],
            guess: &["The release build might need the flag {v}, maybe.", "Perhaps the flag {v} would fix the release build."],
            outcome: &["The build script changed: the release build needs the flag {v} now.", "We added the flag {v} to the release build today."],
            kind: None,
        },
    ],
    small_talk: &["Thanks, that fixed it.", "Why is the build so slow today?", "Give me a minute to pull the latest changes.", "Looks good to me.", "Can you show the diff again?"],
    files: &[
        ("tests", ".github/workflows/test.yml"),
        ("formatter", "tools/format.toml"),
        ("packages", "scripts/bootstrap.sh"),
        ("review", ".github/CODEOWNERS"),
        ("errors", "src/errors.rs"),
        ("storage", "src/store/mod.rs"),
        ("jobs", "src/jobs/worker.rs"),
        ("flaky", "tests/integration.rs"),
        ("blocking", "src/api/handlers.rs"),
        ("release", "Makefile"),
    ],
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
    files: &[],
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
    files: &[],
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
    /// For a profile with code: statements linked to a file, file changes by kind,
    /// revalidations, and the questions that open a file or expect a stale memory withheld.
    pub linked: usize,
    pub edits: usize,
    pub renames: usize,
    pub deletions: usize,
    pub revalidations: usize,
    pub touch_questions: usize,
    pub stale_questions: usize,
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
    /// The attribute's file in the conversation's repository, while it exists.
    path: Option<String>,
    /// The current statement was linked to the file when it was made.
    linked: bool,
    /// The file changed since the current statement was made: the memory must be withheld.
    stale: bool,
    /// How often the file was renamed.
    renames: usize,
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
        let code = !p.files.is_empty();
        let file_of = |attr: usize| p.files.iter().find(|(key, _)| *key == p.attributes[attr].key).map(|(_, path)| path.to_string());
        let mut slots: Vec<Slot> =
            (0..p.attributes.len()).map(|attr| Slot { attr, value: None, planned: None, corrected: false, path: file_of(attr), linked: false, stale: false, renames: 0 }).collect();
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
            // Between two sessions the repository moves on (a profile with code only, so the
            // other profiles draw the same random numbers as ever). A statement that was
            // linked to a file: the file is edited or deleted, and the memory is stale; or
            // it is renamed, and the memory follows it. A memory that was stale before may
            // be confirmed against the file as it is now.
            let (mut changes, mut revalidate) = (vec![], vec![]);
            if code && s > 0 {
                for slot in slots.iter_mut().filter(|x| x.value.is_some() && x.linked && x.path.is_some()) {
                    let key = p.attributes[slot.attr].key;
                    let path = slot.path.clone().expect("filtered");
                    if slot.stale && rng.chance(30) {
                        slot.stale = false;
                        revalidate.push(key.to_string());
                        shape.revalidations += 1;
                        continue;
                    }
                    match rng.below(100) {
                        0..=21 => {
                            slot.stale = true;
                            shape.edits += 1;
                            changes.push(SuiteFileChange { path, change: FileChangeKind::Edit, to: None });
                        }
                        22..=29 => {
                            slot.renames += 1;
                            let base = file_of(slot.attr).expect("has a file");
                            let to = format!("moved{}/{base}", slot.renames);
                            slot.path = Some(to.clone());
                            shape.renames += 1;
                            changes.push(SuiteFileChange { path, change: FileChangeKind::Rename, to: Some(to) });
                        }
                        30..=34 => {
                            slot.stale = true;
                            slot.path = None;
                            shape.deletions += 1;
                            changes.push(SuiteFileChange { path, change: FileChangeKind::Delete, to: None });
                        }
                        _ => {}
                    }
                }
            }
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
                // A statement about an attribute that has a file is about that file as it is
                // now: linked to it, and no longer stale whatever the one before it was.
                let files: Vec<String> = if code && key { slots[i].path.clone().into_iter().collect() } else { vec![] };
                if code && key {
                    slots[i].linked = !files.is_empty();
                    slots[i].stale = false;
                    shape.linked += files.len();
                }
                turns.push(SuiteTurn {
                    say,
                    expect,
                    key: key.then(|| a.key.to_string()),
                    kind: a.kind.filter(|_| expect == Expect::Commit),
                    id: plan_id,
                    confirms,
                    files,
                    ..Default::default()
                });
            }
            if rng.chance(40) {
                shape.small_talk += 1;
                let at_turn = rng.below(turns.len() + 1);
                turns.insert(at_turn, SuiteTurn { say: rng.pick(p.small_talk).to_string(), expect: Expect::Ignore, ..Default::default() });
            }
            // The checkpoint: what changed in this session, then what was corrected before,
            // then anything known, up to three questions.
            let mut ask: Vec<usize> = touched.clone();
            ask.extend(slots.iter().enumerate().filter(|(_, x)| x.corrected && x.value.is_some()).map(|(i, _)| i));
            ask.extend(slots.iter().enumerate().filter(|(_, x)| x.value.is_some()).map(|(i, _)| i));
            let mut seen = std::collections::HashSet::new();
            let mut ask: Vec<SuiteQuestion> = ask
                .into_iter()
                .filter(|i| seen.insert(*i))
                .take(3)
                .map(|i| SuiteQuestion {
                    q: p.attributes[slots[i].attr].question.to_string(),
                    key: p.attributes[slots[i].attr].key.to_string(),
                    // A memory about a file that changed since must not be recalled.
                    stale: slots[i].stale,
                    ..Default::default()
                })
                .collect();
            if code {
                // The agent opens files: up to three that a current statement is linked to,
                // those whose memory is stale first (they must be listed for revalidation).
                let mut open: Vec<&Slot> = slots.iter().filter(|x| x.value.is_some() && x.linked && x.path.is_some()).collect();
                open.sort_by_key(|x| !x.stale);
                for slot in open.into_iter().take(3) {
                    let path = slot.path.clone().expect("filtered");
                    ask.push(SuiteQuestion {
                        q: format!("Opening {path}"),
                        key: p.attributes[slot.attr].key.to_string(),
                        touch: Some(path),
                        stale: slot.stale,
                        ..Default::default()
                    });
                    shape.touch_questions += 1;
                }
                shape.stale_questions += ask.iter().filter(|q| q.stale).count();
            }
            shape.turns += turns.len();
            shape.questions += ask.len();
            sessions.push(SuiteSession { at: Some(at), changes, revalidate, turns, ask });
            at += Duration::days(3 + rng.below(40) as i64) + Duration::minutes(rng.below(600) as i64);
        }
        shape.sessions += sessions.len();
        out.push(SuiteConversation { id: format!("{}-{seed}-{c:05}", p.name), sessions });
    }
    let suite = Suite {
        format: if p.files.is_empty() { SUITE_FORMAT } else { SUITE_FORMAT_CODE },
        name: name.map(String::from).unwrap_or_else(|| format!("synth-{}-{seed}-{conversations}", p.name)),
        description: format!(
            "Synthetic {} timelines: {conversations} conversations from seed {seed} (memhouse bench synth --profile {} --seed {seed} --conversations {conversations}).",
            p.name, p.name
        ),
        language: None,
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
        // The coding profile has code: statements linked to files, the files changed between
        // sessions, and questions that open them. The other profiles have none of it, and
        // stay format 1 suites.
        let (coding, shape) = generate("coding", 7, 40, None).unwrap();
        assert_eq!(coding.format, SUITE_FORMAT_CODE);
        for (what, n) in [
            ("linked", shape.linked),
            ("edits", shape.edits),
            ("renames", shape.renames),
            ("deletions", shape.deletions),
            ("revalidations", shape.revalidations),
            ("touch questions", shape.touch_questions),
            ("stale questions", shape.stale_questions),
        ] {
            assert!(n >= 5, "{what}: {n}");
        }
        let keys: std::collections::HashSet<&str> = coding.conversations.iter().flat_map(|c| &c.sessions).flat_map(|s| &s.turns).filter_map(|t| t.key.as_deref()).collect();
        for category in ["formatter", "errors", "storage", "jobs", "flaky", "blocking", "tests", "release", "review"] {
            assert!(keys.contains(category), "{category}");
        }
        for c in &coding.conversations {
            // A file is opened only while it exists under that name, and a change names a file
            // that exists: the repository of a conversation is consistent from start to end.
            let mut files = std::collections::HashSet::new();
            for s in &c.sessions {
                for ch in &s.changes {
                    assert!(files.remove(&ch.path), "{}: {} changed before any statement was linked to it", c.id, ch.path);
                    match ch.change {
                        FileChangeKind::Edit => files.insert(ch.path.clone()),
                        FileChangeKind::Rename => files.insert(ch.to.clone().unwrap()),
                        FileChangeKind::Delete => true,
                    };
                }
                files.extend(s.turns.iter().flat_map(|t| t.files.iter().cloned()));
                assert!(s.ask.iter().filter_map(|q| q.touch.as_ref()).all(|p| files.contains(p)), "{}: a file that is not there is opened", c.id);
            }
        }
        let (personal, plain) = generate("personal", 7, 5, None).unwrap();
        assert_eq!((personal.format, plain.linked + plain.edits + plain.touch_questions), (SUITE_FORMAT, 0));
        assert!(generate("nope", 1, 1, None).is_err());
        assert!(generate("personal", 1, 0, None).is_err());
    }
}
