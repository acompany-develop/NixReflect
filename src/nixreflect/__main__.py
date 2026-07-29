# SPDX-License-Identifier: MIT

"""Allow ``python -m nixreflect`` invocation."""

import sys

from .cli import main

if __name__ == "__main__":
    sys.exit(main())
