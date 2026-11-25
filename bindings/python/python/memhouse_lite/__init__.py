# SPDX-License-Identifier: Apache-2.0
"""MemHouse Lite embedded in this process: the REST API without a server or a socket."""

from ._lite import Lite, __version__

__all__ = ["Lite", "__version__"]
