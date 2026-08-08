# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

# Database seed script. Run it with:
#
# If you ever do add seeding here, write through Ash actions, not through
# `MemHouse.Repo.insert!/1`. Every durable row in this system belongs to an Account and is
# subject to Ash policies, row-level security, and — for knowledge — the extraction pipeline
# and the governance gates. Inserting with Ecto bypasses all of that and produces rows that
# the application will not treat as valid: unattributed, ungoverned, and invisible to
# retrieval.
