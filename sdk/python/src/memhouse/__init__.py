# SPDX-License-Identifier: Apache-2.0
"""MemHouse SDK for Python: a governed memory service for AI agents.

    from memhouse import MemHouse, MemoryHooks

    mh = MemHouse()  # MEMHOUSE_URL and MEMHOUSE_API_KEY
    mh.remember({"subject": "customer:acme", "content": "Acme renews on 2027-03-01"})
    print(mh.recall({"subject": "customer:acme", "query": "renewal", "render": True})["rendered"])

The client has one method per operation of the API (generated from the OpenAPI specification).
`MemoryHooks` are the four lifecycle hooks of an agent loop; they only call the API.
"""

from ._generated import API_VERSION
from .client import HttpTransport, MemHouse, MemHouseError, Transport
from .hooks import MemoryHooks

__version__ = "2.0.0rc1"

__all__ = ["API_VERSION", "HttpTransport", "MemHouse", "MemHouseError", "MemoryHooks", "Transport", "__version__"]
