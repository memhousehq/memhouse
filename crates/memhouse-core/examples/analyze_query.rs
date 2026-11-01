//! Prints the query plan for each `<rfc3339 time>\t<question>` line on stdin as JSON.
use std::io::BufRead;

fn main() {
    for line in std::io::stdin().lock().lines().map_while(Result::ok) {
        let Some((t, q)) = line.split_once('\t') else { continue };
        let Ok(now) = chrono::DateTime::parse_from_rfc3339(t) else { continue };
        let plan = memhouse_core::query::analyze(q, now.with_timezone(&chrono::Utc));
        println!("{}", serde_json::to_string(&plan).unwrap());
    }
}
