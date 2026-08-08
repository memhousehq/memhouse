# MemHouse License

Copyright (c) 2026-present Aleksei Popov.

Portions of this repository are licensed as follows:

- Files in `deps/`, generated dependency artifacts, and other third-party
  components remain under the licenses supplied by their respective owners.
- Files whose path contains `/ee/` or whose filename contains `.ee.` are not
  licensed under the MemHouse Sustainable Use License. They are governed by
  `LICENSE_EE.md` unless a separate written agreement says otherwise.
- All other repository content is licensed under the MemHouse Sustainable Use
  License below.

This repository is source-available fair-code. It is not released under an OSI
approved open source license.

## MemHouse Sustainable Use License

Version 1.0

### Acceptance

By using, copying, modifying, distributing, or making the software available, you
accept these terms.

### Copyright Grant

The licensor grants you a non-exclusive, worldwide, royalty-free,
non-transferable, non-sublicensable license to use, copy, modify, distribute, and
make available the software, subject to the limits and conditions in this
license.

### Permitted Use

You may use the software for personal use, evaluation, development, testing,
education, non-commercial use, and your own internal business purposes.

You may run the community self-hosted core for a single Account without usage
metering. You may also use that community core as part of an application you
operate for your own business, provided that you do not sell, rent, provide, or
make available MemHouse itself, a hosted MemHouse instance, or a substantially
similar managed memory service to third parties as a standalone commercial
offering.

You may distribute copies or modified copies only free of charge and only for
personal, evaluation, development, testing, education, or non-commercial use.

### Enterprise Features

Enterprise features require a valid MemHouse Enterprise license or another
written commercial agreement. Enterprise features include, without limitation:

- multiple Accounts in one deployment;
- clustered queue-mode operation;
- SSO, SAML, OIDC enterprise federation, or SCIM;
- database-per-account or schema-per-account isolation;
- granular enterprise RBAC;
- audit export, SIEM streaming, compliance packs, CMK, or KMS integrations;
- any code marked with `/ee/`, `.ee.`, or `SPDX-License-Identifier:
  MemHouse-Enterprise`.

Missing, expired, or insufficient enterprise entitlements do not grant rights to
use enterprise features, even if the source is visible or technically modifiable.

### Restrictions

You may not:

- remove, alter, or obscure copyright, license, or attribution notices;
- use enterprise-marked code except as permitted by `LICENSE_EE.md` or a written
  commercial agreement;
- provide the software as a hosted, managed, paid, or competitive service to
  third parties without a written commercial agreement;
- use the software in a way that avoids, disables, or misrepresents license or
  entitlement checks for enterprise features;
- sublicense the software or grant rights broader than this license grants you.

### Patents

The licensor grants you a license under patent claims it can license, now or in
the future, to make, have made, use, sell, offer for sale, import, and have
imported the software, solely as needed for the permitted use above.

This patent license does not cover claims infringed only because of your
modifications or additions. If you or your company make a written claim that the
software infringes or contributes to patent infringement, the patent license
granted to you under these terms ends immediately.

### Notices

If you give anyone a copy of the software or a substantial part of it, you must
include these terms. If you distribute a modified copy, you must make clear that
you changed it.

### Termination

Any use outside these terms is unlicensed. If you violate these terms, your
rights terminate automatically.

If the licensor notifies you of a violation and you stop all violating activity
within 30 days after receiving notice, your rights are reinstated retroactively
for that violation. A later violation terminates your rights permanently unless
the licensor agrees otherwise in writing.

### No Warranty

The software is provided "as is", without warranties or conditions of any kind,
including implied warranties of merchantability, fitness for a particular
purpose, title, and non-infringement. To the maximum extent permitted by law, the
licensor is not liable for damages arising from the software or these terms.

### Definitions

"Account" has the meaning used in MemHouse's functional requirements: the hard
tenant and isolation boundary.

"Licensor" means the person or entity offering these terms.

"Software" means the MemHouse software and documentation made available under
these terms, including any part of it.

"You" means the individual or entity accepting these terms.

"Your company" means the organization you work for, plus any organization that
controls, is controlled by, or is under common control with it. Control means the
power to direct management or policies by ownership, vote, contract, or
otherwise.

"Use" means any activity requiring permission from the copyright holder or patent
holder.
